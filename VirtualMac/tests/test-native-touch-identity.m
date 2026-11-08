#import <Foundation/Foundation.h>
#import "../vz/host/VZNativeTouchIdentity.h"
int main(int argc,const char**argv){@autoreleasepool {
 NSString*root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 assert([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:NULL]);
 NSString*a=[root stringByAppendingPathComponent:@"a.plist"],*b=[root stringByAppendingPathComponent:@"b.plist"];
 assert(([@{@"Name":@"Test",@"CPUCount":@4} writeToFile:a atomically:YES]));
 assert(([@{} writeToFile:b atomically:YES]));
 NSError*error=nil;NSString*u=VZNativeTouchUUIDForConfiguration(a,&error);
 assert(u&&error==nil&&[NSUUID.alloc initWithUUIDString:u]);
 assert([u isEqual:VZNativeTouchUUIDForConfiguration(a,&error)]);
 assert(![u isEqual:VZNativeTouchUUIDForConfiguration(b,&error)]);
 assert([[NSDictionary dictionaryWithContentsOfFile:a][@"CPUCount"] isEqual:@4]);
 assert(([@{@"NativeTouchDisplayUUID":@"invalid",@"Name":@"Keep"} writeToFile:b atomically:YES]));
 assert(!VZNativeTouchUUIDForConfiguration(b,&error)&&error);
 assert([[NSDictionary dictionaryWithContentsOfFile:b][@"Name"] isEqual:@"Keep"]);
 assert(!VZNativeTouchUUIDForConfiguration([root stringByAppendingPathComponent:@"missing"],&error));
 assert(!VZNativeTouchValidateRuntime(root,&error));
 assert([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
 if(argc==2)assert(VZNativeTouchValidateRuntime(@(argv[1]),&error));
 puts("native-touch identity persistence passed");return 0;
}}
