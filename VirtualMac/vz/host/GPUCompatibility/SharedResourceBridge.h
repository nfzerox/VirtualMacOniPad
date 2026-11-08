#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>

// Disposable, unverified SPIKE. No protocol advertisement or FIFO65 dispatch.
BOOL ThinInstallSharedResourceBridge(void *expectedPVGBase);
// Harness-only override: production wire references name task 0's backing.
// Weak; passing nil restores task-0 lookup. Set before any type16 creation.
void ThinSharedSetBackingTask(id task,id backingTask);
id ThinSharedBackingForReference(id task,uint32_t reference);
IOSurfaceRef ThinSharedBackingSurface(id backing);
unsigned ThinSharedBackingCount(void);
unsigned ThinSharedReferenceCount(void);
