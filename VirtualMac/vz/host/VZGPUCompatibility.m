#import "VZGPUCompatibility.h"
#include <stdlib.h>
NSString * const VZGPUCompatibilityEnabledKey=@"GPUCompatibilityEnabled";
void VZGPUCompatibilityResetForBoot(void){
 unsetenv("VMM_GPU_COMPATIBILITY_ENABLED");unsetenv("VMM_GPU_COMPATIBILITY_STATE_DIR");
}
static BOOL failure(NSError **error,NSString *message){
 VZGPUCompatibilityResetForBoot();
 if(error)*error=[NSError errorWithDomain:@"VMMGPUCompatibility" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO;
}
BOOL VZGPUCompatibilityPrepareForBoot(NSDictionary *options,NSString *runtimeRoot,NSString *stateRoot,NSError **error){
 if(error)*error=nil;VZGPUCompatibilityResetForBoot();
 if(![options[VZGPUCompatibilityEnabledKey] boolValue])return YES;
 NSString *library=[runtimeRoot stringByAppendingPathComponent:@"Frameworks/libVMMGPUCompatibility.dylib"];
 if(![NSFileManager.defaultManager isReadableFileAtPath:library])
  return failure(error,@"Graphics compatibility is unavailable in this runtime. Turn it off or install the complete App runtime.");
 BOOL directory=NO;
 if(![NSFileManager.defaultManager fileExistsAtPath:stateRoot isDirectory:&directory]){
  if(![NSFileManager.defaultManager createDirectoryAtPath:stateRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
 }else if(!directory)return failure(error,@"The App graphics diagnostics directory is unavailable.");
 if(setenv("VMM_GPU_COMPATIBILITY_STATE_DIR",stateRoot.fileSystemRepresentation,1)||setenv("VMM_GPU_COMPATIBILITY_ENABLED","1",1))
  return failure(error,@"Unable to prepare graphics compatibility for this Virtual Mac.");
 return YES;
}
