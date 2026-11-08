#import "VZNativeTouchInput.h"
#import "VZNativeTouchContacts.h"
#import <objc/message.h>
@implementation VZNativeTouchInput
- (instancetype)initWithDevice:(id)device {
 if((self=[super init])){_device=[device retain];_contacts=[[VZNativeTouchContacts alloc]init];}return self;
}
- (void)dealloc {[_contacts release];[_device release];[super dealloc];}
- (void)sendFrame:(NSArray*)frame {
 if(!frame.count)return;
 NSMutableSet*touches=[NSMutableSet set];
 for(NSDictionary*r in frame){
  CGPoint p=CGPointMake([r[@"x"] doubleValue],[r[@"y"] doubleValue]);
  id touch=((id(*)(id,SEL,unsigned char,NSInteger,CGPoint,NSInteger,double))objc_msgSend)([NSClassFromString(@"_VZTouch") alloc],NSSelectorFromString(@"initWithIndex:phase:location:swipeAim:timestamp:"),[r[@"index"] unsignedCharValue],[r[@"phase"] integerValue],p,0,NSProcessInfo.processInfo.systemUptime);
  if(touch){[touches addObject:touch];[touch release];}
 }
 id event=((id(*)(id,SEL,id))objc_msgSend)([NSClassFromString(@"_VZMultiTouchEvent") alloc],NSSelectorFromString(@"initWithTouches:"),touches);
 if(event){((void(*)(id,SEL,id))objc_msgSend)(_device,NSSelectorFromString(@"sendMultiTouchEvents:"),@[event]);[event release];}
}
- (BOOL)handleTouches:(NSSet<UITouch*>*)touches inView:(UIView*)view viewport:(CGRect)v {
 NSMutableArray*changes=[NSMutableArray array];
 for(UITouch*t in touches)if(t.type==UITouchTypeDirect){CGPoint p=[t locationInView:view];[changes addObject:@{@"token":t,@"phase":@(t.phase),@"x":@(p.x),@"y":@(p.y)}];}
 if(!changes.count)return NO;
 [self sendFrame:[_contacts update:changes viewport:(VZTouchRect){v.origin.x,v.origin.y,v.size.width,v.size.height}]];return YES;
}
- (void)cancelAll {[self sendFrame:[_contacts cancelAll]];}
@end
