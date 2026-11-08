#import "TextureBridge.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdatomic.h>
#include "GPUCompatibilityLogMacros.h"
#include "RuntimeLog.h"

// Disposable experiment: only operation52 and operation56 on the pinned decoder.
static BOOL (*originalOperation)(id,SEL,const void *,NSUInteger,id);
static id (*originalBuffer)(id,SEL,uint32_t);
static void (*originalSurface)(id,SEL,id,const void *,NSUInteger,id);
static _Thread_local ThinTextureExtras *active;
static _Thread_local uint32_t activeOpcode;
static _Thread_local BOOL surfaceActive;
static _Thread_local uint16_t expectedRotation;
static _Atomic unsigned translated,restored;
static _Atomic unsigned bufferTextureCount,bufferManagedCount,bufferManagedTranslated;
static _Atomic NSUInteger lastBufferGuestMode,lastBufferEffectiveMode;
static BOOL extraPaths=YES;
static uint32_t u32(const void *p){uint32_t x;memcpy(&x,p,4);return x;}
static void p32(void *p,uint32_t x){memcpy(p,&x,4);}
static void need(BOOL ok,NSString *reason){if(!ok){VMMThinRuntimeRecord("texture-bounds-rejected",0,0,0,0);@throw [NSException exceptionWithName:@"ThinTexture" reason:reason userInfo:nil];}}

MTLTextureDescriptor *ThinRestoreTextureDescriptor(MTLTextureDescriptor *descriptor) {
    if(!active)return descriptor;
    need(descriptor.usage==(active->usage&255),@"unexpected legacy usage");
    MTLTextureDescriptor *copy=[descriptor copy];copy.usage=active->usage;
    copy.swizzle=(MTLTextureSwizzleChannels){active->swizzle[0],active->swizzle[1],active->swizzle[2],active->swizzle[3]};
    if(surfaceActive) {
        SEL rotation=NSSelectorFromString(@"rotation");need([copy respondsToSelector:rotation],@"surface rotation getter missing");
        need(((NSUInteger(*)(id,SEL))objc_msgSend)(copy,rotation)==expectedRotation,@"surface rotation not preserved");
        printf("surface-descriptor rotation=%u PRESERVED\n",expectedRotation);
    }
    if(active->writeSwizzle) {
        SEL s=NSSelectorFromString(@"setWriteSwizzleEnabled:");need([copy respondsToSelector:s],@"write swizzle unavailable");
        ((void(*)(id,SEL,BOOL))objc_msgSend)(copy,s,YES);
    }
    atomic_fetch_add(&restored,1);return copy;
}

@interface ThinHeap : NSObject
@property(nonatomic,strong) id<MTLHeap> real;
@end
@implementation ThinHeap
-(id)forwardingTargetForSelector:(SEL)s{return self.real;}
-(BOOL)respondsToSelector:(SEL)s{return [super respondsToSelector:s]||[self.real respondsToSelector:s];}
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    return [self.real newTextureWithDescriptor:ThinRestoreTextureDescriptor(d)];
}
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset {
    return [self.real newTextureWithDescriptor:ThinRestoreTextureDescriptor(d) offset:offset];
}
@end
id ThinWrapHeap(id<MTLHeap> heap){if(!heap)return nil;ThinHeap *p=[ThinHeap new];p.real=heap;return p;}

@interface ThinTextureBuffer : NSObject
@property(nonatomic,strong) id<MTLBuffer> real;
@end
@implementation ThinTextureBuffer
-(id)forwardingTargetForSelector:(SEL)s{return self.real;}
-(BOOL)respondsToSelector:(SEL)s{return [super respondsToSelector:s]||[self.real respondsToSelector:s];}
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)stride {
    MTLTextureDescriptor *restored=ThinRestoreTextureDescriptor(d);
    if(restored==d)restored=[d copy];
    NSUInteger guestMode=restored.storageMode;
    NSUInteger hostMode=[self.real respondsToSelector:@selector(storageMode)]?self.real.storageMode:0;
    atomic_store(&lastBufferGuestMode,guestMode);
    atomic_store(&lastBufferEffectiveMode,guestMode);
    atomic_fetch_add(&bufferTextureCount,1);
    if(guestMode==1) {
        // iPadOS exposes no MTLStorageModeManaged. A buffer-backed texture
        // aliases the buffer's allocation, so use the host buffer's actual
        // storage mode; fall back to Shared only if the buffer cannot name a
        // valid non-Managed mode. Never touch storageMode 0, 2 or 3.
        NSUInteger effective=(hostMode==0||hostMode==2||hostMode==3)?hostMode:0;
        restored.storageMode=(MTLStorageMode)effective;
        atomic_store(&lastBufferEffectiveMode,effective);
        atomic_fetch_add(&bufferManagedCount,1);
        atomic_fetch_add(&bufferManagedTranslated,1);
        printf("buffer-texture-managed guest=1 host-buffer=%lu effective=%lu translated=1\n",
               (unsigned long)hostMode,(unsigned long)effective);
    }
    return [self.real newTextureWithDescriptor:restored offset:offset bytesPerRow:stride];
}
@end
static id bufferForTexture(id decoder,SEL selector,uint32_t reference) {
    id value=originalBuffer(decoder,selector,reference);
    if(!value || activeOpcode!=55)return value;
    ThinTextureBuffer *wrapper=[ThinTextureBuffer new];wrapper.real=value;return wrapper;
}

static BOOL operation(id decoder,SEL selector,const void *bytes,NSUInteger length,id allocator) {
    if(length<8 || (u32(bytes)!=52 && (u32(bytes)!=55||!extraPaths) && u32(bytes)!=56))return originalOperation(decoder,selector,bytes,length,allocator);
    const uint8_t *p=bytes;uint32_t opcode=u32(p);
    uint8_t synthetic[52]={0},legacy[44],output[64]={0};NSUInteger oldLength=44;
    ThinTextureExtras extras;const char *error=NULL;
    if(opcode==52) {
        need(ThinTexture52To1(bytes,length,legacy,&extras,&error),error?@(error):@"invalid52");
        memcpy(output,legacy,44);
    } else if(opcode==56) {
        need(length==68 && u32(p+4)==68,@"expected exact68-byte operation56");
        p32(synthetic,52);p32(synthetic+4,52);memcpy(synthetic+8,p+8,4);memcpy(synthetic+12,p+16,39);
        need(ThinTexture52To1(synthetic,52,legacy,&extras,&error),error?@(error):@"invalid56 descriptor");
        // Preserve ref, heap ref, placement flag, padding and 64-bit heap offset.
        p32(output,21);p32(output+4,60);memcpy(output+8,p+8,8);
        memcpy(output+16,legacy+12,32);memcpy(output+48,p+56,4);memcpy(output+52,p+60,8);
        oldLength=60;
    } else {
        need(length==72 && u32(p+4)==72,@"expected exact72-byte operation55");
        p32(synthetic,52);p32(synthetic+4,52);memcpy(synthetic+8,p+8,4);memcpy(synthetic+12,p+32,39);
        need(ThinTexture52To1(synthetic,52,legacy,&extras,&error),error?@(error):@"invalid55 descriptor");
        memcpy(output,p,32);p32(output,9);p32(output+4,64);memcpy(output+32,legacy+12,32);oldLength=64;
    }
    ThinTextureExtras *previous=active;uint32_t previousOpcode=activeOpcode;active=&extras;activeOpcode=opcode;
    unsigned before=atomic_load(&restored);BOOL accepted;
    @try {accepted=originalOperation(decoder,selector,output,oldLength,allocator);}
    @catch(NSException *e){fprintf(stderr,"texture-operation%u exception %s: %s\n",opcode,e.name.UTF8String,e.reason.UTF8String);@throw;}
    @finally {active=previous;activeOpcode=previousOpcode;}
    printf("texture-operation%u accepted=%u restored=%u\n",opcode,accepted,atomic_load(&restored)-before);
    need(accepted && atomic_load(&restored)==before+1,@"texture creation failed or restoration missing");
    atomic_fetch_add(&translated,1);return accepted;
}
static void surface(id decoder,SEL selector,id iosurface,const void *bytes,NSUInteger length,id allocator) {
    if(length<8 || u32(bytes)!=57 || !extraPaths){originalSurface(decoder,selector,iosurface,bytes,length,allocator);return;}
    const uint8_t *p=bytes;need(length==56 && u32(p+4)==56,@"expected exact56-byte operation57");
    uint8_t synthetic[52]={0},legacy[44],output[48]={0};ThinTextureExtras extras;const char *error=NULL;
    p32(synthetic,52);p32(synthetic+4,52);memcpy(synthetic+8,p+8,4);memcpy(synthetic+12,p+12,39);
    need(ThinTexture52To1(synthetic,52,legacy,&extras,&error),error?@(error):@"invalid57 descriptor");
    memcpy(output,legacy,44);p32(output,47);p32(output+4,48);memcpy(output+44,p+52,4);
    ThinTextureExtras *previous=active;BOOL previousSurface=surfaceActive;uint16_t previousRotation=expectedRotation;
    memcpy(&expectedRotation,p+54,2);surfaceActive=YES;active=&extras;unsigned before=atomic_load(&restored);
    @try {originalSurface(decoder,selector,iosurface,output,48,allocator);}
    @finally {active=previous;surfaceActive=previousSurface;expectedRotation=previousRotation;}
    need(atomic_load(&restored)==before+1,@"surface texture descriptor not restored");
    atomic_fetch_add(&translated,1);printf("texture-operation57 accepted=1 restored=1\n");
}
BOOL ThinInstallTextureBridge(void *expectedSerializerBase) {
    Method m=class_getInstanceMethod(NSClassFromString(@"_MTLDeserializer"),NSSelectorFromString(@"operationWithSerializedData:serializedDataSize:allocator:"));
    if(!m)return NO;Dl_info origin={0};
    if(!dladdr((void *)method_getImplementation(m),&origin)||origin.dli_fbase!=expectedSerializerBase)return NO;
    printf("texture-hook ABI=%s\n",method_getTypeEncoding(m));
    Class cls=NSClassFromString(@"_MTLDeserializer");
    Method b=class_getInstanceMethod(cls,NSSelectorFromString(@"getBufferForReference:"));
    Method s=class_getInstanceMethod(cls,NSSelectorFromString(@"newTextureWithIOSurface:serializedData:serializedDataSize:allocator:"));
    for(unsigned i=0;i<2;i++) {
        Method next=i?s:b;Dl_info nextOrigin={0};if(!next)return NO;
        if(!dladdr((void *)method_getImplementation(next),&nextOrigin)||nextOrigin.dli_fbase!=expectedSerializerBase)return NO;
        printf("texture-extra-hook%u ABI=%s\n",i,method_getTypeEncoding(next));
    }
    if(method_getTypeEncoding(s)[0]!='v')return NO;
    originalOperation=(void *)method_setImplementation(m,(IMP)operation);
    originalBuffer=(void *)method_setImplementation(b,(IMP)bufferForTexture);
    originalSurface=(void *)method_setImplementation(s,(IMP)surface);return YES;
}
unsigned ThinTextureTranslationCount(void){return atomic_load(&translated);}
unsigned ThinTextureRestoreCount(void){return atomic_load(&restored);}
unsigned ThinBufferTextureCount(void){return atomic_load(&bufferTextureCount);}
unsigned ThinBufferTextureManagedCount(void){return atomic_load(&bufferManagedCount);}
unsigned ThinBufferTextureManagedTranslationCount(void){return atomic_load(&bufferManagedTranslated);}
NSUInteger ThinLastBufferTextureGuestStorageMode(void){return atomic_load(&lastBufferGuestMode);}
NSUInteger ThinLastBufferTextureEffectiveStorageMode(void){return atomic_load(&lastBufferEffectiveMode);}
void ThinDisableAdditionalTexturePaths(void){extraPaths=NO;}
