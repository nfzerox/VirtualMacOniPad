// Loaded with the existing backend compatibility module. Inert in the UIKit
// host, other executables, and when the selected VM leaves compatibility off.
#import <Foundation/Foundation.h>
#import "GPUCompatibility/ThinRuntime.h"
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <limits.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
static void refuse(const char *why){fprintf(stderr,"[GraphicsCompatibility] startup refused: %s\n",why);abort();}
__attribute__((constructor)) static void graphicsCompatibilityBootstrap(void){@autoreleasepool{
 const char *enabled=getenv("VMM_GPU_COMPATIBILITY_ENABLED");if(!enabled||strcmp(enabled,"1"))return;
 char executable[PATH_MAX],actual[PATH_MAX],expected[PATH_MAX];uint32_t n=sizeof executable;
 if(_NSGetExecutablePath(executable,&n)||!realpath(executable,actual))return;
 Dl_info module={0};if(!dladdr((const void *)graphicsCompatibilityBootstrap,&module)||!module.dli_fname)return;
 char modulePath[PATH_MAX];if(!realpath(module.dli_fname,modulePath))return;
 NSString *frameworks=[@(modulePath) stringByDeletingLastPathComponent];
 NSString *root=[frameworks stringByDeletingLastPathComponent];
 NSString *backend=[root stringByAppendingPathComponent:@"VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"];
 if(!realpath(backend.fileSystemRepresentation,expected)||strcmp(actual,expected))return;
 const char *debug=getenv("VZ_DEBUG_LOGGING");
 if((debug&&strcmp(debug,"0"))||getenv("PVG_TRACE_METHODS"))refuse("legacy method tracing must be disabled for this profile");
 NSString *library=[frameworks stringByAppendingPathComponent:@"libVMMGPUCompatibility.dylib"];
 void *image=dlopen(library.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);if(!image)refuse(dlerror());
 bool(*initialize)(const VMMThinConfiguration *,char *,size_t)=dlsym(image,"VMMThinRuntimeInitialize");
 bool(*configure)(const char *,char *,size_t)=dlsym(image,"VMMThinRuntimeConfigureFirstUnknownFile");
 bool(*install)(char *,size_t)=dlsym(image,"VMMThinRuntimeInstallBackendHooks");
 char *(*status)(void)=dlsym(image,"VMMThinRuntimeCopyStatusJSON");void(*release)(void *)=dlsym(image,"VMMThinRuntimeFree");
 if(!initialize||!configure||!install||!status||!release)refuse("compatibility runtime API missing");
 // A package may load both existing compat modules. They share this one core
 // dylib, so only its first owner configures the exclusive diagnostics file.
 char *text=status();if(!text)refuse("compatibility runtime status unavailable");
 NSDictionary *state=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:text length:strlen(text)] options:0 error:NULL];release(text);
 if(![state isKindOfClass:NSDictionary.class])refuse("compatibility runtime status invalid");
 char error[256]={0};
 if(![state[@"configured"] boolValue]){
  const char *directory=getenv("VMM_GPU_COMPATIBILITY_STATE_DIR");if(!directory||directory[0]!='/')refuse("App diagnostics directory missing");
  NSString *path=[@(directory) stringByAppendingPathComponent:[NSString stringWithFormat:@"gpu-first-unknown.%d.%@.json",getpid(),NSUUID.UUID.UUIDString]];
  if(!configure(path.fileSystemRepresentation,error,sizeof error))refuse(error);
 }
 NSString *pvg=[frameworks stringByAppendingPathComponent:@"ParavirtualizedGraphics.framework/ParavirtualizedGraphics"];
 NSString *serializer=[frameworks stringByAppendingPathComponent:@"MetalSerializer.framework/MetalSerializer"];
 VMMThinConfiguration configuration={VMM_THIN_RUNTIME_ABI,237,true,pvg.fileSystemRepresentation,serializer.fileSystemRepresentation};
 if(!initialize(&configuration,error,sizeof error)||!install(error,sizeof error))refuse(error);
 fprintf(stderr,"[GraphicsCompatibility] ready: ImageBlocks profile; TileShaders disabled; cold startup\n");
}}
