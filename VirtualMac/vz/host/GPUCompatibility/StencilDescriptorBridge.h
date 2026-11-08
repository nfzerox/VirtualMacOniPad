#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

// Disposable synthetic-new-layout constructor experiment. Does not alter
// advertised protocol43. Install at startup only; caller owns IMP rollback.
BOOL ThinInstallStencilDescriptorBridge(void *expectedPVGBase);
unsigned ThinStencilDescriptorTranslatedCount(void);
unsigned ThinStencilDescriptorRejectedCount(void);
// CPU-only preflight for the narrowly supported descriptor subset.
BOOL ThinStencilDescriptorPreflight(const void *bytes,uint32_t length,
                                   uint64_t width,uint64_t height);
