#import "DeviceInfoBridge.h"
#import "PVGCallbackABI.h"
#include "RuntimeLog.h"
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <stdatomic.h>

// Track only addresses returned by the caller's existing createTask callback.
// No guest mapping, allocator, writer, framework bytes or task handle is replaced.
@interface ThinImageblockContext : NSObject
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSMutableDictionary *bases;
@property(nonatomic) BOOL supported;
@end
@implementation ThinImageblockContext
@end
typedef struct {__unsafe_unretained ThinImageblockContext *context;uint32_t maxKey,capacity;BOOL patched;} DeviceInfoRequest;
static _Thread_local DeviceInfoRequest *request;
static char contextKey;
static void (*nativeGetInfo)(id,SEL,uint32_t,uint32_t,uint32_t);
static _Atomic unsigned publications;
static uint32_t u32(const void *p){uint32_t v;memcpy(&v,p,4);return v;}
static void publishBeforeUnmap(ThinImageblockContext *context,PGTask_t *task,uint64_t offset,uint64_t length){
    DeviceInfoRequest *q=request;
    if(!q||q->context!=context||q->patched||q->maxKey<=24||length!=0x4000)return;
    [context.lock lock];NSArray *mapping=context.bases[@((uintptr_t)task)];[context.lock unlock];
    if(!mapping)return;
    uintptr_t base=[mapping[0] unsignedLongLongValue];uint64_t span=[mapping[1] unsignedLongLongValue];
    if(offset>span||length>span-offset||offset>UINTPTR_MAX-base||length>UINTPTR_MAX-base-offset)return;
    uint8_t *table=(uint8_t *)(base+offset);uint32_t capacity=MIN(q->capacity,(uint32_t)(length/8));
    uint32_t count=0,insert=UINT32_MAX;
    while(count<capacity&&u32(table+count*8)){
        uint32_t key=u32(table+count*8);
        if(key==24)return; // Pinned old writer does not publish this key.
        if(key>24&&insert==UINT32_MAX)insert=count;
        count++;
    }
    if(count>=capacity||capacity-count<2)return; // Preserve a full native reply.
    if(insert==UINT32_MAX)insert=count;
    // Preserve ascending native key order and its zero terminator.
    memmove(table+(insert+1)*8,table+insert*8,(count-insert+1)*8);
    uint32_t pair[2]={24,1};memcpy(table+insert*8,pair,8);q->patched=YES;
    if(atomic_fetch_add(&publications,1)<4)VMMThinRuntimePrint("IMAGEBLOCK-DEVICEINFO key24=1 before-unmap=YES tile-key23=UNCHANGED pairs=%u\n",count+1);
}
@interface ThinImageblockDescriptor : NSObject
@property(nonatomic,strong) PGDeviceDescriptor *original;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) ThinImageblockContext *context;
@end
@implementation ThinImageblockDescriptor
-(id)forwardingTargetForSelector:(SEL)s{return self.original;}
-(BOOL)respondsToSelector:(SEL)s{return [super respondsToSelector:s]||[self.original respondsToSelector:s];}
-(PGTask_t *(^)(uint64_t,void **))createTask{
    PGTask_t *(^create)(uint64_t,void **)=self.original.createTask;ThinImageblockContext *c=self.context;
    return ^PGTask_t *(uint64_t n,void **base){
        PGTask_t *task=create(n,base);
        if(task&&base&&*base){[c.lock lock];c.bases[@((uintptr_t)task)]=@[@((uintptr_t)*base),@(n)];[c.lock unlock];}
        return task;
    };
}
-(void(^)(PGTask_t *))destroyTask{
    void(^destroy)(PGTask_t *)=self.original.destroyTask;ThinImageblockContext *c=self.context;
    return ^(PGTask_t *task){[c.lock lock];[c.bases removeObjectForKey:@((uintptr_t)task)];[c.lock unlock];destroy(task);};
}
-(bool(^)(PGTask_t *,uint64_t,uint64_t))unmapMemory{
    bool(^unmap)(PGTask_t *,uint64_t,uint64_t)=self.original.unmapMemory;ThinImageblockContext *c=self.context;
    return ^bool(PGTask_t *task,uint64_t offset,uint64_t length){publishBeforeUnmap(c,task,offset,length);return unmap(task,offset,length);};
}
@end
id ThinMakeImageblockDescriptor(id original,id<MTLDevice> device){
    ThinImageblockDescriptor *d=[ThinImageblockDescriptor new];d.original=original;d.device=device;
    ThinImageblockContext *c=[ThinImageblockContext new];c.lock=[NSLock new];c.bases=[NSMutableDictionary new];
    SEL support=sel_registerName("supportsImageBlocks");c.supported=[device respondsToSelector:support]&&((BOOL(*)(id,SEL))objc_msgSend)(device,support);
    d.context=c;return d;
}
void ThinAttachImageblockDeviceInfo(id device,id descriptor){
    if(object_getClass(descriptor)!=[ThinImageblockDescriptor class])return;
    ThinImageblockContext *c=((ThinImageblockDescriptor *)descriptor).context;
    if(c.supported)objc_setAssociatedObject(device,&contextKey,c,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void getInfo(id device,SEL selector,uint32_t maxKey,uint32_t capacity,uint32_t page){
    ThinImageblockContext *context=objc_getAssociatedObject(device,&contextKey);
    if(!context){nativeGetInfo(device,selector,maxKey,capacity,page);return;}
    DeviceInfoRequest q={context,maxKey,capacity,NO};DeviceInfoRequest *previous=request;request=&q;
    @try{nativeGetInfo(device,selector,maxKey,capacity,page);}
    @finally{request=previous;}
}
BOOL ThinInstallImageblockDeviceInfoBridge(void *base){
    Method m=class_getInstanceMethod(NSClassFromString(@"_PGDevice"),sel_registerName("getDeviceInfo:length:dst:"));Dl_info origin={0};
    if(nativeGetInfo||!m||strcmp(method_getTypeEncoding(m),"v28@0:8I16I20I24"))return NO;
    const void *pc=ptrauth_strip((const void *)method_getImplementation(m),ptrauth_key_function_pointer);
    if(!dladdr(pc,&origin)||origin.dli_fbase!=base||(uintptr_t)pc-(uintptr_t)base!=0x11df0)return NO;
    nativeGetInfo=(void *)method_setImplementation(m,(IMP)getInfo);return YES;
}
