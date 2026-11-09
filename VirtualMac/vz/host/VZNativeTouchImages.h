#ifndef VZ_NATIVE_TOUCH_IMAGES_H
#define VZ_NATIVE_TOUCH_IMAGES_H
#include <mach-o/loader.h>
#include <stdbool.h>
#include <string.h>
#include <stdint.h>
static inline bool VZTouchImageUUID(const void*base,const unsigned char expected[16]) {
 const struct mach_header_64*h=base;if(!h||h->magic!=MH_MAGIC_64)return false;
 const unsigned char*p=(const unsigned char*)(h+1),*end=p+h->sizeofcmds;
 for(uint32_t i=0;i<h->ncmds&&p+sizeof(struct load_command)<=end;i++) {
  const struct load_command*c=(const void*)p;if(c->cmdsize<sizeof(*c)||c->cmdsize>(size_t)(end-p))return false;
  if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command))return !memcmp(((const struct uuid_command*)c)->uuid,expected,16);
  p+=c->cmdsize;
 }
 return false;
}
static inline const void*VZTouchFindExecutable(const void*const*headers,size_t count,const unsigned char expected[16]) {
 const void*found=NULL;
 for(size_t i=0;i<count;i++) {
  const struct mach_header_64*h=headers[i];
  if(h&&h->magic==MH_MAGIC_64&&h->filetype==MH_EXECUTE&&VZTouchImageUUID(h,expected)) {if(found)return NULL;found=h;}
 }
 return found;
}
#endif
