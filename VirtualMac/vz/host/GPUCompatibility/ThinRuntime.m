#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <pthread.h>
#include "ThinRuntime.h"
#include "RuntimeLog.h"
#include "FifoBridge.h"
#include "InfoBridge.h"
#include "TextureBridge.h"
#include "SharedResourceBridge.h"
#include "DescriptorPrefixBridge.h"
#include "StencilDescriptorBridge.h"
#include "NegotiationBridge.h"
#include "BackendBridge.h"
#include "DeviceInfoBridge.h"
#include "CommandDiagnostics.h"
extern NSArray *VMMThinRuntimeDiagnostics(void);
extern BOOL ThinInstallImageblockComputeBridge(void);
static pthread_mutex_t installLock=PTHREAD_MUTEX_INITIALIZER;
static BOOL configured,active,failed;
static uint32_t configuredCeiling=43;
static NSDictionary *identity;
static void *configuredPVGBase;
static NSString *configuredPVG,*configuredSerializer;
static const char *pvgHash="bc3e1f9c9400162be3c930ab3fd42e5aba1c32a456f96fc6dc0e74e6935ec8a8";
static const char *serializerHash="525c9d0e1bed56b32ec37e081dcc65222eb4391d313a6e2860c58dfaceeb5843";
static void need(BOOL ok,NSString *why){if(!ok)@throw [NSException exceptionWithName:@"VMMThinPreflight" reason:why userInfo:nil];}
static NSString *checkedText(const char *path,const char *expected){
    need(path!=NULL,@"missing image path");NSData *data=[NSData dataWithContentsOfFile:@(path)];need(data.length>=sizeof(struct mach_header_64),@"cannot read Mach-O image");
    const uint8_t *bytes=data.bytes;const struct mach_header_64 *header=(const void *)bytes;
    need(header->magic==MH_MAGIC_64&&header->cputype==CPU_TYPE_ARM64,@"expected thin arm64 image");
    size_t cursor=sizeof(*header),end=cursor+header->sizeofcmds;need(end<=data.length,@"load commands outside image");
    for(uint32_t i=0;i<header->ncmds;i++){
        need(cursor<=end&&sizeof(struct load_command)<=end-cursor,@"truncated load command");
        const struct load_command *command=(const void *)(bytes+cursor);need(command->cmdsize>=8&&command->cmdsize<=end-cursor,@"invalid load command size");
        if(command->cmd==LC_SEGMENT_64){
            need(command->cmdsize>=sizeof(struct segment_command_64),@"short segment");
            const struct segment_command_64 *segment=(const void *)command;
            need(segment->nsects<=(command->cmdsize-sizeof(*segment))/sizeof(struct section_64),@"invalid section count");
            const struct section_64 *sections=(const void *)(segment+1);
            for(uint32_t j=0;j<segment->nsects;j++)if(!strncmp(sections[j].sectname,"__text",16)&&!strncmp(sections[j].segname,"__TEXT",16)){
                uint64_t start=sections[j].offset,length=sections[j].size;need(start<=data.length&&length<=data.length-start&&length<=UINT32_MAX,@"text section outside image");
                unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes+start,(CC_LONG)length,hash);NSMutableString *hex=[NSMutableString new];
                for(unsigned k=0;k<sizeof(hash);k++)[hex appendFormat:@"%02x",hash[k]];
                need([hex isEqualToString:@(expected)],@"unsupported image text hash; no hooks installed");return hex;
            }
        }
        cursor+=command->cmdsize;
    }
    need(NO,@"text section missing");return nil;
}
// Factory symbols may be interposed by the existing compatibility image.
// Select the actual loaded image by exact canonical file identity instead.
static void *pinnedLoadedImage(const char *path){
    char expected[PATH_MAX];need(path&&realpath(path,expected),@"cannot canonicalize pinned image path");
    uint32_t count=_dyld_image_count();need(count>0&&count<=4096,@"invalid loaded image count");void *found=NULL;
    for(uint32_t i=0;i<count;i++){
        const char *name=_dyld_get_image_name(i);char actual[PATH_MAX];
        if(name&&realpath(name,actual)&&!strcmp(actual,expected)){
            need(found==NULL,@"pinned image loaded more than once");found=(void *)_dyld_get_image_header(i);
        }
    }
    need(found!=NULL,@"exact pinned image is not loaded");return found;
}
static NSArray *savedMethods(void *pvg,void *serializer){
    NSArray *specs=@[
      @[@"MTLDeserializerBlitDecoder",@"decodeWithHeader:withIterator:",@"v32@0:8^{?=ICCC}16@24",@1],@[@"MTLDeserializerEventDecoder",@"decodeWithHeader:withIterator:",@"v32@0:8^{?=ICCC}16@24",@1],
      @[@"MTLDeserializerRenderDecoder",@"decodeWithHeader:withIterator:",@"v32@0:8^{?=ICCC}16@24",@1],@[@"MTLDeserializerComputeDecoder",@"decodeWithHeader:withIterator:",@"v32@0:8^{?=ICCC}16@24",@1],
      @[@"_PGDevice",@"getDeviceInfo:length:dst:",@"v28@0:8I16I20I24",@0],
      @[@"_PGDevice",@"setBinaryVersion:",@"v20@0:8I16",@0],@[@"_PGDevice",@"mmioReadAtOffset:",@"I24@0:8Q16",@0],
      @[@"_PGDevice",@"willSuspend",@"v16@0:8",@0],@[@"_PGDevice",@"finishSuspend",@"@16@0:8",@0],
      @[@"_PGDevice",@"willResumeWithSuspendState:error:",@"B32@0:8@16^@24",@0],
      @[@"PGRootFIFO",@"latchCommandOffset",@"v16@0:8",@0],@[@"PGRootFIFO",@"getFifoBytes:into:",@"B32@0:8Q16^v24",@0],
      @[@"PGChildFIFO",@"latchCommandOffset",@"v16@0:8",@0],@[@"PGChildFIFO",@"getFifoBytes:into:",@"B32@0:8Q16^v24",@0],
      @[@"PGFIFO",@"CmdExecIndirect2:stampValue:withPayload:payloadSize:",@"v44@0:8^{?=SSII}16I24^v28Q36",@0],
      @[@"PGFIFO",@"CmdDeleteResource:stampValue:withPayload:payloadSize:",@"v44@0:8^{?=SSII}16I24^v28Q36",@0],
      @[@"_MTLDeserializer",@"operationWithSerializedData:serializedDataSize:allocator:",@"B40@0:8r*16Q24@32",@1],
      @[@"_MTLDeserializer",@"decodeSegments:lengths:count:into:",@"v48@0:8^^v16^Q24Q32@40",@1],
      @[@"_MTLDeserializer",@"getBufferForReference:",@"@20@0:8I16",@1],
      @[@"_MTLDeserializer",@"newTextureWithIOSurface:serializedData:serializedDataSize:allocator:",@"v48@0:8^{__IOSurface=}16r*24Q32@40",@1],
      @[@"_MTLDeserializer",@"decodeSegmentWithHeader:withIterator:withDecoder:into:",@"@48@0:8^{?=ICCC}16@24@32@40",@1],
      @[@"PGDualPlaneBlitTextureResource",@"initWithTask:objectType:descriptor:descriptorLength:texture:",@"@48@0:8@16I24^v28I36@40",@0],
      @[@"PGTask",@"makeResource:",@"v20@0:8I16",@0],@[@"PGTask",@"makeTexture:",@"v20@0:8I16",@0],@[@"PGTask",@"backingForID:",@"@20@0:8I16",@0]
    ];NSMutableArray *saved=[NSMutableArray new];
    for(NSArray *spec in specs){Method m=class_getInstanceMethod(NSClassFromString(spec[0]),NSSelectorFromString(spec[1]));need(m!=NULL,@"missing pinned method");
        IMP imp=method_getImplementation(m);Dl_info origin={0};need(dladdr((const void *)imp,&origin)&&origin.dli_fbase==([spec[3] boolValue]?serializer:pvg),[NSString stringWithFormat:@"%@ %@ belongs to %s; expected pinned image",spec[0],spec[1],origin.dli_fname?:"unresolved"]);
        NSString *abi=spec[2];if(abi.length)need(!strcmp(method_getTypeEncoding(m),abi.UTF8String),@"method ABI mismatch");
        [saved addObject:@[[NSValue valueWithPointer:m],[NSValue valueWithPointer:(const void *)imp]]];
    }
    return saved;
}
bool VMMThinRuntimeInitialize(const VMMThinConfiguration *c,char *error,size_t capacity){
    pthread_mutex_lock(&installLock);BOOL result=NO;NSArray *saved=nil;
    @try {
        need(c&&c->abiVersion==VMM_THIN_RUNTIME_ABI,@"runtime ABI mismatch");need(c->advertisedVersion==43||c->advertisedVersion==237,@"only ceiling43 or explicit preview237 supported");
        need(c->enabled||c->advertisedVersion==43,@"preview237 requires the enabled compatibility runtime");
        need(!failed,@"earlier install failed; restart the independent process before retry");
        if(configured){need(configuredCeiling==c->advertisedVersion,@"startup ceiling is immutable");need(active==c->enabled,@"startup mode is immutable; restart to change it");
            if(active)need(c->pvgPath&&c->serializerPath&&[configuredPVG isEqualToString:@(c->pvgPath)]&&[configuredSerializer isEqualToString:@(c->serializerPath)],@"image paths are immutable after initialization");result=YES;}
        else if(!c->enabled){configured=YES;active=NO;result=YES;}
        else {
            NSString *pvgText=checkedText(c->pvgPath,pvgHash),*serializerText=checkedText(c->serializerPath,serializerHash);
            void *pvg=dlopen(c->pvgPath,RTLD_NOW|RTLD_LOCAL),*serializer=dlopen(c->serializerPath,RTLD_NOW|RTLD_LOCAL);need(pvg&&serializer,@"cannot load pinned libraries");
            need(dlsym(pvg,"PGNewDeviceWithDescriptor")&&dlsym(serializer,"MTLCreateDeserializerForDeviceWithDelegate"),@"missing pinned factory symbols");
            void *pvgImage=pinnedLoadedImage(c->pvgPath),*serializerImage=pinnedLoadedImage(c->serializerPath);
            saved=savedMethods(pvgImage,serializerImage);
            need(ThinInstallCommandDiagnostics(serializerImage),@"command diagnostic hooks failed");
            need(ThinInstallImageblockComputeBridge(),@"imageblock compute adapter failed");
            if(c->advertisedVersion==237)need(ThinInstallImageblockDeviceInfoBridge(pvgImage),@"imageblock device info adapter failed");
            need(ThinInstallTextureBridge(serializerImage),@"texture bridge installation failed");
            need(ThinInstallRootFIFOBridge(pvgImage),@"FIFO bridge installation failed");
            need(ThinInstallSharedResourceBridge(pvgImage),@"shared-resource bridge installation failed");
            need(ThinInstallInlineInfoBridge(serializerImage),@"inline Info bridge installation failed");
            need(ThinInstallDescriptorPrefixBridge(serializerImage),@"descriptor prefix bridge installation failed");
            need(ThinInstallStencilDescriptorBridge(pvgImage),@"stencil descriptor bridge installation failed");
            if(c->advertisedVersion==237)need(ThinInstallNegotiationBridge(pvgImage),@"negotiation bridge installation failed");
            configuredPVGBase=pvgImage;ThinEnableInfo();configuredCeiling=c->advertisedVersion;identity=@{@"pvgTextSHA256":pvgText,@"serializerTextSHA256":serializerText};configuredPVG=@(c->pvgPath);configuredSerializer=@(c->serializerPath);configured=YES;active=YES;result=YES;
            VMMThinRuntimePrint("runtime-install ABI=1 ceiling=%u native-ceiling=43 explicit-device-attach-required=%u\n",configuredCeiling,configuredCeiling==237);
        }
        if(error&&capacity)error[0]=0;
    } @catch(NSException *e){
        result=NO;
        if(saved){
            for(NSArray *item in saved)method_setImplementation([item[0] pointerValue],(IMP)[item[1] pointerValue]);
            failed=YES;configured=NO;active=NO;configuredCeiling=43;identity=nil;configuredPVG=nil;configuredSerializer=nil;
        }
        if(error&&capacity)snprintf(error,capacity,"%s",e.reason.UTF8String);
        @try {VMMThinRuntimeRecord("preflight-rejected",0,0,0,0);}
        @catch(NSException *loggingFailure){(void)loggingFailure;}
    } @finally {pthread_mutex_unlock(&installLock);}
    return result;
}
bool VMMThinRuntimeInstallBackendHooks(char *error,size_t capacity){
    pthread_mutex_lock(&installLock);BOOL result=NO;
    @try {need(active&&configuredCeiling==237,@"backend hooks require enabled preview237");
        need(ThinInstallBackendBridge(configuredPVGBase),@"backend boundary image/ABI/layout mismatch; hooks not installed");
        result=YES;if(error&&capacity)error[0]=0;
    } @catch(NSException *e){if(error&&capacity)snprintf(error,capacity,"%s",e.reason.UTF8String);}
    @finally {pthread_mutex_unlock(&installLock);}return result;
}
id VMMThinRuntimeWrapDevice(id<MTLDevice> device){return active?ThinSharedEventDevice(device):device;}
bool VMMThinRuntimeConfigureFirstUnknownFile(const char *path,char *error,size_t capacity){
    pthread_mutex_lock(&installLock);BOOL result=!configured&&!failed&&ThinCommandSetOutputPath(path);
    if(error&&capacity)snprintf(error,capacity,"%s",result?"":"configure a new absolute first-error path before initialization");
    pthread_mutex_unlock(&installLock);return result;
}
char *VMMThinRuntimeCopyFirstUnknownJSON(void){
    NSData *data=[NSJSONSerialization dataWithJSONObject:ThinCommandFirstUnknown() options:NSJSONWritingSortedKeys error:nil];
    char *copy=calloc(1,data.length+1);if(copy)memcpy(copy,data.bytes,data.length);return copy;
}
char *VMMThinRuntimeCopyStatusJSON(void){
    NSDictionary *status=@{@"abi":@1,@"configured":@(configured),@"active":@(active),@"installFailed":@(failed),@"maximumAdvertisedVersion":@(configured?configuredCeiling:43),@"nativeVersionCeiling":@43,@"negotiationPreview":@(active&&configuredCeiling==237),
       @"backend":ThinBackendBridgeStatus(),@"identity":identity?:@{},@"diagnostics":VMMThinRuntimeDiagnostics(),@"scope":@"experimental macOS27 graphics compatibility runtime"};
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:0 error:nil];if(!data)return NULL;
    char *copy=calloc(1,data.length+1);if(copy)memcpy(copy,data.bytes,data.length);return copy;
}
bool VMMThinRuntimeAttachDevice(id device,char *error,size_t capacity){
    if(!active||configuredCeiling!=237){if(error&&capacity)snprintf(error,capacity,"initialize enabled preview237 before attachment");return false;}
    return ThinAttachNegotiationDevice(device,237,error,capacity);
}
char *VMMThinRuntimeCopyDeviceStatusJSON(id device){
    if(!active||configuredCeiling!=237)return NULL;NSDictionary *state=ThinNegotiationDeviceStatus(device);if(!state)return NULL;
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];if(!data)return NULL;
    char *copy=calloc(1,data.length+1);if(copy)memcpy(copy,data.bytes,data.length);return copy;
}
void VMMThinRuntimeFree(void *pointer){free(pointer);}
