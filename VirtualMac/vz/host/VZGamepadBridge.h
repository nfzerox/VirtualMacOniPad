#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VZGamepadBridgeStateDidChangeNotification;

// Development bridge from one iPadOS GCController to the guest-side HID
// receiver. Virtio socket is the default transport; UDP remains available for
// compatibility with guests that do not expose AF_VSOCK.
@interface VZGamepadBridge : NSObject
+ (instancetype)sharedBridge;
- (void)start;
- (void)attachToVirtualMachine:(id)virtualMachine;
- (void)detachFromVirtualMachine;
- (void)setForegroundActive:(BOOL)active;
- (void)neutralize;
- (void)sendTestState;
- (NSDictionary *)stateSnapshot;
@end

NS_ASSUME_NONNULL_END
