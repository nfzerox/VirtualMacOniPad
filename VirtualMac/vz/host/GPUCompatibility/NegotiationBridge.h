#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
// Startup-only hooks. Owned PGDevices opt in explicitly before any guest setup.
BOOL ThinInstallNegotiationBridge(void *pvgBase);
BOOL ThinAttachNegotiationDevice(id device,uint32_t ceiling,char *error,size_t capacity);
NSDictionary *ThinNegotiationDeviceStatus(id device);
