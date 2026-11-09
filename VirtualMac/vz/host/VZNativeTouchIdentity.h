#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString * const VZNativeTouchEnabledKey;
FOUNDATION_EXPORT NSString * const VZNativeTouchDisplayUUIDKey;
// Preserve existing VM options; refuse missing/malformed plist or stored UUID.
NSString *VZNativeTouchUUIDForConfiguration(NSString *path,NSError **error);
// Exact Stage9/12 backend/PVG binaries. A new extraction needs revalidation.
BOOL VZNativeTouchValidateRuntime(NSString *payloadRoot,NSError **error);
