#import <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#import <ParavirtualizedGraphics/PGDevice.h>
#else
// Narrow declarations of the PGDevice callback ABI. The existing
// ported framework is loaded dynamically; this is not a replacement GPU.
typedef struct {uint64_t physicalAddress,physicalLength;} PGPhysicalMemoryRange_t;
typedef struct PGTask_s PGTask_t;
@interface PGDeviceDescriptor : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,copy) PGTask_t *(^createTask)(uint64_t,void **);
@property(nonatomic,copy) void(^destroyTask)(PGTask_t *);
@property(nonatomic,copy) bool(^mapMemory)(PGTask_t *,uint32_t,uint64_t,bool,PGPhysicalMemoryRange_t *);
@property(nonatomic,copy) bool(^unmapMemory)(PGTask_t *,uint64_t,uint64_t);
@property(nonatomic,copy) bool(^readMemory)(uint64_t,uint64_t,void *);
@property(nonatomic,copy) void(^raiseInterrupt)(uint32_t);
@end
@protocol PGDevice <NSObject>
-(uint32_t)mmioReadAtOffset:(size_t)offset;
-(void)mmioWriteAtOffset:(size_t)offset value:(uint32_t)value;
-(void)stop;
@end
#endif
