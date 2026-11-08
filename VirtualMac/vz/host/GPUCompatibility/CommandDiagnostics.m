#import "CommandDiagnostics.h"
#include "RuntimeLog.h"
#include <objc/runtime.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#include <stdatomic.h>

// Header-only diagnostics. No command payload, guest addresses or guest strings.
static _Thread_local ThinCommandContext context;
static pthread_mutex_t firstLock=PTHREAD_MUTEX_INITIALIZER;
static NSDictionary *first;
static char outputPath[PATH_MAX];
static Class iteratorClass,decoderClasses[4];
static Ivar bufferIvar,offsetIvar,lengthIvar;
typedef void (*Decode)(id,SEL,const void *,id);
static Decode originals[4];
BOOL ThinCommandSetOutputPath(const char *path){
    if(!path||path[0]!='/'||strlen(path)>=sizeof(outputPath)||first)return NO;
    if(outputPath[0])return !strcmp(outputPath,path);
    struct stat st;errno=0;if(lstat(path,&st)==0||errno!=ENOENT)return NO;
    snprintf(outputPath,sizeof(outputPath),"%s",path);return YES;
}
ThinCommandContext ThinCommandEnter(uint32_t opcode,uint32_t stamp,uint64_t bytes,uint32_t slot,BOOL child){
    ThinCommandContext previous=context;context=(ThinCommandContext){true,child,opcode,stamp,slot,bytes};return previous;
}
void ThinCommandLeave(ThinCommandContext previous){context=previous;}
static void publish(NSDictionary *record){
    NSDictionary *claimed=nil;
    pthread_mutex_lock(&firstLock);
    @try {
        if(first)return;
        NSMutableDictionary *complete=[record mutableCopy];complete[@"schema"]=@1;
        complete[@"outerAvailable"]=@(context.valid);
        if(context.valid){complete[@"outerOpcode"]=@(context.opcode);complete[@"stamp"]=@(context.stamp);complete[@"stampSlot"]=@(context.slot);complete[@"child"]=@(context.child);complete[@"outerBytes"]=@(context.bytes);}
        first=[complete copy];claimed=first;
    } @finally {pthread_mutex_unlock(&firstLock);}
    @try {
        NSData *json=[NSJSONSerialization dataWithJSONObject:claimed options:NSJSONWritingSortedKeys error:nil];
        // Optional file is exclusive: preserve an earlier failed run's evidence.
        int fileError=0;
        if(outputPath[0]){
            int fd=open(outputPath,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
            if(fd<0)fileError=errno;
            else {size_t done=0;while(done<json.length){ssize_t n=write(fd,(const uint8_t *)json.bytes+done,json.length-done);if(n<0&&errno==EINTR)continue;if(n<=0){fileError=errno?:EIO;break;}done+=(size_t)n;}if(!fileError&&fsync(fd))fileError=errno;close(fd);}
        }
        VMMThinRuntimePrint("FIRST-UNKNOWN %.*s file-error=%d\n",(int)json.length,(const char *)json.bytes,fileError);
    } @catch(NSException *ignored){(void)ignored;}
}
NSDictionary *ThinCommandFirstUnknown(void){pthread_mutex_lock(&firstLock);NSDictionary *result=first?:@{};pthread_mutex_unlock(&firstLock);return result;}
void ThinCommandUnknownOuter(uint32_t opcode,uint32_t stamp,uint64_t bytes,uint32_t slot,BOOL child){
    ThinCommandContext previous=ThinCommandEnter(opcode,stamp,bytes,slot,child);
    @try {publish(@{@"kind":@"outer-unsupported",@"opcode":@(opcode),@"recordBytes":@(bytes)});}
    @finally {ThinCommandLeave(previous);}
}
static void decode(unsigned index,id object,SEL selector,const void *header,id iterator){
    @try {originals[index](object,selector,header,iterator);}
    @catch(NSException *exception){
        if(index==3)VMMThinRuntimePrint("COMPUTE-DECODE-ERROR name=%s reason=%s\n",exception.name.UTF8String,exception.reason.UTF8String);
        // Pinned native loops read exactly8 command header bytes immediately
        // before their UnrecognizedCommand branch; fault() does not move iterator.
        // Do not reinterpret unrelated exceptions as an unknown opcode.
        if([exception.name isEqualToString:@"UnrecognizedCommand"]&&object_getClass(object)==decoderClasses[index]&&object_getClass(iterator)==iteratorClass){
            const uint8_t *buffer=NULL;uint64_t offset=0,length=0;
            const uint8_t *base=(const uint8_t *)(__bridge const void *)iterator;
            memcpy(&buffer,base+ivar_getOffset(bufferIvar),8);memcpy(&offset,base+ivar_getOffset(offsetIvar),8);memcpy(&length,base+ivar_getOffset(lengthIvar),8);
            if(buffer&&offset>=8&&offset<=length&&(uintptr_t)buffer<=UINTPTR_MAX-length){
                uint32_t op,bytes;memcpy(&op,buffer+offset-8,4);memcpy(&bytes,buffer+offset-4,4);
                publish(@{@"kind":@"inner-unrecognized",@"opcode":@(op),@"recordBytes":@(bytes),@"offset":@(offset-8),@"segmentBytes":@(length),@"decoderType":@(index==0?2:index==1?3:index==2?0:1),@"recordWithinSegment":@(bytes>=8&&bytes<=length-(offset-8))});
            }else publish(@{@"kind":@"inner-unrecognized-unlocated",@"decoderIndex":@(index)});
        }
        @throw;
    }
}
static void blit(id o,SEL s,const void *h,id i){decode(0,o,s,h,i);}
static void event(id o,SEL s,const void *h,id i){decode(1,o,s,h,i);}
static void render(id o,SEL s,const void *h,id i){decode(2,o,s,h,i);}
static void compute(id o,SEL s,const void *h,id i){decode(3,o,s,h,i);}
BOOL ThinInstallCommandDiagnostics(void *base){
    Class it=NSClassFromString(@"MTLByteIterator");Ivar b=class_getInstanceVariable(it,"buffer"),o=class_getInstanceVariable(it,"currentOffset"),l=class_getInstanceVariable(it,"length");
    if(!it||class_getInstanceSize(it)!=32||!b||!o||!l||ivar_getOffset(b)!=8||strcmp(ivar_getTypeEncoding(b),"^v")||ivar_getOffset(o)!=16||strcmp(ivar_getTypeEncoding(o),"Q")||ivar_getOffset(l)!=24||strcmp(ivar_getTypeEncoding(l),"Q"))return NO;
    const char *names[]={"MTLDeserializerBlitDecoder","MTLDeserializerEventDecoder","MTLDeserializerRenderDecoder","MTLDeserializerComputeDecoder"};
    const uintptr_t offsets[]={0x28b8,0x64e0,0xa678,0x19750};
    IMP hooks[]={(IMP)blit,(IMP)event,(IMP)render,(IMP)compute};Method methods[4];
    for(unsigned n=0;n<4;n++){
        decoderClasses[n]=NSClassFromString(@(names[n]));Method m=class_getInstanceMethod(decoderClasses[n],sel_registerName("decodeWithHeader:withIterator:"));Dl_info image={0};
        if(!m||strcmp(method_getTypeEncoding(m),"v32@0:8^{?=ICCC}16@24"))return NO;
        const void *pc=ptrauth_strip((const void *)method_getImplementation(m),ptrauth_key_function_pointer);
        if(!dladdr(pc,&image)||image.dli_fbase!=base||(uintptr_t)pc-(uintptr_t)base!=offsets[n])return NO;methods[n]=m;
    }
    iteratorClass=it;bufferIvar=b;offsetIvar=o;lengthIvar=l;
    for(unsigned n=0;n<4;n++)originals[n]=(Decode)method_setImplementation(methods[n],hooks[n]);return YES;
}

// Capture only the first arbitrary padding word, not command-buffer contents.
static _Atomic bool paddingSeen;
void ThinCommandObserveExecPadding(const void *payload,size_t length){
    if(atomic_load(&paddingSeen)||!payload||length<12||length>65536)return;
    const uint8_t *p=payload;uint32_t task,resources,buffers;memcpy(&task,p,4);memcpy(&resources,p+4,4);memcpy(&buffers,p+8,4);
    if(12+(uint64_t)resources*8+(uint64_t)buffers*16!=length)return;
    for(uint32_t i=0;i<resources;i++){
        uint32_t flags,reference;memcpy(&flags,p+12+(size_t)i*8+4,4);
        if(!(flags&~7u))continue;memcpy(&reference,p+12+(size_t)i*8,4);
        if(!atomic_exchange(&paddingSeen,true))VMMThinRuntimePrint("EXEC-PADDING-OBSERVED task=%u resource-index=%u reference=%u raw=0x%08x semantic=0x%x ignored-padding=0x%08x resources=%u buffers=%u outer-available=%u opcode=%u stamp=%u slot=%u child=%u\n",task,i,reference,flags,flags&7u,flags&~7u,resources,buffers,context.valid,context.opcode,context.stamp,context.slot,context.child);
        break;
    }
}

// Independent of first-unknown outer12. Emit once per known Info ID and at
// most4 other IDs/records, bounded24 lines total. No guest payload/address read.
static _Atomic uint32_t infoSeen;
static _Atomic unsigned otherInfoLogged;
void ThinCommandUnknownInfo(uint32_t opcode,uint32_t bytes,uint64_t offset,
                            uint64_t segmentBytes,uint32_t task,uint32_t segmentIndex){
    if(opcode>=450&&opcode<=469){
        uint32_t bit=UINT32_C(1)<<(opcode-450);
        if(atomic_fetch_or(&infoSeen,bit)&bit)return;
    }else{
        unsigned n=atomic_load(&otherInfoLogged);
        do {if(n>=4)return;}while(!atomic_compare_exchange_weak(&otherInfoLogged,&n,n+1));
    }
    // A diagnostic sink failure must never replace the original query fault.
    @try {
        VMMThinRuntimePrint("INFO-UNSUPPORTED opcode=%u record-bytes=%u record-offset=%llu segment-bytes=%llu task=%u segment-index=%u outer-available=%u outer-opcode=%u outer-bytes=%llu stamp=%u slot=%u child=%u\n",opcode,bytes,(unsigned long long)offset,(unsigned long long)segmentBytes,task,segmentIndex,context.valid,context.opcode,(unsigned long long)context.bytes,context.stamp,context.slot,context.child);
    }@catch(NSException *ignored){(void)ignored;}
}
