#import "BackendBridge.h"
#import "ThinRuntime.h"
#import "DeviceInfoBridge.h"
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <stdatomic.h>

// Process-local, startup-only. Never interpose the already-interposed factory.
// Explicit consumed-self/+1-result ABI matches the pinned MRC initializers.
typedef id (*DeviceCtor)(id __attribute__((ns_consumed)),SEL,id) __attribute__((ns_returns_retained));
typedef id (*DisplayCtor)(id __attribute__((ns_consumed)),SEL,id,id,NSUInteger,uint32_t) __attribute__((ns_returns_retained));
static DeviceCtor savedDevice;
static DisplayCtor savedDisplay;
static Class deviceClass,displayClass,descriptorClass;
static Ivar displayCache;
static char ownedKey;
static _Atomic unsigned devices,displays;
static void need(BOOL ok,NSString *why){if(!ok)@throw [NSException exceptionWithName:@"ThinBackendBoundary" reason:why userInfo:nil];}

static id backendDeviceInit(id __attribute__((ns_consumed)) object,SEL selector,id descriptor) __attribute__((ns_returns_retained));
static id backendDeviceInit(id __attribute__((ns_consumed)) object,SEL selector,id descriptor){
    need(object_getClass(object)==deviceClass&&object_getClass(descriptor)==descriptorClass,@"unexpected device/descriptor class");
    id metal=((id(*)(id,SEL))objc_msgSend)(descriptor,NSSelectorFromString(@"device"));
    need(metal!=nil,@"missing backing Metal device");
    id wrapper=VMMThinRuntimeWrapDevice(metal);need(wrapper!=nil,@"cannot wrap backing device");
    id forward=ThinMakeImageblockDescriptor(descriptor,wrapper);
    id result=savedDevice(object,selector,forward);
    if(result){
        need(object_getClass(result)==deviceClass,@"unexpected initialized device class");
        need(((id(*)(id,SEL))objc_msgSend)(result,NSSelectorFromString(@"mtlDevice"))==wrapper,@"native constructor did not retain supplied wrapper");
        ThinAttachImageblockDeviceInfo(result,forward);
        char error[256];need(VMMThinRuntimeAttachDevice(result,error,sizeof(error)),@(error));
        objc_setAssociatedObject(result,&ownedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_fetch_add(&devices,1);
    }
    return result;
}
static id backendDisplayInit(id __attribute__((ns_consumed)) object,SEL selector,id device,id descriptor,NSUInteger port,uint32_t serial) __attribute__((ns_returns_retained));
static id backendDisplayInit(id __attribute__((ns_consumed)) object,SEL selector,id device,id descriptor,NSUInteger port,uint32_t serial){
    id result=savedDisplay(object,selector,device,descriptor,port,serial);
    if(result&&[objc_getAssociatedObject(device,&ownedKey) boolValue]){
        need(object_getClass(result)==displayClass&&object_getClass(device)==deviceClass,@"unexpected owned display/device class");
        id wrapper=((id(*)(id,SEL))objc_msgSend)(device,NSSelectorFromString(@"mtlDevice"));
        need(object_getIvar(result,displayCache)==wrapper,@"display cache differs from owner");
        need(object_getClass(wrapper)==NSClassFromString(@"ThinInfoDevice"),@"only an owned ThinInfoDevice may be unwrapped");
        Ivar real=class_getInstanceVariable(object_getClass(wrapper),"_real");
        id native=real?object_getIvar(wrapper,real):nil;need(native!=nil,@"owned wrapper has no native device");
        // Pinned MRC code stores a borrowed pointer; lifetime is supplied by
        // display -> PGDevice -> ThinInfoDevice -> native device. No ARC store.
        void *pointer=(__bridge void *)native;
        memcpy((uint8_t *)(__bridge void *)result+ivar_getOffset(displayCache),&pointer,sizeof(pointer));
        atomic_fetch_add(&displays,1);
    }
    return result;
}
static BOOL method(Class cls,NSString *name,const char *abi,void *base,uintptr_t offset,Method *out){
    Method m=class_getInstanceMethod(cls,NSSelectorFromString(name));Dl_info origin={0};
    if(!m||strcmp(method_getTypeEncoding(m),abi))return NO;
    const void *pc=ptrauth_strip((const void *)method_getImplementation(m),ptrauth_key_function_pointer);
    if(!dladdr(pc,&origin)||origin.dli_fbase!=base||(offset&&(uintptr_t)pc-(uintptr_t)base!=offset))return NO;
    if(out)*out=m;return YES;
}
static BOOL hooksIntact(void){return savedDevice&&method_getImplementation(class_getInstanceMethod(deviceClass,sel_registerName("initWithDescriptor:")))==(IMP)backendDeviceInit&&method_getImplementation(class_getInstanceMethod(displayClass,sel_registerName("initWithDevice:descriptor:port:serialNum:")))==(IMP)backendDisplayInit;}
BOOL ThinInstallBackendBridge(void *base){
    if(savedDevice)return hooksIntact();
    Class dc=NSClassFromString(@"_PGDevice"),sc=NSClassFromString(@"_PGDisplay"),desc=NSClassFromString(@"PGDeviceDescriptor");
    Method d=NULL,s=NULL;Ivar cache=class_getInstanceVariable(sc,"_mtlDevice");
    // All guards precede either replacement. Refuse unknown tracer chains.
    if(!dc||!sc||!desc||!cache||ivar_getOffset(cache)!=0xf0||strcmp(ivar_getTypeEncoding(cache),"@\"<MTLDevice>\"")||class_getInstanceSize(sc)!=472||
       !method(dc,@"initWithDescriptor:","@24@0:8@16",base,0xe94c,&d)||
       !method(sc,@"initWithDevice:descriptor:port:serialNum:","@44@0:8@16@24Q32I40",base,0x22e48,&s)||
       !method(dc,@"mtlDevice","@16@0:8",base,0,NULL)||
       !method(sc,@"encodeCurrentFrameToCommandBuffer:texture:region:","B80@0:8@16@24{?={?=QQQ}{?=QQQ}}32",base,0x235b8,NULL))return NO;
    deviceClass=dc;displayClass=sc;descriptorClass=desc;displayCache=cache;
    savedDevice=(DeviceCtor)method_setImplementation(d,(IMP)backendDeviceInit);
    savedDisplay=(DisplayCtor)method_setImplementation(s,(IMP)backendDisplayInit);
    return YES;
}
NSDictionary *ThinBackendBridgeStatus(void){return @{@"installed":@(savedDevice!=NULL),@"hooksIntact":@(hooksIntact()),@"devicesCreated":@(atomic_load(&devices)),@"displayCachesAdapted":@(atomic_load(&displays))};}
