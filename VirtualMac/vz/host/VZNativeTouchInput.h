#import <UIKit/UIKit.h>
@class VZNativeTouchContacts;
@interface VZNativeTouchInput:NSObject {
 id _device;
 VZNativeTouchContacts *_contacts;
}
- (instancetype)initWithDevice:(id)device;
// YES means direct fingers were claimed (including starts outside the image).
- (BOOL)handleTouches:(NSSet<UITouch*>*)touches inView:(UIView*)view viewport:(CGRect)viewport;
- (void)cancelAll;
@end
