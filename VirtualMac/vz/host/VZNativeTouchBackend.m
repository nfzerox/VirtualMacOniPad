// Experimental, exact-runtime binding. Runs only in the VMM backend.
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <ptrauth.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include "VZNativeTouchCore.h"
#include "VZNativeTouchImages.h"
static char nativeUUID[37];
static bool nativeEnabled,nativeInstalled;
static atomic_bool displayWritten,publicationWritten;
static id (*nativeOriginalInit)(id,SEL,id,unsigned long long,unsigned int);
static const void *nativeMainImage;
static void nativeRefuse(const char*reason) {fprintf(stderr,"[NativeTouch] backend refused: %s\n",reason);abort();}
static id nativeNubInit(id self,SEL sel,id device,unsigned long long port,unsigned int page) {
 id result=nativeOriginalInit(self,sel,device,port,page);
 if(!result||!nativeEnabled||port!=0)return result;
 Ivar field=class_getInstanceVariable(object_getClass(result),"_sharedState");
 if(!field||ivar_getOffset(field)!=0x20||ivar_getTypeEncoding(field)[0]!='^')nativeRefuse("sharedState layout");
 unsigned char*shared=NULL;memcpy(&shared,(unsigned char*)(void*)result+0x20,sizeof(shared));
 vm_address_t address=(vm_address_t)shared;vm_size_t length=0;vm_region_basic_info_data_64_t info={0};mach_msg_type_number_t n=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t object=0;
 kern_return_t kr=shared?vm_region_64(mach_task_self(),&address,&length,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&n,&object):KERN_INVALID_ADDRESS;
 if(object)mach_port_deallocate(mach_task_self(),object);
 if(kr!=KERN_SUCCESS||address>(vm_address_t)shared||((vm_address_t)shared-address)>length||(info.protection&(VM_PROT_READ|VM_PROT_WRITE))!=(VM_PROT_READ|VM_PROT_WRITE))nativeRefuse("sharedState mapping");
 size_t available=length-((vm_address_t)shared-address);
 if(atomic_exchange(&displayWritten,true)||!VZTouchWriteDisplayUUID(shared,available,port,nativeUUID))nativeRefuse("display identity field/mode");
 fprintf(stderr,"[NativeTouch] display UUID supplied: %s\n",nativeUUID);return result;
}
void VZNativeTouchBackendInstall(bool required) {
 if(!nativeEnabled||nativeInstalled)return;
 Class c=objc_getClass("_PGDisplayNub");Method m=c?class_getInstanceMethod(c,sel_registerName("initWithDevice:port:sharedStatePage:")):NULL;
 if(!m){if(required)nativeRefuse("PVG init unavailable");return;}
 Ivar f=class_getInstanceVariable(c,"_sharedState");Dl_info image={0};
 void*pc=ptrauth_strip((void*)method_getImplementation(m),ptrauth_key_function_pointer);
 static const unsigned char expected[]={0x73,0x20,0x73,0xab,0x34,0xe5,0x38,0xc9,0xa9,0x19,0x53,0xb6,0x28,0x97,0x7b,0xdb};
 if(!f||ivar_getOffset(f)!=0x20||!dladdr(pc,&image)||!VZTouchImageUUID(image.dli_fbase,expected)||(uintptr_t)pc-(uintptr_t)image.dli_fbase!=0x13908)nativeRefuse("PVG image/init profile");
 nativeOriginalInit=(void*)method_setImplementation(m,(IMP)nativeNubInit);nativeInstalled=true;
}
static CFDictionaryRef nativeDictionary(CFAllocatorRef a,const void**keys,const void**values,CFIndex count,const CFDictionaryKeyCallBacks*kc,const CFDictionaryValueCallBacks*vc) {
 CFDictionaryRef d=CFDictionaryCreate(a,keys,values,count,kc,vc);
 if(!d||!nativeEnabled||count!=4)return d;
 const CFStringRef expected[]={CFSTR("Manufacturer"),CFSTR("Product"),CFSTR("Built-In"),CFSTR("DisplayIntegrated")};
 for(int i=0;i<4;i++)if(!CFDictionaryContainsKey(d,expected[i]))return d;
 CFTypeRef product=CFDictionaryGetValue(d,CFSTR("Product"));
 if(!product||CFGetTypeID(product)!=CFStringGetTypeID()||!CFEqual(product,CFSTR("Virtual Touch Screen"))||CFDictionaryGetValue(d,CFSTR("Built-In"))!=kCFBooleanTrue||CFDictionaryGetValue(d,CFSTR("DisplayIntegrated"))!=kCFBooleanTrue)return d;
 void*pc=ptrauth_strip(__builtin_return_address(0),ptrauth_key_return_address);Dl_info image={0};
 if(!dladdr(pc,&image)||image.dli_fbase!=nativeMainImage||(uintptr_t)pc-(uintptr_t)image.dli_fbase!=0x41d1c||atomic_exchange(&publicationWritten,true))nativeRefuse("initial HID dictionary profile");
 CFMutableDictionaryRef result=CFDictionaryCreateMutableCopy(NULL,0,d);CFStringRef uuid=CFStringCreateWithCString(NULL,nativeUUID,kCFStringEncodingUTF8);
 if(!result||!uuid)nativeRefuse("HID identity allocation");
 CFDictionarySetValue(result,CFSTR("displayUUID"),uuid);CFRelease(uuid);CFRelease(d);
 fprintf(stderr,"[NativeTouch] HID displayUUID published: %s\n",nativeUUID);return result;
}
__attribute__((used)) static const struct{const void*replacement;const void*original;} nativeDictionaryInterpose __attribute__((section("__DATA,__interpose")))={(const void*)nativeDictionary,(const void*)CFDictionaryCreate};
__attribute__((constructor)) static void nativeBackendInit(void) {
 const char*enabled=getenv("VMM_NATIVE_TOUCH_ENABLED"),*uuid=getenv("VMM_NATIVE_TOUCH_UUID");
 if(!enabled||strcmp(enabled,"1"))return;
 // This compatibility dylib must remain inert if another process loads it.
 char executable[PATH_MAX];uint32_t capacity=sizeof(executable);
 if(_NSGetExecutablePath(executable,&capacity)!=0||!VZTouchBackendProcess(executable))return;
 static const unsigned char expected[]={0xba,0xc4,0x51,0xc3,0x70,0xab,0x32,0x59,0xb7,0x7e,0x91,0xf5,0x67,0x3d,0x15,0xe1};
 uint32_t count=_dyld_image_count();
 if(count==0||count>4096)nativeRefuse("image count");
 const void **headers=calloc(count,sizeof(*headers));if(!headers)nativeRefuse("image allocation");
 for(uint32_t i=0;i<count;i++)headers[i]=_dyld_get_image_header(i);
 nativeMainImage=VZTouchFindExecutable(headers,count,expected);free(headers);
 if(!VZTouchUUIDValid(uuid)||!nativeMainImage)nativeRefuse("backend executable image/UUID profile");
 memcpy(nativeUUID,uuid,37);nativeEnabled=true;
 VZNativeTouchBackendInstall(false);
}
