#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString * const VZGPUCompatibilityEnabledKey;
BOOL VZGPUCompatibilityPrepareForBoot(NSDictionary *options,NSString *runtimeRoot,NSString *stateRoot,NSError **error);
void VZGPUCompatibilityResetForBoot(void);
