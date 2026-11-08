#import "VZNativeTouchIdentity.h"
#import <CommonCrypto/CommonDigest.h>
NSString * const VZNativeTouchEnabledKey=@"NativeTouchEnabled";
NSString * const VZNativeTouchDisplayUUIDKey=@"NativeTouchDisplayUUID";
static BOOL nativeError(NSError**error,NSString*message) {
 if(error)*error=[NSError errorWithDomain:@"VMMNativeTouch" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO;
}
NSString *VZNativeTouchUUIDForConfiguration(NSString*path,NSError**error) {
 if(error)*error=nil;
 NSDictionary*saved=[NSDictionary dictionaryWithContentsOfFile:path];
 if(!saved){nativeError(error,@"Native touch requires a valid, saved VM configuration.");return nil;}
 id old=saved[VZNativeTouchDisplayUUIDKey];
 if(old){
  if(![old isKindOfClass:NSString.class]||![[[NSUUID alloc]initWithUUIDString:old] autorelease]){nativeError(error,@"The VM has an invalid native touch display UUID.");return nil;}
  return [old uppercaseString];
 }
 NSMutableDictionary*updated=[[saved mutableCopy]autorelease];NSString*uuid=NSUUID.UUID.UUIDString;
 updated[VZNativeTouchDisplayUUIDKey]=uuid;
 NSData*data=[NSPropertyListSerialization dataWithPropertyList:updated format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
 if(!data||![data writeToFile:path options:NSDataWritingAtomic error:error])return nil;
 return uuid;
}
BOOL VZNativeTouchValidateRuntime(NSString*root,NSError**error) {
 if(error)*error=nil;
 NSDictionary*profile=@{
  @"Frameworks/Virtualization.framework/Virtualization":@"fc6d5e4ffba3d77728aa32e440dc5524e8c87f2142c8ee813c51c9f207206539",
  @"VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine":@"2f8f813777559ee15f2903b3cb4f55118fbbd26ce5a5f07141181776ce179d4a",
  @"Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics":@"3512e12ca89f29d1e3e27ced5df9483931475f2fa7451403a1d6dd6a73ddb61b"};
 for(NSString*relative in profile){
  NSData*data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:relative] options:NSDataReadingMappedIfSafe error:NULL];
  if(!data)return nativeError(error,@"Native touch requires the validated Ventura research runtime; a required image is missing.");
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString*hex=[NSMutableString string];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
  if(![hex isEqual:profile[relative]])return nativeError(error,@"Native touch is not validated for this runtime. Disable Native Touch or revalidate the backend/PVG profile.");
 }
 return YES;
}
