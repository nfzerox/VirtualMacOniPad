#import <Foundation/Foundation.h>
#import "../vz/host/VZNativeTouchContacts.h"
static NSDictionary *change(id token,int phase,double x,double y) {return @{@"token":token,@"phase":@(phase),@"x":@(x),@"y":@(y)};}
int main(void){@autoreleasepool {
 VZNativeTouchContacts*t=[[[VZNativeTouchContacts alloc]init]autorelease];VZTouchRect v={0,0,200,100};
 assert([t update:@[change(@"outside",0,-1,0)] viewport:v].count==0);
 NSArray*f=[t update:@[change(@"a",0,100,50)] viewport:v];assert(f.count==1&&[f[0][@"index"] intValue]==0&&[f[0][@"x"] doubleValue]==.5);
 f=[t update:@[change(@"b",0,40,20)] viewport:v];assert(f.count==2&&[f[0][@"phase"] intValue]==2&&[f[1][@"phase"] intValue]==0);
 f=[t update:@[change(@"a",1,220,-5)] viewport:v];assert([f[0][@"x"] doubleValue]==1&&[f[0][@"y"] doubleValue]==0&&[f[1][@"phase"] intValue]==2);
 f=[t update:@[change(@"a",3,NAN,NAN)] viewport:v];assert([f[0][@"phase"] intValue]==3);
 f=[t update:@[change(@"c",0,1,1)] viewport:v];assert(f.count==2&&[f[0][@"index"] intValue]==0&&[f[1][@"index"] intValue]==1);
 assert([t cancelAll].count==2&&[t cancelAll].count==0);
 NSMutableArray*a=[NSMutableArray array];for(int i=0;i<11;i++)[a addObject:change(@(i),0,i,i)];assert([t update:a viewport:v].count==10);
 f=[t update:@[change(@0,1,2,2)] viewport:(VZTouchRect){0,0,0,0}];assert(f.count==10);for(NSDictionary*d in f)assert([d[@"phase"] intValue]==4);
 assert([t update:@[change(@1,1,5,5)] viewport:v].count==0);
 puts("native-touch contact lifecycle passed");return 0;
}}
