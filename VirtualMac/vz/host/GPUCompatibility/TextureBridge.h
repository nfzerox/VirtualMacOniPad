#import <Metal/Metal.h>
#include "ThinBridge.h"
BOOL ThinInstallTextureBridge(void *expectedSerializerBase);
MTLTextureDescriptor *ThinRestoreTextureDescriptor(MTLTextureDescriptor *descriptor);
unsigned ThinTextureTranslationCount(void);
unsigned ThinTextureRestoreCount(void);
unsigned ThinBufferTextureCount(void);
unsigned ThinBufferTextureManagedCount(void);
unsigned ThinBufferTextureManagedTranslationCount(void);
NSUInteger ThinLastBufferTextureGuestStorageMode(void);
NSUInteger ThinLastBufferTextureEffectiveStorageMode(void);
id ThinWrapHeap(id<MTLHeap> heap);
void ThinDisableAdditionalTexturePaths(void);
