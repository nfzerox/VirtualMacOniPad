#import "StencilDescriptorBridge.h"
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <ptrauth.h>
#include "RuntimeLog.h"
#include "GPUCompatibilityLogMacros.h"

// Exact pinned ABI @48@0:8@16I24^v28I36@40; ARC's init ownership
// convention is explicit on the C trampoline and original function pointer.
typedef id (*StencilCtor)(id __attribute__((ns_consumed)),SEL,id,uint32_t,
                         void *,uint32_t,id) __attribute__((ns_returns_retained));
static StencilCtor savedCtor;
static Class pinnedClass;
static _Atomic unsigned translated,rejected;
static uint16_t s16(const uint8_t *p){uint16_t v;memcpy(&v,p,2);return v;}
static uint32_t s32(const uint8_t *p){uint32_t v;memcpy(&v,p,4);return v;}
static uint64_t s64(const uint8_t *p){uint64_t v;memcpy(&v,p,8);return v;}
static BOOL plane(const uint8_t *p,uint8_t bpp,uint64_t width,uint64_t height,
                  uint64_t allocation, uint64_t *start,uint64_t *end) {
    if(s16(p)!=1||s16(p+2)!=1||p[20]!=1||p[21]!=1||p[22]!=1||p[23]!=bpp)return NO;
    uint64_t base=s64(p+4),stride=s64(p+12),offset=s64(p+24),length=s64(p+32),row=s64(p+40);
    if(s32(p+48)!=width||s32(p+52)!=height||s32(p+56)!=1)return NO;
    // Both actual producer mip0 rows retain depth's pitch; tighter new-layout
    // inputs are intentionally outside this constructor-only experiment.
    if(width>UINT64_MAX/4||row<width*4||row%4||height>UINT64_MAX/row)return NO;
    uint64_t used=row*height;
    if(used>length||offset>stride||used>stride-offset||base>allocation||stride>allocation-base)return NO;
    if(offset>allocation-base||length>allocation-base-offset)return NO;
    *start=base;*end=base+stride;return YES;
}
BOOL ThinStencilDescriptorPreflight(const void *bytes,uint32_t length,uint64_t width,uint64_t height) {
    if(!bytes||length<0x84||length>65536||!width||!height||width>16384||height>16384)return NO;
    const uint8_t *p=bytes;uint64_t allocation=s64(p),a,b,c,d;
    if(!allocation||allocation>UINT32_MAX)return NO;
    return plane(p+12,4,width,height,allocation,&a,&b)&&
           plane(p+72,1,width,height,allocation,&c,&d)&&(b<=c||d<=a);
}
static void stencilNeed(BOOL condition,NSString *reason) {
    if(condition)return;
    atomic_fetch_add(&rejected,1);VMMThinRuntimeRecord("stencil-descriptor-rejected",12,0,0,0);
    @throw [NSException exceptionWithName:@"ThinStencilDescriptor" reason:reason userInfo:nil];
}
static id stencilCtor(id __attribute__((ns_consumed)) object,SEL selector,id task,
                      uint32_t type,void *descriptor,uint32_t length,id texture)
                      __attribute__((ns_returns_retained));
static id stencilCtor(id __attribute__((ns_consumed)) object,SEL selector,id task,
                      uint32_t type,void *descriptor,uint32_t length,id texture) {
    id<MTLTexture> metal=texture;
    if(type!=12||(metal.pixelFormat!=260&&metal.pixelFormat!=261))
        return savedCtor(object,selector,task,type,descriptor,length,texture);
    // Preserve the complete legacy path, including its own rejection behavior.
    if(descriptor&&length>=0x84&&((const uint8_t *)descriptor)[0x5f]==4)
        return savedCtor(object,selector,task,type,descriptor,length,texture);
    stencilNeed(object_getClass(object)==pinnedClass,@"unexpected stencil resource class");
    stencilNeed(descriptor&&length>=0x84&&length<=65536,@"bounded two-plane stencil descriptor required");
    // Own a stable snapshot before checking; original pointer and guest bytes
    // remain untouched. The original constructor synchronously copies records.
    NSMutableData *copy=[NSMutableData dataWithBytes:descriptor length:length];
    stencilNeed(copy!=nil,@"stencil descriptor snapshot allocation failed");
    stencilNeed(metal.textureType==MTLTextureType2D&&metal.sampleCount==1&&
                metal.mipmapLevelCount==1&&metal.arrayLength==1&&metal.depth==1,
                @"only ordinary single-sample one-mip 2D stencil supported");
    stencilNeed(ThinStencilDescriptorPreflight(copy.bytes,length,metal.width,metal.height),
                @"stencil descriptor shape/pitch/extent outside narrow subset");
    uint8_t *p=copy.mutableBytes;p[0x5f]=4;
    id result=savedCtor(object,selector,task,type,p,length,texture);
    if(result){
        stencilNeed(object_getClass(result)==pinnedClass,@"unexpected initialized stencil class");
        uint8_t *planes[2]={0};memcpy(planes,(const uint8_t *)(__bridge const void *)result+64,sizeof(planes));
        stencilNeed(planes[0]&&planes[1]&&planes[0]!=planes[1]&&planes[1][23]==4,
                    @"unexpected owned stencil plane records");
        planes[1][23]=1;atomic_fetch_add(&translated,1);
    }
    return result;
}
BOOL ThinInstallStencilDescriptorBridge(void *base) {
    if(savedCtor)return NO;
    Class cls=NSClassFromString(@"PGDualPlaneBlitTextureResource");
    SEL selector=NSSelectorFromString(@"initWithTask:objectType:descriptor:descriptorLength:texture:");
    Method method=class_getInstanceMethod(cls,selector);Ivar planes=class_getInstanceVariable(cls,"_planes");
    Dl_info origin={0};
    if(!cls||!method||!planes||class_getInstanceSize(cls)!=80||ivar_getOffset(planes)!=64||
       strcmp(ivar_getTypeEncoding(planes),"[2^{?}]")||
       strcmp(method_getTypeEncoding(method),"@48@0:8@16I24^v28I36@40")||
       !dladdr((const void *)method_getImplementation(method),&origin)||origin.dli_fbase!=base)return NO;
    // Known implementation address in the __TEXT-hash-pinned image.
    const void *implementation=ptrauth_strip((const void *)method_getImplementation(method),ptrauth_key_function_pointer);
    if((uintptr_t)implementation-(uintptr_t)base!=0x190c8)return NO;
    pinnedClass=cls;savedCtor=(StencilCtor)method_setImplementation(method,(IMP)stencilCtor);
    printf("stencil-constructor-hook ABI=%s planes-offset=64 instance-size=80\n",method_getTypeEncoding(method));
    return YES;
}
unsigned ThinStencilDescriptorTranslatedCount(void){return atomic_load(&translated);}
unsigned ThinStencilDescriptorRejectedCount(void){return atomic_load(&rejected);}
