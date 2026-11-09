#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "../vz/host/VZNativeTouchCore.h"
int main(void) {
 assert(!VZTouchBackendProcess("/Applications/VirtualMac.app/VirtualMac"));
 assert(VZTouchBackendProcess("/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"));
 double x,y; VZTouchRect v={10,20,200,100};
 assert(VZTouchNormalize(110,70,v,&x,&y) && x==.5 && y==.5);
 assert(VZTouchNormalize(-5,200,v,&x,&y) && x==0 && y==1);
 assert(!VZTouchNormalize(0,0,(VZTouchRect){0,0,0,100},&x,&y));
 assert(!VZTouchNormalize(NAN,0,v,&x,&y));
 assert(VZTouchFreeIndex(0)==0 && VZTouchFreeIndex(3)==2);
 assert(VZTouchFreeIndex(1023)==-1);
 unsigned char page[4096]={0}; const char*u="C8149C86-9566-4E02-94BA-143F43BA82E1";
 assert(!VZTouchWriteDisplayUUID(page,100,0,u));
 assert(!VZTouchWriteDisplayUUID(page,sizeof(page),1,u));
 assert(!VZTouchWriteDisplayUUID(page,sizeof(page),0,"not-a-uuid"));
 assert(VZTouchWriteDisplayUUID(page,sizeof(page),0,u));
 assert(!strcmp((char*)page+0xa74,u));
 assert(!VZTouchWriteDisplayUUID(page,sizeof(page),0,u));
 memset(page,0,sizeof(page));page[0x60]=1;
 assert(!VZTouchWriteDisplayUUID(page,sizeof(page),0,u));
 page[0x60]=2;assert(VZTouchWriteDisplayUUID(page,sizeof(page),0,u));
 puts("native-touch core guards passed");return 0;
}
