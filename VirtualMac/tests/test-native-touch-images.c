#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "../vz/host/VZNativeTouchImages.h"
struct Image {struct mach_header_64 header;struct uuid_command uuid;};
static struct Image image(uint32_t type,unsigned char id) {struct Image i={0};i.header.magic=MH_MAGIC_64;i.header.filetype=type;i.header.ncmds=1;i.header.sizeofcmds=sizeof(i.uuid);i.uuid.cmd=LC_UUID;i.uuid.cmdsize=sizeof(i.uuid);memset(i.uuid.uuid,id,16);return i;}
int main(void){
 struct Image injected=image(MH_DYLIB,1),main=image(MH_EXECUTE,2),duplicate=image(MH_EXECUTE,2);unsigned char expected[16];memset(expected,2,16);
 const void*headers[]={&injected,&main};assert(VZTouchFindExecutable(headers,2,expected)==&main);
 const void*bad[]={&injected};assert(!VZTouchFindExecutable(bad,1,expected));
 const void*ambiguous[]={&main,&duplicate};assert(!VZTouchFindExecutable(ambiguous,2,expected));
 main.uuid.cmdsize=0;assert(!VZTouchFindExecutable(headers,2,expected));
 puts("injected image ordering and executable UUID guards passed");return 0;
}
