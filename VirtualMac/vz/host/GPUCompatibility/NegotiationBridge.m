#import "NegotiationBridge.h"
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include "RuntimeLog.h"
static Class nativeClass;
static Ivar nativeFIFO;
static char associationKey;
static void (*nativeSet)(id,SEL,uint32_t),(*nativeWillSuspend)(id,SEL);
static uint32_t (*nativeRead)(id,SEL,size_t);
typedef id (*FinishSuspendFn)(id,SEL) __attribute__((ns_returns_retained));
static FinishSuspendFn nativeFinishSuspend;
static BOOL (*nativeResume)(id,SEL,id,NSError *__autoreleasing *);
@interface VMMThinNegotiationState : NSObject
@property(nonatomic,strong) NSRecursiveLock *lock;
@property(nonatomic) uint32_t ceiling,visible,lastRequest;
@property(nonatomic) uint64_t acceptedWrites,ignoredWrites,suspendRefusals,resumeRefusals;
@end
@implementation VMMThinNegotiationState
@end
static VMMThinNegotiationState *stateFor(id device){return objc_getAssociatedObject(device,&associationKey);}
static void record(const char *kind,uint32_t value){@try{VMMThinRuntimeRecord(kind,value,0,0,UINT32_MAX);}@catch(NSException *e){(void)e;}}
static void need(BOOL ok,NSString *why){if(!ok)@throw [NSException exceptionWithName:@"ThinNegotiation" reason:why userInfo:nil];}
static uint16_t registerIndex(size_t offset){return (uint16_t)(((uint32_t)offset-UINT32_C(0x1000))>>2);}
static void setVersion(id device,SEL selector,uint32_t requested){
    VMMThinNegotiationState *s=stateFor(device);
    if(!s){nativeSet(device,selector,requested);return;}
    [s.lock lock];
    @try {
        s.lastRequest=requested;
        if(requested&UINT32_C(0x80000000)){
            // Retain native refusal/logging; neither visible nor native changes.
            nativeSet(device,selector,requested);s.ignoredWrites++;return;
        }
        uint32_t forwarded=requested>=s.ceiling?43:requested;
        nativeSet(device,selector,forwarded);
        uint32_t actual=nativeRead(device,NSSelectorFromString(@"mmioReadAtOffset:"),0x1034);
        need(requested<s.ceiling||actual==43,@"native43 negotiation did not hold");
        s.visible=requested>=s.ceiling?s.ceiling:actual;s.acceptedWrites++;
    } @finally {[s.lock unlock];}
}
static uint32_t readMMIO(id device,SEL selector,size_t offset){
    VMMThinNegotiationState *s=stateFor(device);
    if(!s||registerIndex(offset)!=13)return nativeRead(device,selector,offset);
    [s.lock lock];uint32_t value=s.visible;[s.lock unlock];return value;
}
static void willSuspend(id device,SEL selector){
    VMMThinNegotiationState *s=stateFor(device);if(!s){nativeWillSuspend(device,selector);return;}
    [s.lock lock];s.suspendRefusals++;[s.lock unlock];record("preview-suspend-refused",237);
    need(NO,@"preview237 does not support saved state");
}
static id finishSuspend(id device,SEL selector) __attribute__((ns_returns_retained));
static id finishSuspend(id device,SEL selector){
    VMMThinNegotiationState *s=stateFor(device);if(!s)return nativeFinishSuspend(device,selector);
    [s.lock lock];s.suspendRefusals++;[s.lock unlock];record("preview-suspend-refused",237);
    need(NO,@"preview237 does not support saved state");return nil;
}
static BOOL resumeState(id device,SEL selector,id state,NSError *__autoreleasing *error){
    VMMThinNegotiationState *s=stateFor(device);if(!s)return nativeResume(device,selector,state,error);
    [s.lock lock];s.resumeRefusals++;[s.lock unlock];record("preview-resume-refused",237);
    if(error)*error=[NSError errorWithDomain:@"VMMThinNegotiationErrorDomain" code:237 userInfo:@{NSLocalizedDescriptionKey:@"preview237 saved-state restoration is unsupported; cold initialization required"}];
    return NO;
}
BOOL ThinInstallNegotiationBridge(void *base){
    if(nativeClass)return NO;
    Class cls=NSClassFromString(@"_PGDevice");
    const char *names[]={"setBinaryVersion:","mmioReadAtOffset:","willSuspend","finishSuspend","willResumeWithSuspendState:error:"};
    const char *abis[]={"v20@0:8I16","I24@0:8Q16","v16@0:8","@16@0:8","B32@0:8@16^@24"};
    Method methods[5];
    for(unsigned i=0;i<5;i++){
        methods[i]=class_getInstanceMethod(cls,sel_registerName(names[i]));Dl_info origin={0};
        if(!methods[i]||strcmp(method_getTypeEncoding(methods[i]),abis[i])||!dladdr((const void *)method_getImplementation(methods[i]),&origin)||origin.dli_fbase!=base)return NO;
    }
    // These getters remain original and expose native state for cross-checking.
    const char *getters[]={"binaryVersion","features","runState"};
    const char *getterABIs[]={"i16@0:8","r^{APVFeatures=BBBBBBBBBBBBBB}16@0:8","i16@0:8"};
    for(unsigned i=0;i<3;i++){
        Method m=class_getInstanceMethod(cls,sel_registerName(getters[i]));Dl_info origin={0};
        if(!m||strcmp(method_getTypeEncoding(m),getterABIs[i])||!dladdr((const void *)method_getImplementation(m),&origin)||origin.dli_fbase!=base)return NO;
    }
    Ivar fifo=class_getInstanceVariable(cls,"_fifo");
    const char *fifoType="{?=\"enabled\"I\"basePage\"I\"length\"I\"start\"I\"virtualOffset\"Q\"read\"I\"written\"I}";
    if(!fifo||ivar_getOffset(fifo)!=0x208||strcmp(ivar_getTypeEncoding(fifo),fifoType)||class_getInstanceSize(cls)<0x228)return NO;
    nativeFIFO=fifo;
    nativeSet=(void *)method_getImplementation(methods[0]);nativeRead=(void *)method_getImplementation(methods[1]);
    nativeWillSuspend=(void *)method_getImplementation(methods[2]);nativeFinishSuspend=(void *)method_getImplementation(methods[3]);nativeResume=(void *)method_getImplementation(methods[4]);
    nativeClass=cls;
    method_setImplementation(methods[0],(IMP)setVersion);method_setImplementation(methods[1],(IMP)readMMIO);
    method_setImplementation(methods[2],(IMP)willSuspend);method_setImplementation(methods[3],(IMP)finishSuspend);method_setImplementation(methods[4],(IMP)resumeState);
    return YES;
}
BOOL ThinAttachNegotiationDevice(id device,uint32_t ceiling,char *error,size_t capacity){
    @try {
        need(nativeClass&&object_getClass(device)==nativeClass,@"expected exact pinned PGDevice");need(ceiling==237,@"only preview237 attachment supported");
        // Attachment is a startup-only operation; serialize repeated callers.
        @synchronized(device){
            VMMThinNegotiationState *old=stateFor(device);
            if(old)need(old.ceiling==ceiling,@"negotiation profile is immutable");
            else {
                SEL read=NSSelectorFromString(@"mmioReadAtOffset:");
                uint32_t runState=((uint32_t(*)(id,SEL))objc_msgSend)(device,NSSelectorFromString(@"runState"));
                need(runState==0,@"attach only in initial native lifecycle state0");
                uint32_t fifo[4];memcpy(fifo,(const uint8_t *)(__bridge const void *)device+ivar_getOffset(nativeFIFO),sizeof(fifo));
                need(nativeRead(device,read,0x1034)==0&&nativeRead(device,read,0x101c)==0&&
                     fifo[0]==0&&fifo[1]==0&&fifo[2]==0&&fifo[3]==0,
                     @"attach before guest version/root/FIFO staging");
                VMMThinNegotiationState *s=[VMMThinNegotiationState new];s.lock=[NSRecursiveLock new];s.ceiling=ceiling;
                objc_setAssociatedObject(device,&associationKey,s,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                record("preview-device-attached",237);
            }
        }
        if(error&&capacity)error[0]=0;return YES;
    } @catch(NSException *e){if(error&&capacity)snprintf(error,capacity,"%s",e.reason.UTF8String);return NO;}
}
NSDictionary *ThinNegotiationDeviceStatus(id device){
    if(!nativeClass||object_getClass(device)!=nativeClass)return nil;
    VMMThinNegotiationState *s=stateFor(device);if(s)[s.lock lock];
    @try {
        uint32_t native=nativeRead(device,NSSelectorFromString(@"mmioReadAtOffset:"),0x1034);
        const uint8_t *features=((const uint8_t *(*)(id,SEL))objc_msgSend)(device,NSSelectorFromString(@"features"));
        NSMutableString *hex=[NSMutableString new];for(unsigned i=0;i<14;i++)[hex appendFormat:@"%02x",features[i]];
        return @{@"attached":@(s!=nil),@"ceiling":@(s?s.ceiling:43),@"guestVersion":@(s?s.visible:native),@"nativeVersion":@(native),@"nativeFeatureBytes":@14,@"nativeFeaturesHex":hex,
            @"lastRequest":@(s?s.lastRequest:0),@"acceptedWrites":@(s?s.acceptedWrites:0),@"ignoredWrites":@(s?s.ignoredWrites:0),@"suspendRefusals":@(s?s.suspendRefusals:0),@"resumeRefusals":@(s?s.resumeRefusals:0),@"savedStateBlocked":@(s!=nil)};
    } @finally {if(s)[s.lock unlock];}
}
