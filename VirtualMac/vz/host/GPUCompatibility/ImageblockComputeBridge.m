// Independent runtime candidate. Preserve the existing diagnostic/native chain;
// adapt216 on the same encoder. No constructor or AIR conversion.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <objc/message.h>
static void require(BOOL ok,NSString *why){if(!ok)@throw [NSException exceptionWithName:@"ImageblockSpike" reason:why userInfo:nil];}
static uint32_t u32(const void *p){uint32_t v;memcpy(&v,p,4);return v;}
static uint64_t u64(const void *p){uint64_t v;memcpy(&v,p,8);return v;}
static uint8_t *storage(id o){return (uint8_t *)(__bridge void *)o;}
static void set64(id o,size_t at,uint64_t n){memcpy(storage(o)+at,&n,8);}
static void (*savedDecode)(id,SEL,const void *,id);
static void legacy(id d,const void *h,id it){savedDecode(d,sel_registerName("decodeWithHeader:withIterator:"),h,it);}
static void ImageblockDecode(id decoder,const void *header,id iterator){
 Class dc=NSClassFromString(@"MTLDeserializerComputeDecoder"),ic=NSClassFromString(@"MTLByteIterator");
 require(object_getClass(decoder)==dc&&object_getClass(iterator)==ic&&class_getInstanceSize(ic)==32,@"pinned classes required");
 const char *names[]={"buffer","currentOffset","length"};const ptrdiff_t offsets[]={8,16,24};
 for(unsigned i=0;i<3;i++){Ivar v=class_getInstanceVariable(ic,names[i]);require(v&&ivar_getOffset(v)==offsets[i],@"iterator layout");}
 Ivar encoderIvar=class_getInstanceVariable(dc,"computeEncoder");require(encoderIvar&&ivar_getOffset(encoderIvar)==16,@"encoder layout");
 const uint8_t *bytes=NULL;memcpy(&bytes,storage(iterator)+8,8);
 uint64_t start=u64(storage(iterator)+16),length=u64(storage(iterator)+24);BOOL hasImageblock=NO;
 // Keep legacy handling of malformed/trailing and large legacy spans. Only
 // an actual216 record opts this segment into the bounded adaptation path.
 if(!header||!bytes||start>length){legacy(decoder,header,iterator);return;}
 for(uint64_t p=start;p<length;){
  if(length-p<8){legacy(decoder,header,iterator);return;}
  uint32_t op=u32(bytes+p),n=u32(bytes+p+4);
  if(n<8||n>length-p){legacy(decoder,header,iterator);return;}
  hasImageblock|=op==216;p+=n;
 }
 if(!hasImageblock){legacy(decoder,header,iterator);return;}
 require(length-start<=65536,@"imageblock segment exceeds current adapter profile");
 for(uint64_t p=start;p<length;p+=u32(bytes+p+4))if(u32(bytes+p)==216)
  require(u32(bytes+p+4)==16&&u32(bytes+p+8)>0&&u32(bytes+p+12)>0,@"216 exact width/height payload");
 uint8_t continuing[8];memcpy(continuing,header,8);continuing[6]=1;
 uint64_t p=start;
 @try {
  while(p<length){
   if(u32(bytes+p)==216){
    id<MTLComputeCommandEncoder> encoder=object_getIvar(decoder,encoderIvar);
    require(encoder&&[encoder respondsToSelector:@selector(setImageblockWidth:height:)],@"native imageblock setter unavailable");
    [encoder setImageblockWidth:u32(bytes+p+8) height:u32(bytes+p+12)];p+=16;set64(iterator,16,p);
   }else{
    uint64_t end=p;while(end<length&&u32(bytes+end)!=216)end+=u32(bytes+end+4);
    // The pinned legacy loop keeps its encoder/pipeline if header[6] is1.
    // Bound only this iterator's visible end; restore it even on exceptions.
    set64(iterator,24,end);legacy(decoder,continuing,iterator);
    require(u64(storage(iterator)+16)==end,@"legacy run did not consume exact span");p=end;
   }
  }
 }@finally{set64(iterator,24,length);}
 // Empty final legacy run retains native finalization/continuation semantics.
 legacy(decoder,header,iterator);
}
static void computeWithImageblock(id decoder,SEL selector,const void *header,id iterator){
 (void)selector;
 @try{ImageblockDecode(decoder,header,iterator);}
 @catch(NSException *e){((void(*)(id,SEL))objc_msgSend)(decoder,sel_registerName("fault"));@throw e;}
}
BOOL ThinInstallImageblockComputeBridge(void){
 Method m=class_getInstanceMethod(NSClassFromString(@"MTLDeserializerComputeDecoder"),sel_registerName("decodeWithHeader:withIterator:"));
 if(savedDecode||!m||strcmp(method_getTypeEncoding(m),"v32@0:8^{?=ICCC}16@24"))return NO;
 savedDecode=(void *)method_setImplementation(m,(IMP)computeWithImageblock);return YES;
}
