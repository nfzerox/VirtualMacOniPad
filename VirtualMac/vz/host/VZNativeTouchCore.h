#ifndef VZ_NATIVE_TOUCH_CORE_H
#define VZ_NATIVE_TOUCH_CORE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <string.h>
#include <stdatomic.h>
typedef struct { double x,y,width,height; } VZTouchRect;
static inline bool VZTouchBackendProcess(const char*path) {
 if(!path)return false;
 const char*name=strrchr(path,'/');name=name?name+1:path;
 return !strcmp(name,"com.apple.Virtualization.VirtualMachine");
}
static inline bool VZTouchNormalize(double px,double py,VZTouchRect r,double*x,double*y) {
 if(!x||!y||!isfinite(px)||!isfinite(py)||!isfinite(r.x)||!isfinite(r.y)||!isfinite(r.width)||!isfinite(r.height)||r.width<=0||r.height<=0)return false;
 double nx=(px-r.x)/r.width,ny=(py-r.y)/r.height;
 if(!isfinite(nx)||!isfinite(ny))return false;
 *x=fmax(0,fmin(1,nx));*y=fmax(0,fmin(1,ny));return true;
}
static inline int VZTouchFreeIndex(uint16_t occupied) {
 for(int i=0;i<10;i++)if(!(occupied&(1U<<i)))return i;
 return -1;
}
static inline bool VZTouchUUIDValid(const char*u) {
 if(!u||strlen(u)!=36)return false;
 for(int i=0;i<36;i++) {
  if(i==8||i==13||i==18||i==23){if(u[i]!='-')return false;}
  else if(!((u[i]>='0'&&u[i]<='9')||(u[i]>='a'&&u[i]<='f')||(u[i]>='A'&&u[i]<='F')))return false;
 }
 return true;
}
// Only call after validating the known PVG image and a read/write VM mapping.
static inline bool VZTouchWriteDisplayUUID(void*shared,size_t size,unsigned long long port,const char*u) {
 if(!shared||size<0xa74+37||port!=0||!VZTouchUUIDValid(u))return false;
 unsigned char*p=shared;uint32_t mode;memcpy(&mode,p+0x60,4);
 if(mode!=0&&mode!=2)return false;
 for(size_t i=0;i<37;i++)if(p[0xa74+i])return false;
 memcpy(p+0xa74,u,37);atomic_thread_fence(memory_order_release);return true;
}
#endif
