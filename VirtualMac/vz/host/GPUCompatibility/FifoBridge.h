#import <Foundation/Foundation.h>
BOOL ThinInstallRootFIFOBridge(void *expectedImageBase);
unsigned ThinFIFOTranslatedCount(void);
unsigned ThinFIFOChildTranslatedCount(void);
unsigned ThinFIFOChildInfoCount(void);
void ThinDisableChildTranslation(void);

unsigned ThinFIFOObjectListsCount(void);
