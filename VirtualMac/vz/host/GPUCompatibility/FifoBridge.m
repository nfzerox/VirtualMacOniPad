#import "FifoBridge.h"
#include "ThinBridge.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdatomic.h>
#include "GPUCompatibilityLogMacros.h"
#include "InfoBridge.h"
#include "RuntimeLog.h"
#include "CommandDiagnostics.h"
#include "NegotiationBridge.h"

// Isolated experiment: preserve each real reader's original IMP and native
// barrier/advance/completion machinery. Hooks only this process's loaded copy.
static void (*originalRootLatch)(id,SEL),(*originalChildLatch)(id,SEL);
static BOOL (*originalRootRead)(id,SEL,NSUInteger,void *),(*originalChildRead)(id,SEL,NSUInteger,void *);
static void (*originalExec)(id,SEL,const void *,uint32_t,const void *,NSUInteger);
static void (*originalObjectList)(id,SEL,const void *,uint32_t,const void *,NSUInteger);
static Ivar taskLengthIvar;
static Class localTaskClass;
static _Atomic unsigned objectLists;
static void (*originalDelete)(id,SEL,const void *,uint32_t,const void *,NSUInteger);
static _Thread_local void *readingFIFO;
static _Thread_local BOOL expectingHeader;
static _Thread_local uint16_t translatedOpcode;
static _Thread_local BOOL readingChild;
static _Atomic unsigned translated,childTranslated,childInfo;
static BOOL childTranslationEnabled=YES;
static uint16_t read16(const void *p){uint16_t v;memcpy(&v,p,2);return v;}
static void put16(void *p,uint16_t v){memcpy(p,&v,2);}
static void put32(void *p,uint32_t v){memcpy(p,&v,4);}

static void latch(id fifo,BOOL child) {
    readingFIFO=(__bridge void *)fifo;expectingHeader=YES;translatedOpcode=0;
    readingChild=child;
}
static void rootLatch(id fifo,SEL selector) {originalRootLatch(fifo,selector);latch(fifo,NO);}
static void childLatch(id fifo,SEL selector) {originalChildLatch(fifo,selector);latch(fifo,YES);}
static BOOL readBytes(id fifo,NSUInteger length,void *bytes,BOOL result) {
    if(readingFIFO==(__bridge void *)fifo && expectingHeader && result) {
        expectingHeader=NO;
        if(readingChild&&!childTranslationEnabled)return result;
        if(length!=12)@throw [NSException exceptionWithName:@"ThinFIFO" reason:@"unexpected FIFO header size" userInfo:nil];
        uint16_t wireOpcode=read16(bytes),barriers=read16((uint8_t *)bytes+2);uint32_t wireStamp,wireLength;memcpy(&wireStamp,(uint8_t *)bytes+8,4);memcpy(&wireLength,(uint8_t *)bytes+4,4);
        uint32_t slot=((uint32_t(*)(id,SEL))objc_msgSend)(fifo,NSSelectorFromString(@"stampIndex"));
        // Native processFifo rejects >32 before reading its bounded barrier array.
        // Retain that rejection and wire bytes, adding only a bounded diagnostic.
        if(barriers>32)VMMThinRuntimeRecord("native-barrier-limit",wireOpcode,wireStamp,wireLength,slot);
        if(wireOpcode==11||wireOpcode==12||(wireOpcode>64&&wireOpcode!=65&&wireOpcode!=67&&wireOpcode!=68&&wireOpcode!=69))
            {VMMThinRuntimeRecord("unsupported-root-opcode",wireOpcode,wireStamp,wireLength,slot);
             ThinCommandUnknownOuter(wireOpcode,wireStamp,wireLength,slot,readingChild);}
        if(read16(bytes)==65 || read16(bytes)==67 || read16(bytes)==68 || (read16(bytes)==69 && ThinInfoEnabled())) {
            translatedOpcode=read16(bytes);put16(bytes,55);
            // Leave wire length, barriers and stamp unchanged. The real reader
            // consumes the original bytes; expansion happens at handler entry.
        }
    }
    return result;
}
static BOOL rootRead(id fifo,SEL selector,NSUInteger length,void *bytes) {
    return readBytes(fifo,length,bytes,originalRootRead(fifo,selector,length,bytes));
}
static BOOL childRead(id fifo,SEL selector,NSUInteger length,void *bytes) {
    return readBytes(fifo,length,bytes,originalChildRead(fifo,selector,length,bytes));
}
static void execBody(id fifo,SEL selector,const void *header,uint32_t stamp,const void *payload,NSUInteger length) {
    if(readingFIFO!=(__bridge void *)fifo || !translatedOpcode) {
        originalExec(fifo,selector,header,stamp,payload,length);return;
    }
    uint16_t opcode=translatedOpcode;translatedOpcode=0;BOOL child=readingChild;
    if(opcode==68){
        ThinObjectLists68 fields;const char *why=NULL;uint8_t converted[12],legacyHeader[12];
        id device=[fifo valueForKey:@"device"];NSDictionary *state=ThinNegotiationDeviceStatus(device);
        if(![state[@"attached"] boolValue]||[state[@"guestVersion"] unsignedIntValue]!=237||[state[@"nativeVersion"] unsignedIntValue]!=43)
            @throw [NSException exceptionWithName:@"ThinFIFO" reason:@"local68 requires owned guest237/native43 device" userInfo:nil];
        if(!ThinDecodeObjectLists68(payload,length,&fields))
            @throw [NSException exceptionWithName:@"ThinFIFO" reason:@"local68 requires exact28-byte metadata" userInfo:nil];
        id task=((id(*)(id,SEL,uint32_t))objc_msgSend)(device,NSSelectorFromString(@"getTaskID:"),fields.task);
        if(object_getClass(task)!=localTaskClass)
            @throw [NSException exceptionWithName:@"ThinFIFO" reason:@"local68 requires pinned in-process PGTask" userInfo:nil];
        uint64_t taskBytes;memcpy(&taskBytes,(const uint8_t *)(__bridge const void *)task+ivar_getOffset(taskLengthIvar),8);
        if(!ThinLocalObjectLists68To51(payload,length,taskBytes,converted,&why)){
            VMMThinRuntimeRecord("local68-rejected",68,stamp,length,UINT32_MAX);
            @throw [NSException exceptionWithName:@"ThinFIFO" reason:@(why) userInfo:nil];
        }
        memcpy(legacyHeader,header,12);put16(legacyHeader,51);put32(legacyHeader+4,24+(uint32_t)read16(legacyHeader+2)*8);
        originalObjectList(fifo,NSSelectorFromString(@"CmdSetObjectList:stampValue:withPayload:payloadSize:"),legacyHeader,stamp,converted,12);
        unsigned n=atomic_fetch_add(&objectLists,1);
        if(n<8)VMMThinRuntimePrint("LOCAL68-APPLIED task=%u object-bytes=%u placement-bytes=%u nonempty-placement=%u mode=PINNED-LOCAL-NO-PLACEMENT stamp=%u child=%u\n",fields.task,fields.objectBytes,fields.placementBytes,fields.placementOffset!=0&&fields.placementBytes!=0,stamp,child);
        else if(n==8)VMMThinRuntimePrint("LOCAL68-LOG-LIMIT further-field-records-suppressed\n");
        return;
    }
    if(opcode==65) {
        if(length!=4)@throw [NSException exceptionWithName:@"ThinFIFO" reason:@"expected shared backing reference only" userInfo:nil];
        uint8_t data[8]={0},legacyHeader[12];memcpy(data+4,payload,4);memcpy(legacyHeader,header,12);
        put16(legacyHeader,37);put32(legacyHeader+4,20+(uint32_t)read16(legacyHeader+2)*8);
        originalDelete(fifo,NSSelectorFromString(@"CmdDeleteResource:stampValue:withPayload:payloadSize:"),legacyHeader,stamp,data,8);
        printf("shared-delete65 native37 kernel-task=0 payload=4-to-8\n");return;
    }
    if(opcode==69){ThinHandleInfo(fifo,stamp,payload,length);if(child)atomic_fetch_add(&childInfo,1);return;}
    if(length>65536)@throw [NSException exceptionWithName:@"ThinFIFO" reason:@"payload exceeds bounded spike" userInfo:nil];
    size_t capacity=length*3,written=0;const char *error=NULL;
    uint8_t *converted=malloc(capacity);
    if(!converted || !ThinExec3To2(payload,length,converted,capacity,&written,&error)) {
        free(converted);
        @throw [NSException exceptionWithName:@"ThinFIFO" reason:error?@(error):@"allocation failed" userInfo:nil];
    }
    ThinCommandObserveExecPadding(payload,length);
    uint8_t legacyHeader[12];memcpy(legacyHeader,header,12);
    put16(legacyHeader,55);put32(legacyHeader+4,(uint32_t)written+12+(uint32_t)read16(legacyHeader+2)*8);
    @try {originalExec(fifo,selector,legacyHeader,stamp,converted,written);}
    @finally {
        memset(converted,0xa5,capacity);free(converted);
        atomic_fetch_add(&translated,1);
        if(child)atomic_fetch_add(&childTranslated,1);
    }
}
static void exec(id fifo,SEL selector,const void *header,uint32_t stamp,const void *payload,NSUInteger length){
    uint32_t wireBytes=0;memcpy(&wireBytes,(const uint8_t *)header+4,4);
    uint32_t slot=((uint32_t(*)(id,SEL))objc_msgSend)(fifo,NSSelectorFromString(@"stampIndex"));
    ThinCommandContext prior=ThinCommandEnter(translatedOpcode?:read16(header),stamp,wireBytes,slot,readingChild);
    @try {execBody(fifo,selector,header,stamp,payload,length);}
    @finally {ThinCommandLeave(prior);}
}
BOOL ThinInstallRootFIFOBridge(void *expectedImageBase) {
    Class root=NSClassFromString(@"PGRootFIFO"),child=NSClassFromString(@"PGChildFIFO"),base=NSClassFromString(@"PGFIFO");
    Method methods[]={class_getInstanceMethod(root,@selector(latchCommandOffset)),
        class_getInstanceMethod(root,@selector(getFifoBytes:into:)),
        class_getInstanceMethod(child,@selector(latchCommandOffset)),
        class_getInstanceMethod(child,@selector(getFifoBytes:into:)),
        class_getInstanceMethod(base,@selector(CmdExecIndirect2:stampValue:withPayload:payloadSize:)),
        class_getInstanceMethod(base,@selector(CmdDeleteResource:stampValue:withPayload:payloadSize:))};
    const char *abis[]={"v16@0:8","B32@0:8Q16^v24","v16@0:8","B32@0:8Q16^v24","v44@0:8^{?=SSII}16I24^v28Q36","v44@0:8^{?=SSII}16I24^v28Q36"};
    for(unsigned i=0;i<6;i++) {
        if(!methods[i])return NO;
        Dl_info origin={0};
        if(!dladdr((void *)method_getImplementation(methods[i]),&origin)||origin.dli_fbase!=expectedImageBase)return NO;
        printf("FIFO-hook ABI[%u]=%s\n",i,method_getTypeEncoding(methods[i]));
        if(strcmp(method_getTypeEncoding(methods[i]),abis[i]))return NO;
    }
    Method objectMethod=class_getInstanceMethod(base,NSSelectorFromString(@"CmdSetObjectList:stampValue:withPayload:payloadSize:"));
    Class task=NSClassFromString(@"PGTask");Ivar taskLength=class_getInstanceVariable(task,"_length");Dl_info objectOrigin={0};
    if(!objectMethod||strcmp(method_getTypeEncoding(objectMethod),"v44@0:8^{?=SSII}16I24^v28Q36")||!dladdr((const void *)method_getImplementation(objectMethod),&objectOrigin)||objectOrigin.dli_fbase!=expectedImageBase||
       class_getInstanceSize(task)!=1960||!taskLength||ivar_getOffset(taskLength)!=40||strcmp(ivar_getTypeEncoding(taskLength),"Q"))return NO;
    const char *taskNames[]={"addressForOffset:length:","setObjectListOffset:length:","getComputePipelineStateForReference:"};const char *taskABIs[]={"^v32@0:8Q16Q24","v28@0:8Q16I24","@20@0:8I16"};
    for(unsigned k=0;k<3;k++){Method m=class_getInstanceMethod(task,sel_registerName(taskNames[k]));Dl_info image={0};if(!m||strcmp(method_getTypeEncoding(m),taskABIs[k])||!dladdr((const void *)method_getImplementation(m),&image)||image.dli_fbase!=expectedImageBase)return NO;}
    localTaskClass=task;taskLengthIvar=taskLength;originalObjectList=(void *)method_getImplementation(objectMethod);
    originalRootLatch=(void *)method_setImplementation(methods[0],(IMP)rootLatch);
    originalRootRead=(void *)method_setImplementation(methods[1],(IMP)rootRead);
    originalChildLatch=(void *)method_setImplementation(methods[2],(IMP)childLatch);
    originalChildRead=(void *)method_setImplementation(methods[3],(IMP)childRead);
    originalExec=(void *)method_setImplementation(methods[4],(IMP)exec);
    originalDelete=(void *)method_getImplementation(methods[5]);
    return YES;
}
unsigned ThinFIFOTranslatedCount(void){return atomic_load(&translated);}
unsigned ThinFIFOChildTranslatedCount(void){return atomic_load(&childTranslated);}
unsigned ThinFIFOChildInfoCount(void){return atomic_load(&childInfo);}
void ThinDisableChildTranslation(void){childTranslationEnabled=NO;}

unsigned ThinFIFOObjectListsCount(void){return atomic_load(&objectLists);}
