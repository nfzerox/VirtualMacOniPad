#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
BOOL ThinInstallImageblockDeviceInfoBridge(void *pvgBase);
id ThinMakeImageblockDescriptor(id original,id<MTLDevice> device);
void ThinAttachImageblockDeviceInfo(id device,id descriptor);
