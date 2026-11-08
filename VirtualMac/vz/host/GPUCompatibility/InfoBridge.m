#import "InfoBridge.h"
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>
#include "ThinBridge.h"
#include "CommandDiagnostics.h"
#include "GPUCompatibilityLogMacros.h"
#include "TextureBridge.h"

// Query/completion reference: reims-vgpu at 1fe0acb, tasks/local/info.rs;
// target-specific queries are checked against the ARM guest and old host ABI.
// See docs/macos27-research-references.md for sources and scope.

static BOOL enabled;
static _Atomic unsigned waiting,completed,restored,rejected,rejectionReturned;
static _Atomic(uintptr_t) faultingFIFO;
static _Thread_local ThinTextureExtras *queryExtras;
static void (*originalDecodeSegments)(id,SEL,const void **,const uint64_t *,NSUInteger,id);
static Ivar inlineDelegateIvar;
static _Atomic unsigned inlineCompleted,inlineRejected,inlineLegacyRuns;
static _Atomic unsigned computeInfoCompleted,imageblockInfoCompleted;
static uint32_t u32(const void *p){uint32_t v;memcpy(&v,p,4);return v;}
static uint64_t u64(const void *p){uint64_t v;memcpy(&v,p,8);return v;}
static void p32(void *p,uint32_t v){memcpy(p,&v,4);}
static void need(BOOL ok,NSString *reason) {
    if(!ok)@throw [NSException exceptionWithName:@"ThinInfo" reason:reason userInfo:nil];
}

// Per-device forwarding wrapper; leaves the real device class untouched.
@interface ThinInfoDevice : NSObject
@property(nonatomic,strong) id<MTLDevice> real;
@end
@implementation ThinInfoDevice
-(id)forwardingTargetForSelector:(SEL)selector{return self.real;}
-(BOOL)respondsToSelector:(SEL)selector{return [super respondsToSelector:selector]||[self.real respondsToSelector:selector];}
-(id<MTLEvent>)newEvent{return [self.real newSharedEvent];}
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    return [self.real newTextureWithDescriptor:ThinRestoreTextureDescriptor(d)];
}
-(id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)d {
    return ThinWrapHeap([self.real newHeapWithDescriptor:d]);
}
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {
    return [self.real newTextureWithDescriptor:ThinRestoreTextureDescriptor(d) iosurface:surface plane:plane];
}
-(MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)descriptor {
    if(!queryExtras)return [self.real heapTextureSizeAndAlignWithDescriptor:descriptor];
    ThinTextureExtras *e=queryExtras;
    MTLTextureDescriptor *copy=[descriptor copy];copy.usage=e->usage;
    copy.swizzle=(MTLTextureSwizzleChannels){e->swizzle[0],e->swizzle[1],e->swizzle[2],e->swizzle[3]};
    if(e->writeSwizzle) {
        SEL setter=NSSelectorFromString(@"setWriteSwizzleEnabled:");
        need([copy respondsToSelector:setter],@"write-swizzle setter unavailable");
        ((void(*)(id,SEL,BOOL))objc_msgSend)(copy,setter,YES);
    }
    atomic_fetch_add(&restored,1);
    return [self.real heapTextureSizeAndAlignWithDescriptor:copy];
}
@end
id ThinSharedEventDevice(id<MTLDevice> device) {
    if(!device||object_getClass(device)==[ThinInfoDevice class])return device;
    ThinInfoDevice *wrapper=[ThinInfoDevice new];wrapper.real=device;
    for(NSString *name in @[@"prepareResources:count:event:value:",@"getObject:entry:",@"mappedAddressForOffset:length:",@"runBlock:"]) {
        Method m=class_getInstanceMethod(NSClassFromString(@"PGTask"),NSSelectorFromString(name));
        printf("Info-method %s ABI=%s\n",name.UTF8String,m?method_getTypeEncoding(m):"missing");
    }
    return wrapper;
}

@interface ThinInfoAllocator : NSObject
@property(nonatomic,strong) NSMutableData *data;
@end
@implementation ThinInfoAllocator
-(void *)allocateOperationBytes:(NSUInteger)length {
    need(length==16,@"unexpected heap reply allocation");
    self.data=[NSMutableData dataWithLength:length];return self.data.mutableBytes;
}
@end

// Matches the pinned runtime encoding {PGTaskPrepareSync_s=BB@Q}, 24 bytes.
typedef struct {BOOL wait,sync;__unsafe_unretained id event;uint64_t value;} PrepareSync;
_Static_assert(sizeof(PrepareSync)==24,"old prepare ABI");

static void waitFor(id<MTLSharedEvent> event,uint64_t value) {
    need([event respondsToSelector:@selector(signaledValue)],@"PVG event is not CPU-signallable");
    struct timespec start,now;clock_gettime(CLOCK_MONOTONIC,&start);
    if(event.signaledValue<value)atomic_fetch_add(&waiting,1);
    while(event.signaledValue<value) {
        clock_gettime(CLOCK_MONOTONIC,&now);
        double elapsed=(now.tv_sec-start.tv_sec)+(now.tv_nsec-start.tv_nsec)/1e9;
        need(elapsed<5.0,@"previous GPU event wait timed out");usleep(1000);
    }
}
static void *mapped(id task,uint64_t offset,uint64_t length) {
    void *address=((void *(*)(id,SEL,uint64_t,uint64_t))objc_msgSend)(task,
        NSSelectorFromString(@"mappedAddressForOffset:length:"),offset,length);
    need(address!=NULL,@"task memory mapping unavailable");return address;
}
static void *replyAddressSized(id task,uint32_t reference,uint64_t offset,uint64_t replyBytes) {
    need(replyBytes>0&&replyBytes<=28,@"reply size outside bounded query profile");
    need(reference!=0,@"nil reply buffer");uint8_t entry[12];
    ((void(*)(id,SEL,uint32_t,void *))objc_msgSend)(task,NSSelectorFromString(@"getObject:entry:"),reference,entry);
    uint32_t bits=u32(entry),type=bits&255,recordLength=bits>>8;
    need(type==1||type==19,@"reply object is not a buffer or CPU buffer");
    need(recordLength>=(type==1?16u:12u)&&recordLength<=4096,@"reply buffer record length");
    const uint8_t *record=mapped(task,u64(entry+4),recordLength);
    uint64_t length=u64(record),base=(uint64_t)u32(record+8)<<14;
    need(length>=replyBytes && offset<=length-replyBytes,@"reply buffer range exceeded");
    need(offset<=UINT64_MAX-base-replyBytes-0x3fff,@"reply address overflow");
    // Map whole touched pages, avoiding the old unaligned-range rounding path.
    uint64_t start=(base+offset)&~UINT64_C(0x3fff);
    uint64_t end=(base+offset+replyBytes+0x3fff)&~UINT64_C(0x3fff);
    need(end>start && end-start<=0x8000,@"reply page span invalid");
    return (uint8_t *)mapped(task,start,end-start)+(base+offset-start);
}
static void *replyAddress(id task,uint32_t reference,uint64_t offset){return replyAddressSized(task,reference,offset,16);}
static void computeQuery(id task,const uint8_t *payload,size_t length){
    need(length==16,@"450 requires exact16-byte query payload");
    id<MTLComputePipelineState> pipeline=((id(*)(id,SEL,uint32_t))objc_msgSend)(task,NSSelectorFromString(@"getComputePipelineStateForReference:"),u32(payload));
    need(pipeline!=nil,@"450 compute pipeline reference is nil");
    void *destination=replyAddressSized(task,u32(payload+4),u64(payload+8),28);
    // Exact27 consumer: low32 of each NSUInteger, zero-extended to u64;
    // one boolean byte and three unspecified padding bytes initialized to zero.
    uint8_t reply[28]={0};
    uint64_t fields[]={(uint32_t)pipeline.maxTotalThreadsPerThreadgroup,(uint32_t)pipeline.threadExecutionWidth,(uint32_t)pipeline.staticThreadgroupMemoryLength};
    memcpy(reply,fields,24);reply[24]=(uint8_t)pipeline.supportIndirectCommandBuffers;
    memcpy(destination,reply,28);
    unsigned n=atomic_fetch_add(&computeInfoCompleted,1);
    if(n<8)printf("INFO450-APPLIED reply-bytes=28 low32-counts=3\n");
}
static void imageblockQuery(id task,const uint8_t *payload,size_t length){
    need(length==40,@"459 requires exact40-byte query payload");
    id<MTLComputePipelineState> pipeline=((id(*)(id,SEL,uint32_t))objc_msgSend)(task,NSSelectorFromString(@"getComputePipelineStateForReference:"),u32(payload));
    need(pipeline!=nil,@"459 compute pipeline reference is nil");
    void *destination=replyAddressSized(task,u32(payload+28),u64(payload+32),4);
    MTLSize dimensions=MTLSizeMake(u64(payload+4),u64(payload+12),u64(payload+20));
    // Exact27 guest consumes a low-u32 byte length. Resource lookup, mapping,
    // waits and FIFO completion belong to the existing450/469 Info paths.
    uint32_t bytes=(uint32_t)[pipeline imageblockMemoryLengthForDimensions:dimensions];
    p32(destination,bytes);
    if(atomic_fetch_add(&imageblockInfoCompleted,1)<8)printf("INFO459-APPLIED reply-bytes=4 imageblock-bytes=%u\n",bytes);
}
static void heapQuery(id task,const uint8_t *payload,size_t length) {
    need(length==52,@"469 requires the exact 52-byte bounded payload");
    uint8_t wire[52]={0},legacy[44],query[40]={0};
    p32(wire,52);p32(wire+4,52);memcpy(wire+12,payload,39);
    ThinTextureExtras extras;const char *error=NULL;
    need(ThinTexture52To1(wire,sizeof(wire),legacy,&extras,&error),error?@(error):@"descriptor2 conversion failed");
    p32(query,22);p32(query+4,40);memcpy(query+8,legacy+12,32);
    void *reply=replyAddress(task,u32(payload+40),u64(payload+44));
    id decoder=((id(*)(id,SEL))objc_msgSend)(task,NSSelectorFromString(@"deserializer"));
    ThinInfoAllocator *allocator=[ThinInfoAllocator new];
    BOOL accepted=NO;unsigned before=atomic_load(&restored);queryExtras=&extras;
    @try {accepted=((BOOL(*)(id,SEL,const void *,NSUInteger,id))objc_msgSend)(decoder,
        NSSelectorFromString(@"operationWithSerializedData:serializedDataSize:allocator:"),query,sizeof(query),allocator);}
    @finally {queryExtras=NULL;}
    need(accepted&&allocator.data.length==16&&atomic_load(&restored)==before+1,@"old heap query failed or usage was not restored");
    memcpy(reply,allocator.data.bytes,16);
}

static void inlineNeed(BOOL ok,NSString *reason) {
    if(!ok)@throw [NSException exceptionWithName:@"ThinInlineInfo" reason:reason userInfo:nil];
}
static void decodeWithInlineInfo(id decoder,SEL selector,const void **segments,const uint64_t *lengths,NSUInteger count,id commandBuffer) {
    // Leave unbounded arrays and the overwhelmingly common all-legacy path
    // to the original full-array walker. Only bounded mixed arrays are adapted.
    if(!count||count>4096){originalDecodeSegments(decoder,selector,segments,lengths,count,commandBuffer);return;}
    inlineNeed(segments&&lengths,@"missing segment arrays");
    BOOL hasInfo=NO;
    for(NSUInteger i=0;i<count;i++) {
        if(lengths[i]<8)continue;
        inlineNeed(segments[i]!=NULL,@"nil segment");
        if(((const uint8_t *)segments[i])[4]==4||((const uint8_t *)segments[i])[4]==5){hasInfo=YES;break;}
    }
    if(!hasInfo){originalDecodeSegments(decoder,selector,segments,lengths,count,commandBuffer);return;}
    id task=object_getIvar(decoder,inlineDelegateIvar);
    Class taskClass=NSClassFromString(@"PGTask");
    if(!taskClass||![task isKindOfClass:taskClass]||
        ((id(*)(id,SEL))objc_msgSend)(task,NSSelectorFromString(@"deserializer"))!=decoder) {
        originalDecodeSegments(decoder,selector,segments,lengths,count,commandBuffer);return;
    }
    NSUInteger copiedBytes=0;
    @try {
        inlineNeed(count<=64,@"mixed/protected array exceeds bounded64 profile");
        // Guest mappings may change concurrently. Parse and execute only bounded
        // private copies once a mixed array needs adaptation; legacy-only arrays
        // still use the original walker without changes.
        __attribute__((objc_precise_lifetime)) NSMutableArray<NSData *> *copies=[NSMutableArray arrayWithCapacity:count];
        const void *stableSegments[64];uint64_t stableLengths[64];
        for(NSUInteger i=0;i<count;i++) {
            inlineNeed(segments[i]&&lengths[i]>=8&&lengths[i]<=65536,@"mixed segment bounds");
            NSData *copy=[NSData dataWithBytes:segments[i] length:(NSUInteger)lengths[i]];
            [copies addObject:copy];stableSegments[i]=copy.bytes;stableLengths[i]=copy.length;copiedBytes+=copy.length;
        }
        segments=stableSegments;lengths=stableLengths;
        // Validate the entire mixed array before encoding GPU work or writing
        // any CPU reply. Unlike the reference's ignored1..7-byte tail, this
        // bounded adapter requires exact Info records and exact Info spans.
        for(NSUInteger i=0;i<count;i++) {
            inlineNeed(segments[i]&&lengths[i]>=8&&lengths[i]<=65536,@"mixed segment bounds");
            const uint8_t *s=segments[i];uint32_t total=u32(s);
            inlineNeed(total>=8&&total<=lengths[i],@"mixed segment length");
            inlineNeed(s[4]<=4,@"protected/unknown encoder refused before native walk");
            if(s[4]==4) {
                inlineNeed(!s[5]&&!s[6],@"Info continuation is outside bounded adapter");
                inlineNeed(total==lengths[i],@"Info span has trailing bytes");
                if(i)inlineNeed(!((const uint8_t *)segments[i-1])[6],@"legacy continuation crosses into Info");
                if(i+1<count) {
                    inlineNeed(segments[i+1]&&lengths[i+1]>=8,@"segment after Info is truncated");
                    inlineNeed(!((const uint8_t *)segments[i+1])[5],@"continuation crosses out of Info");
                }
                size_t cursor=8;
                while(cursor<total) {
                    inlineNeed(total-cursor>=8,@"Info trailing partial record");
                    uint32_t opcode=u32(s+cursor),bytes=u32(s+cursor+4);
                    inlineNeed(bytes>=8&&bytes<=total-cursor,@"Info record bounds");
                    inlineNeed((opcode==469&&bytes==60)||(opcode==450&&bytes==24)||(opcode==459&&bytes==48),@"inline Info only supports exact450/459/469 records");
                    // Verify reply range before either legacy run is encoded.
                    if(opcode==450)replyAddressSized(task,u32(s+cursor+12),u64(s+cursor+16),28);
                    else if(opcode==459)replyAddressSized(task,u32(s+cursor+36),u64(s+cursor+40),4);
                    else replyAddress(task,u32(s+cursor+48),u64(s+cursor+52));
                    cursor+=bytes;
                }
            }
        }
        NSUInteger start=0;
        while(start<count) {
            const uint8_t *s=segments[start];
            if(s[4]==4) {
                uint32_t total=u32(s);
                for(size_t cursor=8;cursor<total;cursor+=u32(s+cursor+4)) {
                    if(u32(s+cursor)==450)computeQuery(task,s+cursor+8,16);
                    else if(u32(s+cursor)==459)imageblockQuery(task,s+cursor+8,40);
                    else heapQuery(task,s+cursor+8,52);
                    atomic_fetch_add(&inlineCompleted,1);
                }
                start++;
            } else {
                NSUInteger end=start+1;
                while(end<count&&((const uint8_t *)segments[end])[4]!=4)end++;
                // Never send continuation segments one at a time: the old
                // walker carries its decoder only within one full array call.
                originalDecodeSegments(decoder,selector,segments+start,lengths+start,end-start,commandBuffer);
                atomic_fetch_add(&inlineLegacyRuns,1);start=end;
            }
        }
        // No commit here: the original PGTask67 path owns its command buffer,
        // completion callbacks and GPU commit.69 retains its uncommitted path.
    } @catch(NSException *e) {
        atomic_fetch_add(&inlineRejected,1);
        fprintf(stderr,"Inline Info rejected: %s\n",e.reason.UTF8String);
#ifdef THIN_RUNTIME_LIBRARY
        VMMThinRuntimeRecord("inline-info-rejected",469,0,copiedBytes,UINT32_MAX);
#endif
        @throw e;
    }
}
BOOL ThinInstallInlineInfoBridge(void *serializerBase) {
    Class cls=NSClassFromString(@"_MTLDeserializer");
    SEL selector=NSSelectorFromString(@"decodeSegments:lengths:count:into:");
    Method method=class_getInstanceMethod(cls,selector);Ivar delegate=class_getInstanceVariable(cls,"_objectDelegate");
    if(!method||!delegate||!serializerBase)return NO;
    const char *abi=method_getTypeEncoding(method),*type=ivar_getTypeEncoding(delegate);
    if(strcmp(abi,"v48@0:8^^v16^Q24Q32@40")||ivar_getOffset(delegate)!=40||
        strcmp(type,"@\"<MTLDeserializerObjectDelegate>\""))return NO;
    IMP current=method_getImplementation(method);
    if(current==(IMP)decodeWithInlineInfo)return originalDecodeSegments!=NULL;
    Dl_info origin={0};
    if(!dladdr((void *)current,&origin)||origin.dli_fbase!=serializerBase)return NO;
    printf("INLINE-INFO-hook ABI=%s delegate-offset=%td type=%s\n",abi,ivar_getOffset(delegate),type);
    inlineDelegateIvar=delegate;
    originalDecodeSegments=(void *)method_setImplementation(method,(IMP)decodeWithInlineInfo);
    return YES;
}
unsigned ThinInlineInfoCompletedCount(void){return atomic_load(&inlineCompleted);}
unsigned ThinInlineInfoRejectedCount(void){return atomic_load(&inlineRejected);}
unsigned ThinInlineInfoLegacyRunCount(void){return atomic_load(&inlineLegacyRuns);}

void ThinHandleInfo(id fifo,uint32_t stamp,const void *payload,size_t length) {
    @try {
        need(length>=12&&length<=65536,@"Info payload size");
        size_t expanded=0;const char *error=NULL;
        NSMutableData *legacy=[NSMutableData dataWithLength:length*3];
        need(ThinExec3To2(payload,length,legacy.mutableBytes,legacy.length,&expanded,&error),error?@(error):@"Info counts/flags");
        ThinCommandObserveExecPadding(payload,length);
        const uint8_t *p=payload;uint32_t taskID=u32(p),resources=u32(p+4),buffers=u32(p+8);
        id device=[fifo valueForKey:@"device"];
        id task=((id(*)(id,SEL,uint32_t))objc_msgSend)(device,NSSelectorFromString(@"getTaskID:"),taskID);
        need(task!=nil,@"Info task unavailable");
        id<MTLSharedEvent> event=[fifo valueForKey:@"fifoEvent"];
        uint64_t value=[[fifo valueForKey:@"fifoEventValue"] unsignedLongLongValue];
        need(value!=UINT64_MAX,@"event counter wrap outside spike");
        waitFor(event,value);
        ((void(*)(id,SEL,id))objc_msgSend)(task,NSSelectorFromString(@"runBlock:"),^{
            PrepareSync prepared=((PrepareSync(*)(id,SEL,const void *,uint32_t,id,uint64_t))objc_msgSend)(task,
                NSSelectorFromString(@"prepareResources:count:event:value:"),(uint8_t *)legacy.mutableBytes…722 tokens truncated…nfo69-rejected",69,stamp,length,slot);
#endif
        atomic_store(&faultingFIFO,(uintptr_t)(__bridge void *)fifo);
        atomic_fetch_add(&rejected,1);
        ((void(*)(id,SEL,uint32_t))objc_msgSend)(fifo,NSSelectorFromString(@"faultAtStampValue:"),stamp);
        ((void(*)(id,SEL,uint32_t))objc_msgSend)(fifo,NSSelectorFromString(@"signalStampValue:"),stamp);
        atomic_fetch_add(&rejectionReturned,1);
    }
}
void ThinEnableInfo(void){enabled=YES;}
BOOL ThinInfoEnabled(void){return enabled;}
unsigned ThinInfoWaitingCount(void){return atomic_load(&waiting);}
unsigned ThinInfoCompletedCount(void){return atomic_load(&completed);}
unsigned ThinInfoRejectedCount(void){return atomic_load(&rejected);}
BOOL ThinInfoFaultActive(void) {
    uintptr_t pointer=atomic_load(&faultingFIFO);if(!pointer)return NO;
    return [[(__bridge id)(void *)pointer valueForKey:@"faulted"] boolValue];
}
unsigned ThinInfoRejectionReturnedCount(void){return atomic_load(&rejectionReturned);}
