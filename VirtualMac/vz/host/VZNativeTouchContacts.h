#import <Foundation/Foundation.h>
#include "VZNativeTouchCore.h"
// UIKit-independent tracker: bounded stable IDs and complete contact frames.
@interface VZNativeTouchContacts:NSObject {
 NSMutableDictionary *_contacts;
 VZTouchRect _viewport;
}
// Changes: token(object identity), phase(UIKit 0..4), x/y(view coordinates).
// Frames: index(0..9), phase(VZ 0..4), x/y(normalized), token(retained).
- (NSArray<NSDictionary*>*)update:(NSArray<NSDictionary*>*)changes viewport:(VZTouchRect)viewport;
- (NSArray<NSDictionary*>*)cancelAll;
@end
