#import <Foundation/Foundation.h>
typedef struct {bool valid,child;uint32_t opcode,stamp,slot;uint64_t bytes;} ThinCommandContext;
BOOL ThinInstallCommandDiagnostics(void *serializerBase);
ThinCommandContext ThinCommandEnter(uint32_t opcode,uint32_t stamp,uint64_t bytes,uint32_t slot,BOOL child);
void ThinCommandLeave(ThinCommandContext previous);
void ThinCommandUnknownOuter(uint32_t opcode,uint32_t stamp,uint64_t bytes,uint32_t slot,BOOL child);
BOOL ThinCommandSetOutputPath(const char *path);
NSDictionary *ThinCommandFirstUnknown(void);

void ThinCommandObserveExecPadding(const void *payload,size_t length);

// Called only after the enclosing Info record bounds were validated.
void ThinCommandUnknownInfo(uint32_t opcode,uint32_t bytes,uint64_t offset,
                            uint64_t segmentBytes,uint32_t task,uint32_t segmentIndex);
