#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
typedef BOOL (*Prepare)(NSDictionary *,NSString *,NSString *,NSError **);
typedef void (*Reset)(void);
static void require(BOOL value,const char *message){if(!value){fprintf(stderr,"FAIL %s\n",message);exit(1);}}
int main(void){@autoreleasepool{
 Prepare prepare=(Prepare)dlsym(RTLD_DEFAULT,"VZGPUCompatibilityPrepareForBoot");
 Reset reset=(Reset)dlsym(RTLD_DEFAULT,"VZGPUCompatibilityResetForBoot");
 require(prepare&&reset,"GPU compatibility boot lifecycle is missing");
 NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString *runtime=[root stringByAppendingPathComponent:@"payload"],*state=[root stringByAppendingPathComponent:@"state"];
 NSError *error=nil;
 setenv("VMM_NATIVE_TOUCH_ENABLED","1",1);
 setenv("VMM_GPU_COMPATIBILITY_ENABLED","1",1);setenv("VMM_GPU_COMPATIBILITY_STATE_DIR","/old-vm-state",1);
 require(prepare(@{@"GPUCompatibilityEnabled":@NO},@"/missing-runtime",state,&error),"disabled VM must keep the legacy path without a GPU library");
 require(!getenv("VMM_GPU_COMPATIBILITY_ENABLED")&&!getenv("VMM_GPU_COMPATIBILITY_STATE_DIR"),"disabled VM must clear preceding VM graphics state");
 require(!strcmp(getenv("VMM_NATIVE_TOUCH_ENABLED"),"1"),"GPU mode must not alter native touch selection");
 require(!prepare(@{@"GPUCompatibilityEnabled":@YES},runtime,state,&error)&&error!=nil,"enabled mode must reject missing runtime component");
 require(!getenv("VMM_GPU_COMPATIBILITY_ENABLED"),"failed preparation must leave GPU mode disabled");
 NSString *frameworks=[runtime stringByAppendingPathComponent:@"Frameworks"];
 require([NSFileManager.defaultManager createDirectoryAtPath:frameworks withIntermediateDirectories:YES attributes:nil error:NULL],"fixture directory");
 require([[@"fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[frameworks stringByAppendingPathComponent:@"libVMMGPUCompatibility.dylib"] atomically:YES],"fixture library presence; backend owns ABI validation");
 require(prepare(@{@"GPUCompatibilityEnabled":@YES},runtime,state,&error)&&error==nil,"enabled VM must prepare its own graphics startup");
 require(getenv("VMM_GPU_COMPATIBILITY_ENABLED")&&!strcmp(getenv("VMM_GPU_COMPATIBILITY_ENABLED"),"1"),"enabled VM must opt in explicitly");
 require(getenv("VMM_GPU_COMPATIBILITY_STATE_DIR")&&!strcmp(getenv("VMM_GPU_COMPATIBILITY_STATE_DIR"),state.fileSystemRepresentation),"startup diagnostics must use current App state");
 require(prepare(@{},@"/missing-runtime",state,&error),"older VM configs must default to the legacy path");
 require(!getenv("VMM_GPU_COMPATIBILITY_ENABLED"),"enabled to older VM transition must clear GPU profile");
 require(prepare(@{@"GPUCompatibilityEnabled":@YES},runtime,state,&error),"a following enabled VM can opt in again");
 reset();require(!getenv("VMM_GPU_COMPATIBILITY_ENABLED")&&!getenv("VMM_GPU_COMPATIBILITY_STATE_DIR"),"VM stop must clear all GPU startup state");
 require(!strcmp(getenv("VMM_NATIVE_TOUCH_ENABLED"),"1"),"cleanup must preserve independently owned touch environment");
 unsetenv("VMM_NATIVE_TOUCH_ENABLED");[NSFileManager.defaultManager removeItemAtPath:root error:NULL];
 puts("GPU compatibility VM transitions passed: on/off/on, missing library, stop cleanup, native touch preserved");return 0;
}}
