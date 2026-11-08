#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
id ThinSharedEventDevice(id<MTLDevice> device);
void ThinHandleInfo(id fifo,uint32_t stamp,const void *payload,size_t length);
void ThinEnableInfo(void);
BOOL ThinInfoEnabled(void);
unsigned ThinInfoWaitingCount(void);
unsigned ThinInfoCompletedCount(void);
unsigned ThinInfoRejectedCount(void);
BOOL ThinInfoFaultActive(void);
unsigned ThinInfoRejectionReturnedCount(void);
BOOL ThinInstallInlineInfoBridge(void *serializerBase);
unsigned ThinInlineInfoCompletedCount(void);
unsigned ThinInlineInfoRejectedCount(void);
unsigned ThinInlineInfoLegacyRunCount(void);
