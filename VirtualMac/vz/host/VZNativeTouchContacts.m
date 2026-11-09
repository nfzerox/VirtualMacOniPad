#import "VZNativeTouchContacts.h"
@implementation VZNativeTouchContacts
- (instancetype)init {if((self=[super init]))_contacts=[[NSMutableDictionary alloc]init];return self;}
- (void)dealloc {[_contacts release];[super dealloc];}
- (NSArray*)orderedContacts {
 return [[_contacts allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){return [a[@"index"] compare:b[@"index"]];}];
}
- (NSArray*)cancelAll {
 NSMutableArray*frame=[NSMutableArray array];
 for(NSDictionary*d in [self orderedContacts]){NSMutableDictionary*c=[[d mutableCopy]autorelease];c[@"phase"]=@4;[frame addObject:c];}
 [_contacts removeAllObjects];return frame;
}
- (NSArray*)update:(NSArray*)changes viewport:(VZTouchRect)v {
 double nx,ny;
 BOOL same=_viewport.x==v.x&&_viewport.y==v.y&&_viewport.width==v.width&&_viewport.height==v.height;
 if(_contacts.count&&(!same||!VZTouchNormalize(v.x,v.y,v,&nx,&ny))) { _viewport=v;return [self cancelAll]; }
 _viewport=v;
 for(NSMutableDictionary*d in _contacts.allValues)d[@"phase"]=@2;
 NSMutableArray*remove=[NSMutableArray array];BOOL changed=NO;
 for(NSDictionary*c in changes){
  id token=c[@"token"];if(!token)continue;
  NSValue*key=[NSValue valueWithPointer:(const void*)token];NSInteger phase=[c[@"phase"] integerValue];
  if(phase<0||phase>4)continue;
  NSMutableDictionary*d=_contacts[key];double px=[c[@"x"] doubleValue],py=[c[@"y"] doubleValue];
  BOOL valid=VZTouchNormalize(px,py,v,&nx,&ny);
  if(phase==0) {
   if(d||!valid||px<v.x||py<v.y||px>=v.x+v.width||py>=v.y+v.height)continue;
   uint16_t occupied=0;for(NSDictionary*active in _contacts.allValues)occupied|=(1U<<[active[@"index"] unsignedIntValue]);
   int index=VZTouchFreeIndex(occupied);if(index<0)continue;
   d=[NSMutableDictionary dictionaryWithDictionary:@{@"index":@(index),@"token":token}];_contacts[key]=d;
  }
  if(!d||(!valid&&phase<3))continue;
  if(valid){d[@"x"]=@(nx);d[@"y"]=@(ny);}
  d[@"phase"]=@(phase);changed=YES;if(phase>=3)[remove addObject:key];
 }
 if(!changed)return @[];
 NSMutableArray*frame=[NSMutableArray array];for(NSDictionary*d in [self orderedContacts])[frame addObject:[[d copy]autorelease]];
 [_contacts removeObjectsForKeys:remove];return frame;
}
@end
