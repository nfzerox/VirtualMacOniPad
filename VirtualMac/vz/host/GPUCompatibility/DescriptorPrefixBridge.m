#import "DescriptorPrefixBridge.h"
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <string.h>
#include "RuntimeLog.h"

typedef struct {uint32_t length;uint8_t type,previous,next,padding;} ThinPrefixHeader;
_Static_assert(sizeof(ThinPrefixHeader)==8,"segment header ABI");
static id (*prefixOriginal)(id,SEL,const ThinPrefixHeader *,id,id,id);
static Class prefixIteratorClass,prefixTaskClass;
static Ivar prefixDelegate,prefixBuffer,prefixOffset,prefixLength;
static _Atomic unsigned prefixCompute,prefixRender,prefixRejected;
static void prefixNeed(BOOL ok,NSString *reason) {
    if(!ok)@throw [NSException exceptionWithName:@"ThinDescriptorPrefix" reason:reason userInfo:nil];
}
static uint32_t prefixU32(const void *p){uint32_t v;memcpy(&v,p,4);return v;}
static BOOL prefixABI(id object,SEL selector,const char *abi) {
    Method m=class_getInstanceMethod(object_getClass(object),selector);
    return m && [object respondsToSelector:selector] && !strcmp(method_getTypeEncoding(m),abi);
}

// An old render decoder retains this forwarding object. Pending state is consumed
// once, so later continuation segments cannot reapply a descriptor prefix.
@interface ThinPrefixCommandBuffer : NSObject
@property(nonatomic,strong) id real;
@property(nonatomic,strong) id createdEncoder;
@property(nonatomic) BOOL compute,used,hasRaster,hasColor;
@property(nonatomic) NSUInteger dispatchType,raster,color;
@end
@implementation ThinPrefixCommandBuffer
-(id)forwardingTargetForSelector:(SEL)selector{return self.real;}
-(BOOL)respondsToSelector:(SEL)selector{return [super respondsToSelector:selector]||[self.real respondsToSelector:selector];}
-(id)computeCommandEncoder {
    prefixNeed(self.compute&&!self.used,@"compute descriptor prefix consumed more than once");
    SEL selector=NSSelectorFromString(@"computeCommandEncoderWithDispatchType:");
    prefixNeed(prefixABI(self.real,selector,"@24@0:8Q16"),@"native compute dispatchType selector ABI mismatch");
    self.used=YES;
    id encoder=((id(*)(id,SEL,NSUInteger))objc_msgSend)(self.real,selector,self.dispatchType);
    prefixNeed(encoder!=nil,@"native compute encoder creation failed");
    self.createdEncoder=encoder;return encoder;
}
-(id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    prefixNeed(!self.compute&&!self.used&&descriptor,@"render descriptor prefix consumed more than once");
    SEL raster=NSSelectorFromString(@"setDefaultRasterSampleCount:");
    SEL color=NSSelectorFromString(@"setDefaultColorSampleCount:");
    SEL rasterGet=NSSelectorFromString(@"defaultRasterSampleCount");
    SEL colorGet=NSSelectorFromString(@"defaultColorSampleCount");
    // Validate every requested setter before mutating the descriptor.
    prefixNeed(!self.hasRaster||prefixABI(descriptor,raster,"v24@0:8Q16"),@"native raster sampleCount setter ABI mismatch");
    prefixNeed(!self.hasColor||prefixABI(descriptor,color,"v24@0:8Q16"),@"native color sampleCount setter ABI mismatch");
    prefixNeed(!self.hasRaster||prefixABI(descriptor,rasterGet,"Q16@0:8"),@"native raster sampleCount getter ABI mismatch");
    prefixNeed(!self.hasColor||prefixABI(descriptor,colorGet,"Q16@0:8"),@"native color sampleCount getter ABI mismatch");
    prefixNeed(prefixABI(self.real,@selector(renderCommandEncoderWithDescriptor:),"@24@0:8@16"),@"native render encoder selector ABI mismatch");
    if(self.hasRaster)((void(*)(id,SEL,NSUInteger))objc_msgSend)(descriptor,raster,self.raster);
    if(self.hasColor)((void(*)(id,SEL,NSUInteger))objc_msgSend)(descriptor,color,self.color);
    prefixNeed(!self.hasRaster||((NSUInteger(*)(id,SEL))objc_msgSend)(descriptor,rasterGet)==self.raster,@"native descriptor did not retain raster sampleCount");
    prefixNeed(!self.hasColor||((NSUInteger(*)(id,SEL))objc_msgSend)(descriptor,colorGet)==self.color,@"native descriptor did not retain color sampleCount");
    self.used=YES;self.hasRaster=NO;self.hasColor=NO;
    id encoder=[self.real renderCommandEncoderWithDescriptor:descriptor];
    prefixNeed(encoder!=nil,@"native render encoder creation failed");
    self.createdEncoder=encoder;return encoder;
}
@end

static id prefixDecode(id decoder,SEL selector,const ThinPrefixHeader *incoming,id iterator,id carried,id commandBuffer) {
    if(!incoming)return prefixOriginal(decoder,selector,incoming,iterator,carried,commandBuffer);
    id task=object_getIvar(decoder,prefixDelegate);
    if(object_getClass(task)!=prefixTaskClass||
       ((id(*)(id,SEL))objc_msgSend)(task,NSSelectorFromString(@"deserializer"))!=decoder)
        return prefixOriginal(decoder,selector,incoming,iterator,carried,commandBuffer);
    // The legacy decoder's carried path bypasses its type>=4 check. Protection
    // envelopes are unsupported even when a native decoder is already carried.
    if(incoming->type==5){atomic_fetch_add(&prefixRejected,1);VMMThinRuntimeRecord("protected-segment-rejected",5,0,incoming->length,UINT32_MAX);prefixNeed(NO,@"protection envelope type5 is unsupported");}
    // Pure legacy and continuation paths otherwise preserve the old walker.
    if(incoming->previous||carried)return prefixOriginal(decoder,selector,incoming,iterator,carried,commandBuffer);
    if(object_getClass(iterator)!=prefixIteratorClass)
        return prefixOriginal(decoder,selector,incoming,iterator,carried,commandBuffer);
    uint8_t *object=(uint8_t *)(__bridge void *)iterator;
    const uint8_t *buffer;uint64_t offset,length;
    memcpy(&buffer,object+ivar_getOffset(prefixBuffer),sizeof(buffer));
    memcpy(&offset,object+ivar_getOffset(prefixOffset),sizeof(offset));
    memcpy(&length,object+ivar_getOffset(prefixLength),sizeof(length));
    // Reading the first word needs valid native iterator bounds. The pinned outer
    // walker has already read/truncated the segment header; no guest offset write.
    if(!buffer||offset>length||length-offset<4||(uintptr_t)buffer>UINTPTR_MAX-length)
        return prefixOriginal(decoder,selector,incoming,iterator,carried,commandBuffer);
    uint32_t first=prefixU32(buffer+offset);
    if(first!=219&&first!=30&&first!=31)
        return prefixOriginal(decoder,selector,incoming,iterator,carried,commandBuffer);
    @try {
        ThinPrefixHeader header;memcpy(&header,incoming,8);
        prefixNeed(header.type<=1,@"descriptor prefix in unsupported encoder type");
        prefixNeed(header.previous==0&&header.next<=1,@"invalid descriptor prefix continuation flags");
        prefixNeed(offset==8&&length==header.length&&length>=8&&length<=65536,@"descriptor prefix iterator bounds");
        prefixNeed((uintptr_t)buffer<=UINTPTR_MAX-length,@"descriptor prefix pointer overflow");
        // Immutable, bounded private bytes stay live through synchronous decode.
        __attribute__((objc_precise_lifetime)) NSData *copy=[NSData dataWithBytes:buffer+offset length:(NSUInteger)(length-offset)];
        const uint8_t *p=copy.bytes;NSUInteger n=copy.length,skip=0;
        __attribute__((objc_precise_lifetime)) ThinPrefixCommandBuffer *wrapper=[ThinPrefixCommandBuffer new];
        wrapper.real=commandBuffer;wrapper.compute=header.type==1;
        prefixNeed(commandBuffer!=nil,@"descriptor prefix requires native command buffer");
        if(header.type==1) {
            prefixNeed(n>=12&&prefixU32(p)==219&&prefixU32(p+4)==12,@"compute prefix requires exact219/12");
            uint32_t dispatchType=prefixU32(p+8);
            prefixNeed(dispatchType<=1,@"unsupported compute dispatchType");
            wrapper.dispatchType=dispatchType;skip=12;
            prefixNeed(prefixABI(commandBuffer,NSSelectorFromString(@"computeCommandEncoderWithDispatchType:"),"@24@0:8Q16"),@"native compute dispatchType unavailable");
        } else {
            // Target order: optional30, optional31, then exact unchanged26.
            while(skip<n&&n-skip>=8&&(prefixU32(p+skip)==30||prefixU32(p+skip)==31)) {
                uint32_t opcode=prefixU32(p+skip);
                prefixNeed(n-skip>=12&&prefixU32(p+skip+4)==12,@"render prefix requires exact30/31 length12");
                uint32_t value=prefixU32(p+skip+8);
                prefixNeed(value!=0&&value!=0xfffffffeu,@"invalid render default sampleCount");
                if(opcode==30){prefixNeed(!wrapper.hasRaster&&!wrapper.hasColor,@"duplicate/out-of-order raster prefix");wrapper.hasRaster=YES;wrapper.raster=value;}
                else{prefixNeed(!wrapper.hasColor,@"duplicate color prefix");wrapper.hasColor=YES;wrapper.color=value;}
                skip+=12;
            }
            prefixNeed(skip>0&&n-skip>=0x250&&prefixU32(p+skip)==26&&prefixU32(p+skip+4)==0x250,@"render prefix must precede exact26 descriptor");
            MTLRenderPassDescriptor *check=[MTLRenderPassDescriptor renderPassDescriptor];
            prefixNeed(!wrapper.hasRaster||prefixABI(check,NSSelectorFromString(@"setDefaultRasterSampleCount:"),"v24@0:8Q16"),@"native raster setter unavailable");
            prefixNeed(!wrapper.hasColor||prefixABI(check,NSSelectorFromString(@"setDefaultColorSampleCount:"),"v24@0:8Q16"),@"native color setter unavailable");
        }
        // Validate record framing before any native encoder is created. Additional
        // new descriptor commands are rejected, never silently skipped.
        for(NSUInteger at=skip;at<n;) {
            prefixNeed(n-at>=8,@"trailing bytes after descriptor prefix");
            uint32_t opcode=prefixU32(p+at),recordLength=prefixU32(p+at+4);
            prefixNeed(recordLength>=8&&!(recordLength&3)&&recordLength<=n-at,@"record framing after descriptor prefix");
            prefixNeed(opcode!=219&&opcode!=30&&opcode!=31,@"duplicate descriptor prefix in body");
            at+=recordLength;
        }
        __attribute__((objc_precise_lifetime)) id stableIterator=((id(*)(id,SEL,void *,uint64_t))objc_msgSend)([prefixIteratorClass alloc],NSSelectorFromString(@"initWithBuffer:withLength:"),(void *)p,(uint64_t)n);
        ((void(*)(id,SEL,uint64_t))objc_msgSend)(stableIterator,NSSelectorFromString(@"advance:"),(uint64_t)skip);
        id result=prefixOriginal(decoder,selector,&header,stableIterator,nil,wrapper);
        prefixNeed(wrapper.used,@"descriptor prefix did not select native encoder");
        uint64_t consumed;memcpy(&consumed,(uint8_t *)(__bridge void *)stableIterator+ivar_getOffset(prefixOffset),8);
        prefixNeed(consumed<=n,@"private iterator exceeded bounded copy");
        ((void(*)(id,SEL,uint64_t))objc_msgSend)(iterator,NSSelectorFromString(@"advance:"),consumed);
        atomic_fetch_add(header.type==1?&prefixCompute:&prefixRender,1);
        return result;
    } @catch(NSException *e) {atomic_fetch_add(&prefixRejected,1);VMMThinRuntimeRecord("descriptor-prefix-rejected",first,0,length,UINT32_MAX);@throw;}
}

BOOL ThinInstallDescriptorPrefixBridge(void *serializerBase) {
    Class decoder=NSClassFromString(@"_MTLDeserializer"),iterator=NSClassFromString(@"MTLByteIterator"),task=NSClassFromString(@"PGTask");
    Method method=class_getInstanceMethod(decoder,NSSelectorFromString(@"decodeSegmentWithHeader:withIterator:withDecoder:into:"));
    Ivar delegate=class_getInstanceVariable(decoder,"_objectDelegate");
    Ivar buffer=class_getInstanceVariable(iterator,"buffer"),offset=class_getInstanceVariable(iterator,"currentOffset"),length=class_getInstanceVariable(iterator,"length");
    if(!serializerBase||!method||!task||!delegate||!buffer||!offset||!length)return NO;
    if(strcmp(method_getTypeEncoding(method),"@48@0:8^{?=ICCC}16@24@32@40")||
       ivar_getOffset(delegate)!=40||strcmp(ivar_getTypeEncoding(delegate),"@\"<MTLDeserializerObjectDelegate>\"")||
       class_getInstanceSize(iterator)!=32||ivar_getOffset(buffer)!=8||strcmp(ivar_getTypeEncoding(buffer),"^v")||
       ivar_getOffset(offset)!=16||strcmp(ivar_getTypeEncoding(offset),"Q")||
       ivar_getOffset(length)!=24||strcmp(ivar_getTypeEncoding(length),"Q"))return NO;
    const char *names[]={"initWithBuffer:withLength:","advance:"};
    const char *abis[]={"@32@0:8^v16Q24","v24@0:8Q16"};
    for(unsigned i=0;i<2;i++) {
        Method m=class_getInstanceMethod(iterator,sel_registerName(names[i]));Dl_info origin={0};
        if(!m||strcmp(method_getTypeEncoding(m),abis[i])||!dladdr((const void *)method_getImplementation(m),&origin)||origin.dli_fbase!=serializerBase)return NO;
    }
    IMP current=method_getImplementation(method);
    if(current==(IMP)prefixDecode)return prefixOriginal!=NULL;
    Dl_info origin={0};if(!dladdr((const void *)current,&origin)||origin.dli_fbase!=serializerBase)return NO;
    prefixIteratorClass=iterator;prefixTaskClass=task;prefixDelegate=delegate;prefixBuffer=buffer;prefixOffset=offset;prefixLength=length;
    prefixOriginal=(void *)method_setImplementation(method,(IMP)prefixDecode);return YES;
}
unsigned ThinDescriptorComputeCount(void){return atomic_load(&prefixCompute);}
unsigned ThinDescriptorRenderCount(void){return atomic_load(&prefixRender);}
unsigned ThinDescriptorRejectedCount(void){return atomic_load(&prefixRejected);}
