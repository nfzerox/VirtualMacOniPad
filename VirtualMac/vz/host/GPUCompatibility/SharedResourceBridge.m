#import "SharedResourceBridge.h"
#include "ThinBridge.h"
#include "GPUCompatibilityLogMacros.h"
#include "RuntimeLog.h"
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <string.h>

// Evidence: pinned old PGTask makeResource/makeTexture and getObject:entry:;
// PGSinglePlane init @0x18b38; PGTextureView init @0x17808. Reims pinned
// 1fe0acb6 manager/texture.rs and texture/shared.rs describe the newer records.
// Only one 2D BGRA8 mip, one slice/sample, <=4096 dimensions, unprotected;
// no placement table/resource-index implementation, no type18/two-plane support.
@interface NSObject (ThinSharedOldABI)
-(void)getObject:(uint32_t)reference entry:(void *)entry;
-(void *)mappedAddressForOffset:(uint64_t)offset length:(uint64_t)length;
-(id)getExistingHostResource:(uint32_t)reference;
-(id)getHostResource:(uint32_t)reference;
-(void)registerHostResource:(id)resource forReference:(uint32_t)reference;
-(id)mtlDevice;
-(id)device;
-(id)getTaskID:(uint32_t)task;
-(void)makeResource:(uint32_t)reference;
-(void)makeTexture:(uint32_t)reference;
-(id)backingForID:(uint32_t)reference;
-(id)getTexture;
-(BOOL)needsPrepare;
-(void)prepareInEncoder:(id)encoder;
-(void)setIsGuestValid:(BOOL)value;
-(instancetype)initWithTask:(id)task objectType:(uint32_t)type descriptor:(const void *)descriptor descriptorLength:(uint32_t)length texture:(id)texture;
-(instancetype)initWithTask:(id)task texture:(id)texture;
@end

@interface ThinSharedMetadata : NSObject
@property(nonatomic,strong) MTLSharedTextureHandle *handle;
@property(nonatomic,weak) id backing;
@property(nonatomic,weak) id taskOverride;
@end
@implementation ThinSharedMetadata
@end

typedef struct __attribute__((packed)) {uint32_t word;uint64_t address;} ObjectEntry;
static void (*originalMakeResource)(id,SEL,uint32_t),(*originalMakeTexture)(id,SEL,uint32_t);
static id (*originalBackingForID)(id,SEL,uint32_t);
static Class backingClass,referenceClass;
static char backingKey,referenceKey,taskKey;
static _Atomic unsigned backings,references;
static BOOL installed;
static void need(BOOL ok,NSString *why){if(!ok){VMMThinRuntimeRecord("shared-bounds-rejected",0,0,0,0);@throw [NSException exceptionWithName:@"ThinSharedResource" reason:why userInfo:nil];}}
static uint16_t u16(const void *p){uint16_t n;memcpy(&n,p,2);return n;}
static uint32_t u32(const void *p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const void *p){uint64_t n;memcpy(&n,p,8);return n;}
static ObjectEntry entryFor(id task,uint32_t reference){ObjectEntry e={0};need(reference!=0,@"reference zero");[task getObject:reference entry:&e];return e;}
static BOOL isSpecial(unsigned type){return type==16||type==17||type==18;}

IOSurfaceRef ThinSharedBackingSurface(id backing){
    need(objc_getAssociatedObject(backing,&backingKey)!=nil,@"not a spike shared backing");
    id<MTLTexture> texture=[backing getTexture];
    return texture.iosurface; // Texture retains its surface; returned +0.
}
static IOSurfaceRef surfaceGetter(id self,SEL selector){(void)selector;return ThinSharedBackingSurface(self);}
static BOOL yes(id self,SEL selector){(void)self;(void)selector;return YES;}
static void noOp(id self,SEL selector){(void)self;(void)selector;}
static void noOpEncoder(id self,SEL selector,id encoder){(void)self;(void)selector;(void)encoder;}
static void noOpValid(id self,SEL selector,BOOL value){(void)self;(void)selector;(void)value;}
static void guestValid(id self,SEL selector,BOOL value){
    (void)selector;
    // old PGTask calls this after preparation for invalidateGuest. The new host
    // forwards only guest-invalidity to the kernel backing; this bounded same-
    // process implementation forwards through a weak associated resource.
    if(!value){ThinSharedMetadata *m=objc_getAssociatedObject(self,&referenceKey);[m.backing setIsGuestValid:NO];}
}

void ThinSharedSetBackingTask(id task,id backingTask){ThinSharedMetadata *m=[ThinSharedMetadata new];m.taskOverride=backingTask;objc_setAssociatedObject(task,&taskKey,m,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
id ThinSharedBackingForReference(id task,uint32_t reference){
    ObjectEntry e=entryFor(task,reference);need((e.word&255)==17,@"shared reference must name type17 backing");
    id resource=[task getHostResource:reference];
    need(resource && objc_getAssociatedObject(resource,&backingKey),@"missing shared backing metadata");return resource;
}

static MTLTextureDescriptor *descriptor53(const uint8_t *op){
    uint8_t synthetic[52],legacy[44];memcpy(synthetic,op,52);uint32_t opcode=52;memcpy(synthetic,&opcode,4);
    ThinTextureExtras extras;const char *error=NULL;
    need(ThinTexture52To1(synthetic,52,legacy,&extras,&error),error?@(error):@"invalid53 descriptor");
    const uint8_t *d=op+12;
    need((d[0]&0x3f)==2 && u16(d+1)==MTLPixelFormatBGRA8Unorm,@"only plain 2D BGRA8 shared texture examined");
    need(u32(d+7)>0&&u32(d+7)<=4096&&u32(d+11)>0&&u32(d+11)<=4096,@"shared dimensions outside bound");
    need(u32(d+15)==1&&u16(d+19)==1&&u16(d+21)==1&&u16(d+23)==1,@"shared mip/depth/sample/array outside bound");
    need((u16(d+25)==0||u16(d+25)==MTLResourceStorageModePrivate)&&u64(d+27)==0,@"shared options/protection outside bound");
    MTLTextureDescriptor *result=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:u32(d+7) height:u32(d+11) mipmapped:NO];
    result.resourceOptions=u16(d+25);result.usage=extras.usage;result.allowGPUOptimizedContents=(d[0]&0x40)!=0;
    result.swizzle=(MTLTextureSwizzleChannels){extras.swizzle[0],extras.swizzle[1],extras.swizzle[2],extras.swizzle[3]};
    if(extras.writeSwizzle){SEL s=NSSelectorFromString(@"setWriteSwizzleEnabled:");need([result respondsToSelector:s],@"write swizzle unsupported");((void(*)(id,SEL,BOOL))objc_msgSend)(result,s,YES);}
    return result;
}

static void prepareBeforeSharing(id backing,id<MTLDevice> device){
    if(![backing needsPrepare])return;
    // New shared-handle lookup requires completed upload before publishing it.
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> buffer=[queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder=[buffer blitCommandEncoder];need(encoder!=nil,@"shared prepare encoder missing");
    [backing prepareInEncoder:encoder];[encoder endEncoding];[buffer commit];[buffer waitUntilCompleted];
    need(buffer.status==MTLCommandBufferStatusCompleted,@"shared backing preparation failed");
}
static void makeSpecial(id task,uint32_t reference,ObjectEntry e){
    unsigned type=e.word&255;uint32_t length=e.word>>8;
    need(type!=18,@"type18 shared dual plane unimplemented");
    need(length<=4096,@"shared object record outside bound");
    const uint8_t *p=[task mappedAddressForOffset:e.address length:length];need(p!=NULL,@"shared object mapping missing");
    id<MTLDevice> device=[task mtlDevice];need(device!=nil,@"task Metal device missing");
    id resource;
    if(type==17){
        need(length==124 && (u16(p+12)&0x3fff)==1,@"expected packed12 + single60 dimension + operation53");
        const uint8_t *op=p+72;need(u32(op)==53&&u32(op+4)==52&&u32(op+8)==reference,@"invalid exact operation53 header/reference");
        need(u64(p)>0&&u64(p)<=1048576,@"shared paging span outside bound");
        MTLTextureDescriptor *d=descriptor53(op);id<MTLTexture> texture=[device newSharedTextureWithDescriptor:d];
        need(texture && texture.isShareable,@"Metal refused shareable backing");
        resource=[[backingClass alloc] initWithTask:task objectType:2 descriptor:p descriptorLength:length texture:texture];
        need(resource!=nil,@"legacy single-plane dimension validation refused shared backing");
        ThinSharedMetadata *m=[ThinSharedMetadata new];m.handle=[texture newSharedTextureHandle];
        need(m.handle!=nil,@"shared texture handle missing");objc_setAssociatedObject(resource,&backingKey,m,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_fetch_add(&backings,1);
    }else{
        need(type==16&&length==12&&u32(p+4)==49&&u32(p+8)==8,@"expected id32 + header-only operation49");
        ThinSharedMetadata *override=objc_getAssociatedObject(task,&taskKey);
        id backingTask=override.taskOverride?:[[task device] getTaskID:0];need(backingTask!=nil,@"kernel backing task missing");
        id backing=ThinSharedBackingForReference(backingTask,u32(p));prepareBeforeSharing(backing,[backingTask mtlDevice]);
        ThinSharedMetadata *source=objc_getAssociatedObject(backing,&backingKey);
        id<MTLTexture> texture=[device newSharedTextureWithHandle:source.handle];need(texture&&texture.isShareable,@"Metal refused shared reference");
        resource=[[referenceClass alloc] initWithTask:task texture:texture];need(resource!=nil,@"legacy view resource missing");
        ThinSharedMetadata *m=[ThinSharedMetadata new];m.backing=backing;objc_setAssociatedObject(resource,&referenceKey,m,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_fetch_add(&references,1);
    }
    [task registerHostResource:resource forReference:reference];
    printf("shared-resource type=%u reference=%u resource=%s registry=PGTask\n",type,reference,object_getClassName(resource));
}
static void makeResource(id task,SEL selector,uint32_t reference){if(!reference){originalMakeResource(task,selector,reference);return;}ObjectEntry e=entryFor(task,reference);if(isSpecial(e.word&255))makeSpecial(task,reference,e);else originalMakeResource(task,selector,reference);}
static void makeTexture(id task,SEL selector,uint32_t reference){if(!reference){originalMakeTexture(task,selector,reference);return;}ObjectEntry e=entryFor(task,reference);if(isSpecial(e.word&255))makeSpecial(task,reference,e);else originalMakeTexture(task,selector,reference);}
static id backingForID(id task,SEL selector,uint32_t reference){if(!reference)return originalBackingForID(task,selector,reference);ObjectEntry e=entryFor(task,reference);if((e.word&255)==17)return ThinSharedBackingForReference(task,reference);return originalBackingForID(task,selector,reference);}
static BOOL pinned(Method m,void *base){Dl_info i={0};return m&&dladdr((void *)method_getImplementation(m),&i)&&i.dli_fbase==base;}
static void add(Class c,const char *name,IMP imp,const char *encoding){need(class_addMethod(c,sel_registerName(name),imp,encoding),@"cannot add bounded shared subclass method");}
BOOL ThinInstallSharedResourceBridge(void *base){
    if(installed)return YES;
    Class task=NSClassFromString(@"PGTask"),single=NSClassFromString(@"PGSinglePlaneTextureResource"),view=NSClassFromString(@"PGTextureViewResource");
    Method mr=class_getInstanceMethod(task,@selector(makeResource:)),mt=class_getInstanceMethod(task,@selector(makeTexture:)),bf=class_getInstanceMethod(task,@selector(backingForID:));
    if(!pinned(mr,base)||!pinned(mt,base)||!pinned(bf,base)||!pinned(class_getInstanceMethod(single,@selector(initWithTask:objectType:descriptor:descriptorLength:texture:)),base)||!pinned(class_getInstanceMethod(view,@selector(initWithTask:texture:)),base))return NO;
    SEL required[]={@selector(getObject:entry:),@selector(mappedAddressForOffset:length:),@selector(getExistingHostResource:),@selector(getHostResource:),@selector(registerHostResource:forReference:),@selector(mtlDevice)};
    for(unsigned i=0;i<sizeof(required)/sizeof(required[0]);i++)if(!pinned(class_getInstanceMethod(task,required[i]),base))return NO;
    backingClass=objc_allocateClassPair(single,"ThinSharedSinglePlaneSpike",0);referenceClass=objc_allocateClassPair(view,"ThinSharedReferenceSpike",0);
    need(backingClass&&referenceClass,@"shared subclass name already present");
    // Old PGBackingResource getIOSurface@0x1ae80 and ioSurface@0x1ae90 are
    // identical loads of the same CF pointer. Keep both bounded aliases.
    add(backingClass,"ioSurface",(IMP)surfaceGetter,"^{__IOSurface=}@:");
    add(backingClass,"getIOSurface",(IMP)surfaceGetter,"^{__IOSurface=}@:");
    add(referenceClass,"isHostValid",(IMP)yes,"B@:");add(referenceClass,"isGuestValid",(IMP)yes,"B@:");
    add(referenceClass,"supportsDiscard",(IMP)yes,"B@:");add(referenceClass,"supportsSynchronize",(IMP)yes,"B@:");add(referenceClass,"setIsGuestValid:",(IMP)guestValid,"v@:B");add(referenceClass,"setIsHostValid:",(IMP)noOpValid,"v@:B");
    add(referenceClass,"prepareInEncoder:",(IMP)noOpEncoder,"v@:@");add(referenceClass,"synchronizeInEncoder:",(IMP)noOpEncoder,"v@:@");add(referenceClass,"discard",(IMP)noOp,"v@:");
    objc_registerClassPair(backingClass);objc_registerClassPair(referenceClass);
    printf("shared-hooks makeResource=%s makeTexture=%s backingForID=%s\n",method_getTypeEncoding(mr),method_getTypeEncoding(mt),method_getTypeEncoding(bf));
    originalMakeResource=(void *)method_setImplementation(mr,(IMP)makeResource);originalMakeTexture=(void *)method_setImplementation(mt,(IMP)makeTexture);originalBackingForID=(void *)method_setImplementation(bf,(IMP)backingForID);installed=YES;return YES;
}
unsigned ThinSharedBackingCount(void){return atomic_load(&backings);}
unsigned ThinSharedReferenceCount(void){return atomic_load(&references);}
