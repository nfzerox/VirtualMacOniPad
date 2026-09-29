#include "VZPaths.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <ptrauth.h>
#import <pthread.h>
#import <notify.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/mman.h>
#import <time.h>
#import <unistd.h>

static BOOL (*gOriginalSetupBlitPipelines)(id, SEL);
static BOOL (*gOriginalSetupReporting)(id, SEL);
static id (*gOriginalInitWithDescriptor)(id, SEL, id);
static id (*gOriginalIOSurfaceInitWithDescriptor)(id, SEL, id);
static id (*gOriginalNewDisplay)(id, SEL, id, NSUInteger, uint32_t);
static id (*gOriginalDisplayInit)(
    id, SEL, id, id, NSUInteger, uint32_t);
static id (*gOriginalPipelineCacheInit)(id, SEL, id);
static id (*gOriginalNewDefaultLibraryWithBundle)(id, SEL, NSBundle *, NSError **);
static void (*gOriginalCommandBufferCommit)(id, SEL);
static BOOL (*gOriginalTextureValidate)(id, SEL, id);
static SEL gOriginalNewDefaultLibrarySelector;
static dispatch_data_t gSerializedMetallib;
static dispatch_source_t gMetalHealthTimer;
static uint64_t gMetalCommandBufferCommits;
static uint64_t gMetalCommandBufferCompletions;
static uint64_t gMetalCommandBufferErrors;
static id (*gOriginalGetTaskID)(id, SEL, uint32_t);
static void (*gOriginalCreateTaskID)(
    id, SEL, uint32_t, uint32_t, uint64_t, BOOL);
static BOOL (*gOriginalDeleteTaskID)(id, SEL, uint32_t);
static uint64_t gTaskLookupCount;
static uint64_t gTaskLookupMissCount;
static uint64_t gTaskMapCount;
static uint64_t gTaskMapHighWater;
static uint64_t gTaskMapFailures;
static uint64_t gManagedTextureTranslations;
static BOOL gDebugLogging;
static pthread_mutex_t gLargeTaskLock = PTHREAD_MUTEX_INITIALIZER;
static void *gLargeTaskPointers[8];
static bool gLargeTaskSlotUsed[8];
static uint32_t gLargeTaskLimit;
static uint64_t gLargeTaskReservationMB;
static uint64_t gMinimumTaskReservationMB;
static uint64_t gTaskReservationFallbacks;
static uint64_t gTaskReservationFailures;
static id (*gOriginalGetBufferForReferenceNonNull)(id, SEL, uint32_t);
static const char * const VZVideoMemoryExhaustedNotification =
    "com.mac.virtual.video-memory-exhausted";

extern id PGNewDeviceWithDescriptor(id descriptor);
static void InstallMetalLibraryFallback(id<MTLDevice> device);

static NSInteger HostIPadOSMajorVersion(void) {
    static NSInteger majorVersion;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        majorVersion = 16;
        char version[32] = {0};
        size_t size = sizeof(version);
        if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) == 0)
            majorVersion = strtol(version, NULL, 10);
    });
    return majorVersion;
}

static BOOL HostPredatesIPadOS16(void) {
    return HostIPadOSMajorVersion() < 16;
}

static NSString *HostMetalLibraryResourceName(void) {
    if (HostIPadOSMajorVersion() == 14)
        return @"default.ipados14";
    if (HostPredatesIPadOS16())
        return @"default.ipados15";
    return @"default";
}

static void Trace(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

typedef void *(^PVGCreateTaskBlock)(uint64_t length, void **baseAddress);
typedef void (^PVGDestroyTaskBlock)(void *task);
typedef BOOL (^PVGMapMemoryBlock)(void *task, uint32_t segmentCount,
                                  uint64_t offset, BOOL readonly,
                                  const uint64_t *ranges);
typedef BOOL (^PVGUnmapMemoryBlock)(void *task, uint64_t offset,
                                    uint64_t length);

// A macOS host can leave the complete 16 GiB guest GPU address space sparsely
// reserved for every PGTask. iPadOS has only about 63 GiB of process VA, so
// doing that for tens of guest clients is impossible. Keep the inexpensive
// primary reservation and add large, discontiguous host reservations only for
// tasks that actually cross it. PGTask's address helpers are translated to the
// reservation containing the requested guest range; Metal resources therefore
// retain stable host pointers for their full lifetime.
#define PVG_SEGMENT_BUCKET_COUNT 64
#define PVG_MAX_TASK_SEGMENTS 16

typedef struct {
    void *task;
    void *base;
    uint64_t logicalStart;
    uint64_t length;
} PVGTaskSegment;

typedef struct PVGSegmentedTask {
    void *primaryTask;
    uint64_t logicalLength;
    uint32_t segmentCount;
    PVGCreateTaskBlock createTask;
    pthread_mutex_t mutex;
    PVGTaskSegment segments[PVG_MAX_TASK_SEGMENTS];
    struct PVGSegmentedTask *next;
} PVGSegmentedTask;

static pthread_rwlock_t gSegmentedTaskLock = PTHREAD_RWLOCK_INITIALIZER;
static PVGSegmentedTask *gSegmentedTaskBuckets[PVG_SEGMENT_BUCKET_COUNT];
static uint64_t gTaskOverflowReservationMB;
static Ivar gPGTaskHandleIvar;
static SEL gOriginalAddressForOffsetSelector;
static SEL gOriginalMappedAddressForOffsetSelector;
static BOOL gSegmentedAddressHooksInstalled;

static size_t SegmentedTaskBucket(void *task) {
    return (((uintptr_t)task) >> 4) % PVG_SEGMENT_BUCKET_COUNT;
}

// The caller must hold gSegmentedTaskLock for reading or writing.
static PVGSegmentedTask *FindSegmentedTaskLocked(void *task) {
    if (task == NULL)
        return NULL;
    PVGSegmentedTask *entry =
        gSegmentedTaskBuckets[SegmentedTaskBucket(task)];
    while (entry != NULL && entry->primaryTask != task)
        entry = entry->next;
    return entry;
}

static BOOL RegisterSegmentedTask(void *task, void *base,
                                  uint64_t reservedLength,
                                  uint64_t logicalLength,
                                  PVGCreateTaskBlock createTask) {
    if (task == NULL || base == NULL || reservedLength == 0 ||
        reservedLength >= logicalLength || gTaskOverflowReservationMB == 0 ||
        createTask == nil)
        return NO;
    PVGSegmentedTask *entry = calloc(1, sizeof(*entry));
    if (entry == NULL)
        return NO;
    entry->primaryTask = task;
    entry->logicalLength = logicalLength;
    entry->segmentCount = 1;
    entry->createTask = [createTask copy];
    if (entry->createTask == nil) {
        free(entry);
        return NO;
    }
    entry->segments[0] = (PVGTaskSegment){
        .task = task,
        .base = base,
        .logicalStart = 0,
        .length = reservedLength,
    };
    pthread_mutex_init(&entry->mutex, NULL);

    size_t bucket = SegmentedTaskBucket(task);
    pthread_rwlock_wrlock(&gSegmentedTaskLock);
    entry->next = gSegmentedTaskBuckets[bucket];
    gSegmentedTaskBuckets[bucket] = entry;
    pthread_rwlock_unlock(&gSegmentedTaskLock);
    return YES;
}

static PVGSegmentedTask *RemoveSegmentedTask(void *task) {
    size_t bucket = SegmentedTaskBucket(task);
    pthread_rwlock_wrlock(&gSegmentedTaskLock);
    PVGSegmentedTask **cursor = &gSegmentedTaskBuckets[bucket];
    while (*cursor != NULL && (*cursor)->primaryTask != task)
        cursor = &(*cursor)->next;
    PVGSegmentedTask *entry = *cursor;
    if (entry != NULL)
        *cursor = entry->next;
    pthread_rwlock_unlock(&gSegmentedTaskLock);
    return entry;
}

// The task mutex must be held. A returned segment always contains the entire
// range; a single Metal allocation is never allowed to straddle unrelated host
// reservations because Metal retains the resulting CPU pointer.
static PVGTaskSegment *SegmentForRangeLocked(PVGSegmentedTask *entry,
                                             uint64_t offset,
                                             uint64_t length,
                                             BOOL create) {
    if (entry == NULL || length == 0 || UINT64_MAX - offset < length ||
        offset + length > entry->logicalLength)
        return NULL;
    uint64_t end = offset + length;
    for (uint32_t index = 0; index < entry->segmentCount; index++) {
        PVGTaskSegment *segment = &entry->segments[index];
        if (offset >= segment->logicalStart &&
            end <= segment->logicalStart + segment->length)
            return segment;
    }
    if (!create || entry->createTask == nil ||
        entry->segmentCount >= PVG_MAX_TASK_SEGMENTS)
        return NULL;

    uint64_t primaryLength = entry->segments[0].length;
    uint64_t overflowLength = gTaskOverflowReservationMB << 20;
    if (offset < primaryLength || overflowLength == 0)
        return NULL;
    uint64_t logicalStart = primaryLength +
        ((offset - primaryLength) / overflowLength) * overflowLength;
    uint64_t reservationLength = MIN(
        overflowLength, entry->logicalLength - logicalStart);
    if (end > logicalStart + reservationLength)
        return NULL;

    void *base = NULL;
    void *task = entry->createTask(reservationLength, &base);
    if (task == NULL || base == NULL) {
        dprintf(STDERR_FILENO,
                "VirtualMac PVG: overflow reservation failed primary=%p "
                "start=%llu length=%llu\n",
                entry->primaryTask,
                (unsigned long long)logicalStart,
                (unsigned long long)reservationLength);
        return NULL;
    }
    PVGTaskSegment *segment = &entry->segments[entry->segmentCount++];
    *segment = (PVGTaskSegment){
        .task = task,
        .base = base,
        .logicalStart = logicalStart,
        .length = reservationLength,
    };
    Trace(@"TASK_OVERFLOW_RESERVE\tprimary=%p\tsegment=%p"
          "\tbase=%p\tstart=%llu\tlength=%llu",
          entry->primaryTask, task, base,
          (unsigned long long)logicalStart,
          (unsigned long long)reservationLength);
    return segment;
}

static void *PGTaskHandle(id taskObject) {
    if (taskObject == nil || gPGTaskHandleIvar == NULL)
        return NULL;
    void *task = NULL;
    ptrdiff_t offset = ivar_getOffset(gPGTaskHandleIvar);
    memcpy(&task, (const uint8_t *)(__bridge const void *)taskObject + offset,
           sizeof(task));
    return task;
}

static void *TranslatedTaskAddress(void *task, uint64_t offset,
                                   uint64_t length, BOOL create) {
    void *address = NULL;
    pthread_rwlock_rdlock(&gSegmentedTaskLock);
    PVGSegmentedTask *entry = FindSegmentedTaskLocked(task);
    if (entry != NULL) {
        pthread_mutex_lock(&entry->mutex);
        PVGTaskSegment *segment = SegmentForRangeLocked(
            entry, offset, length, create);
        if (segment != NULL)
            address = (uint8_t *)segment->base +
                (offset - segment->logicalStart);
        pthread_mutex_unlock(&entry->mutex);
    }
    pthread_rwlock_unlock(&gSegmentedTaskLock);
    return address;
}

static void *SegmentedAddressForOffset(id self, SEL selector,
                                       uint64_t offset, uint64_t length) {
    // Preserve PGTask's native range validation and exception behavior.
    void *nativeAddress = ((void *(*)(id, SEL, uint64_t, uint64_t))
        objc_msgSend)(self, gOriginalAddressForOffsetSelector, offset, length);
    void *translated = TranslatedTaskAddress(
        PGTaskHandle(self), offset, length, YES);
    return translated ?: nativeAddress;
}

static void *SegmentedMappedAddressForOffset(id self, SEL selector,
                                             uint64_t offset,
                                             uint64_t length) {
    // The original method maintains PGTask's mapped-range tracker and invokes
    // the descriptor callback. Discard only its base+offset result.
    void *nativeAddress = ((void *(*)(id, SEL, uint64_t, uint64_t))
        objc_msgSend)(self, gOriginalMappedAddressForOffsetSelector,
                      offset, length);
    void *translated = TranslatedTaskAddress(
        PGTaskHandle(self), offset, length, NO);
    return translated ?: nativeAddress;
}

static BOOL InstallSegmentedPGTaskAddressHooks(void) {
    if (gSegmentedAddressHooksInstalled)
        return YES;
    Class taskClass = NSClassFromString(@"PGTask");
    if (taskClass == Nil)
        return NO;
    gPGTaskHandleIvar = class_getInstanceVariable(taskClass, "_task");
    Method addressMethod = class_getInstanceMethod(
        taskClass, NSSelectorFromString(@"addressForOffset:length:"));
    Method mappedMethod = class_getInstanceMethod(
        taskClass, NSSelectorFromString(@"mappedAddressForOffset:length:"));
    if (gPGTaskHandleIvar == NULL || addressMethod == NULL ||
        mappedMethod == NULL)
        return NO;
    // iPadOS 14/15 cannot safely call a Ventura arm64e IMP returned by
    // method_setImplementation through a plain C function pointer. Preserve
    // each implementation as a private Objective-C method instead. Dispatch
    // through objc_msgSend then uses the current runtime's own pointer-
    // authentication convention on every supported host release.
    gOriginalAddressForOffsetSelector = sel_registerName(
        "_virtualMac_originalAddressForOffset:length:");
    gOriginalMappedAddressForOffsetSelector = sel_registerName(
        "_virtualMac_originalMappedAddressForOffset:length:");
    if (!class_addMethod(taskClass, gOriginalAddressForOffsetSelector,
                         method_getImplementation(addressMethod),
                         method_getTypeEncoding(addressMethod)) ||
        !class_addMethod(taskClass, gOriginalMappedAddressForOffsetSelector,
                         method_getImplementation(mappedMethod),
                         method_getTypeEncoding(mappedMethod))) {
        return NO;
    }
    method_setImplementation(addressMethod, (IMP)SegmentedAddressForOffset);
    method_setImplementation(mappedMethod,
                             (IMP)SegmentedMappedAddressForOffset);
    Trace(@"TASK_OVERFLOW_HOOKS\tinstalled=1");
    gSegmentedAddressHooksInstalled = YES;
    return YES;
}

static BOOL MapSegmentedTaskRange(PVGMapMemoryBlock originalMap,
                                  void *task, uint32_t segmentCount,
                                  uint64_t offset, uint64_t mappedLength,
                                  BOOL readonly, const uint64_t *ranges) {
    BOOL result = NO;
    pthread_rwlock_rdlock(&gSegmentedTaskLock);
    PVGSegmentedTask *entry = FindSegmentedTaskLocked(task);
    if (entry != NULL) {
        pthread_mutex_lock(&entry->mutex);
        PVGTaskSegment *segment = SegmentForRangeLocked(
            entry, offset, mappedLength, YES);
        if (segment != NULL) {
            result = originalMap(
                segment->task, segmentCount,
                offset - segment->logicalStart, readonly, ranges);
        } else {
            dprintf(STDERR_FILENO,
                    "VirtualMac PVG: mapping cannot fit one reservation "
                    "task=%p offset=%llu length=%llu\n",
                    task, (unsigned long long)offset,
                    (unsigned long long)mappedLength);
        }
        pthread_mutex_unlock(&entry->mutex);
    }
    pthread_rwlock_unlock(&gSegmentedTaskLock);
    return result;
}

static BOOL UnmapSegmentedTaskRange(PVGUnmapMemoryBlock originalUnmap,
                                    void *task, uint64_t offset,
                                    uint64_t length) {
    BOOL result = NO;
    pthread_rwlock_rdlock(&gSegmentedTaskLock);
    PVGSegmentedTask *entry = FindSegmentedTaskLocked(task);
    if (entry != NULL) {
        pthread_mutex_lock(&entry->mutex);
        PVGTaskSegment *segment = SegmentForRangeLocked(
            entry, offset, length, NO);
        if (segment != NULL) {
            result = originalUnmap(
                segment->task, offset - segment->logicalStart, length);
        }
        pthread_mutex_unlock(&entry->mutex);
    }
    pthread_rwlock_unlock(&gSegmentedTaskLock);
    return result;
}

static void *CreateTaskWithAdaptiveReservation(
    PVGCreateTaskBlock createTask, uint64_t requestedLength,
    uint64_t preferredLength, void **baseAddress) {
    if (requestedLength != (16ULL << 30) || preferredLength == 0)
        return createTask(requestedLength, baseAddress);

    uint64_t minimumLength = MAX(gMinimumTaskReservationMB, 1) << 20;
    minimumLength = MIN(minimumLength, preferredLength);
    uint64_t candidate = preferredLength;
    while (true) {
        if (baseAddress != NULL)
            *baseAddress = NULL;
        void *task = createTask(candidate, baseAddress);
        if (task != NULL) {
            if (candidate != preferredLength) {
                uint64_t fallback = __atomic_add_fetch(
                    &gTaskReservationFallbacks, 1, __ATOMIC_RELAXED);
                dprintf(STDERR_FILENO,
                        "VirtualMac PVG: task reservation fell back from "
                        "%llu to %llu bytes (fallback %llu)\n",
                        (unsigned long long)preferredLength,
                        (unsigned long long)candidate,
                        (unsigned long long)fallback);
            }
            return task;
        }
        if (candidate == minimumLength)
            break;
        candidate = MAX(candidate / 2, minimumLength);
    }

    // Keep the VMM and guest alive long enough for the user to decide whether
    // to save non-graphical work or force shutdown. A real 1 MiB task is safer
    // than returning nil (which makes _PGDevice enter an unbounded Invalid
    // task loop), while the host warning makes the degraded state explicit.
    uint64_t failure = __atomic_add_fetch(
        &gTaskReservationFailures, 1, __ATOMIC_RELAXED);
    if (baseAddress != NULL)
        *baseAddress = NULL;
    void *emergencyTask = createTask(1ULL << 20, baseAddress);
    notify_post(VZNotificationName(@(VZVideoMemoryExhaustedNotification)).UTF8String);
    if (emergencyTask != NULL) {
        dprintf(STDERR_FILENO,
                "VirtualMac PVG: graphics address space exhausted; using "
                "1 MiB emergency task so the guest can remain alive "
                "(failure %llu)\n",
                (unsigned long long)failure);
        return emergencyTask;
    }
    dprintf(STDERR_FILENO,
            "VirtualMac PVG: graphics address space exhausted after "
            "reservation retries, including the emergency task; stopping "
            "VMM (failure %llu)\n",
            (unsigned long long)failure);
    abort();
}

static const char *TracePath(void) {
    const char *configured = getenv("PVG_TRACE_PATH");
    return configured && configured[0] ? configured : VZTemporaryPath("pvg-trace.log");
}

static void Trace(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void Trace(NSString *format, ...) {
    if (!gDebugLogging)
        return;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    int fd = open(TracePath(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        struct timespec now = {0};
        clock_gettime(CLOCK_MONOTONIC, &now);
        dprintf(fd, "[%lld.%06ld]\t%s\n",
                (long long)now.tv_sec, now.tv_nsec / 1000,
                line.UTF8String);
        close(fd);
    }
}

static void TraceMethod(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        Trace(@"METHOD\t%@\tmissing", NSStringFromSelector(selector));
        return;
    }

    Dl_info info = {0};
    IMP implementation = method_getImplementation(method);
    dladdr((const void *)implementation, &info);
    Trace(@"METHOD\t%@\t%p\t%s",
          NSStringFromSelector(selector),
          implementation,
          info.dli_fname != NULL ? info.dli_fname : "(unknown)");
}

static id TraceGetBufferForReferenceNonNull(id self, SEL selector,
                                            uint32_t reference) {
    if (reference == 0) {
        void *returnAddress = __builtin_return_address(0);
        Dl_info caller = {0};
        dladdr(returnAddress, &caller);
        Trace(@"METAL_BUFFER_REFERENCE\tinvalid-zero\tdecoder=%s"
              "\tcaller=%p\toffset=0x%llx\timage=%s",
              object_getClassName(self), returnAddress,
              (unsigned long long)((uintptr_t)returnAddress -
                                   (uintptr_t)caller.dli_fbase),
              caller.dli_fname ?: "(unknown)");
    }
    return gOriginalGetBufferForReferenceNonNull(
        self, selector, reference);
}

static void InstallMetalSerializerReferenceTrace(void) {
    Class cls = NSClassFromString(@"MTLDeserializerBlitDecoder");
    SEL selector = NSSelectorFromString(@"getBufferForReferenceNonNull:");
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        Trace(@"METAL_BUFFER_REFERENCE\thook-missing\tclass=%@", cls);
        return;
    }
    gOriginalGetBufferForReferenceNonNull =
        (id (*)(id, SEL, uint32_t))method_setImplementation(
            method, (IMP)TraceGetBufferForReferenceNonNull);
    Trace(@"METAL_BUFFER_REFERENCE\thook-installed\tclass=%@\toriginal=%p",
          cls, gOriginalGetBufferForReferenceNonNull);
}

static id TraceGetTaskID(id self, SEL selector, uint32_t taskID) {
    uint64_t count = __atomic_add_fetch(
        &gTaskLookupCount, 1, __ATOMIC_RELAXED);
    @try {
        id task = gOriginalGetTaskID(self, selector, taskID);
        if (count <= 12) {
            Trace(@"TASK_LOOKUP\tcount=%llu\tid=%u\tresult=%p",
                  (unsigned long long)count, taskID, task);
        }
        return task;
    } @catch (NSException *exception) {
        uint64_t misses = __atomic_add_fetch(
            &gTaskLookupMissCount, 1, __ATOMIC_RELAXED);
        Ivar tasksIvar = class_getInstanceVariable([self class], "_tasks");
        id tasks = tasksIvar != NULL ? object_getIvar(self, tasksIvar) : nil;
        Trace(@"TASK_LOOKUP_MISS\tmiss=%llu\tcount=%llu\tid=%u"
              "\ttasks=%@\texception=%@",
              (unsigned long long)misses,
              (unsigned long long)count,
              taskID,
              tasks,
              exception);
        @throw;
    }
}

static id TaskDictionary(id device) {
    Ivar tasksIvar = class_getInstanceVariable([device class], "_tasks");
    return tasksIvar != NULL ? object_getIvar(device, tasksIvar) : nil;
}

static int32_t ClaimLargeTaskSlot(uint64_t length) {
    if (length != (16ULL << 30) || gLargeTaskReservationMB == 0 ||
        gLargeTaskLimit == 0)
        return -1;
    int32_t claimedSlot = -1;
    pthread_mutex_lock(&gLargeTaskLock);
    for (uint32_t index = 0; index < gLargeTaskLimit; index++) {
        if (!gLargeTaskSlotUsed[index]) {
            gLargeTaskSlotUsed[index] = true;
            gLargeTaskPointers[index] = NULL;
            claimedSlot = (int32_t)index;
            break;
        }
    }
    pthread_mutex_unlock(&gLargeTaskLock);
    return claimedSlot;
}

static void FinishLargeTaskSlot(int32_t slot, void *task) {
    if (slot < 0)
        return;
    pthread_mutex_lock(&gLargeTaskLock);
    if ((uint32_t)slot < gLargeTaskLimit) {
        if (task != NULL) {
            gLargeTaskPointers[slot] = task;
        } else {
            gLargeTaskSlotUsed[slot] = false;
            gLargeTaskPointers[slot] = NULL;
        }
    }
    pthread_mutex_unlock(&gLargeTaskLock);
}

static void ReleaseLargeTaskSlotForPointer(void *task) {
    if (task == NULL)
        return;
    pthread_mutex_lock(&gLargeTaskLock);
    for (uint32_t index = 0; index < gLargeTaskLimit; index++) {
        if (gLargeTaskSlotUsed[index] &&
            gLargeTaskPointers[index] == task) {
            gLargeTaskSlotUsed[index] = false;
            gLargeTaskPointers[index] = NULL;
            break;
        }
    }
    pthread_mutex_unlock(&gLargeTaskLock);
}

static void TraceCreateTaskID(id self, SEL selector, uint32_t taskID,
                              uint32_t taskRoot, uint64_t length,
                              BOOL restoring) {
    if (gDebugLogging) {
        Trace(@"TASK_CREATE\tbegin\tid=%u\troot=%u\tlength=%llu"
              "\trestoring=%d\ttasks=%@",
              taskID, taskRoot, (unsigned long long)length, restoring,
              TaskDictionary(self));
    }
    gOriginalCreateTaskID(
        self, selector, taskID, taskRoot, length, restoring);
    if (gDebugLogging)
        Trace(@"TASK_CREATE\tend\tid=%u\ttasks=%@",
              taskID, TaskDictionary(self));
}

static BOOL TraceDeleteTaskID(id self, SEL selector, uint32_t taskID) {
    if (gDebugLogging)
        Trace(@"TASK_DELETE\tbegin\tid=%u\ttasks=%@",
              taskID, TaskDictionary(self));
    BOOL result = gOriginalDeleteTaskID(self, selector, taskID);
    if (gDebugLogging) {
        Trace(@"TASK_DELETE\tend\tid=%u\tresult=%d\ttasks=%@",
              taskID, result, TaskDictionary(self));
    }
    return result;
}

static void TraceCommandBufferCommit(id self, SEL selector) {
    uint64_t commit = __atomic_add_fetch(
        &gMetalCommandBufferCommits, 1, __ATOMIC_RELAXED);
    // Adding a heap-allocated completion block to every PVG command buffer
    // changes graphics timing under load. Debug Logging samples startup and
    // then one in 256 buffers, retaining useful error evidence without making
    // the diagnostic itself a graphics hot path.
    if (commit <= 32 || commit % 256 == 0) {
        [self addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
            uint64_t completion = __atomic_add_fetch(
                &gMetalCommandBufferCompletions, 1, __ATOMIC_RELAXED);
            MTLCommandBufferStatus status = commandBuffer.status;
            NSError *error = commandBuffer.error;
            if (status == MTLCommandBufferStatusError || error != nil) {
                uint64_t errors = __atomic_add_fetch(
                    &gMetalCommandBufferErrors, 1, __ATOMIC_RELAXED);
                Trace(@"METAL_COMMAND_BUFFER\terror=%llu\tcommit=%llu"
                      "\tsampled-completion=%llu\tstatus=%lu"
                      "\tdescription=%@",
                      (unsigned long long)errors,
                      (unsigned long long)commit,
                      (unsigned long long)completion,
                      (unsigned long)status,
                      error);
            }
        }];
    }
    gOriginalCommandBufferCommit(self, selector);
}

static void InstallCommandBufferTrace(id<MTLDevice> device) {
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    Method commitMethod = class_getInstanceMethod(
        [commandBuffer class], @selector(commit));
    if (commitMethod == NULL) {
        Trace(@"METAL_COMMAND_BUFFER\tcommit-method-missing\tclass=%@",
              [commandBuffer class]);
        [queue release];
        return;
    }
    gOriginalCommandBufferCommit =
        (void (*)(id, SEL))method_setImplementation(
            commitMethod, (IMP)TraceCommandBufferCommit);
    Trace(@"METAL_COMMAND_BUFFER\ttrace-installed\tclass=%@\toriginal=%p",
          [commandBuffer class], gOriginalCommandBufferCommit);

    dispatch_queue_t healthQueue = dispatch_get_global_queue(
        QOS_CLASS_UTILITY, 0);
    gMetalHealthTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, healthQueue);
    dispatch_source_set_timer(
        gMetalHealthTimer,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC,
        NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gMetalHealthTimer, ^{
        Trace(@"METAL_HEALTH\tcommits=%llu\tsampled-completions=%llu"
              "\tsampled-errors=%llu",
              (unsigned long long)__atomic_load_n(
                  &gMetalCommandBufferCommits, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &gMetalCommandBufferCompletions, __ATOMIC_RELAXED),
              (unsigned long long)__atomic_load_n(
                  &gMetalCommandBufferErrors, __ATOMIC_RELAXED));
    });
    dispatch_resume(gMetalHealthTimer);
    [queue release];
}

static BOOL ValidateTextureDescriptorForIOS(id self, SEL selector,
                                            id device) {
    MTLStorageMode storageMode = ((MTLStorageMode (*)(id, SEL))objc_msgSend)(
        self, @selector(storageMode));
    // MTLStorageModeManaged is numerically 1 but unavailable in the iOS SDK.
    if (storageMode == (MTLStorageMode)1) {
        ((void (*)(id, SEL, MTLStorageMode))objc_msgSend)(
            self, @selector(setStorageMode:), MTLStorageModeShared);
        if (gDebugLogging) {
            uint64_t count = __atomic_add_fetch(
                &gManagedTextureTranslations, 1, __ATOMIC_RELAXED);
            if (count <= 12 || count % 100 == 0) {
                Trace(@"METAL_TEXTURE\tmanaged-to-shared=%llu\tdescriptor=%@",
                      (unsigned long long)count, self);
            }
        }
    }
    return gOriginalTextureValidate(self, selector, device);
}

static void InstallTextureDescriptorCompatibility(void) {
    MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
    Class cls = [descriptor class];
    SEL selector = NSSelectorFromString(@"validateWithDevice:");
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        Trace(@"METAL_TEXTURE\tvalidate-hook-missing\tclass=%@", cls);
        [descriptor release];
        return;
    }
    gOriginalTextureValidate =
        (BOOL (*)(id, SEL, id))method_setImplementation(
            method, (IMP)ValidateTextureDescriptorForIOS);
    Trace(@"METAL_TEXTURE\tvalidate-hook-installed\tclass=%@"
          "\ttype=%s\toriginal=%p",
          cls, method_getTypeEncoding(method), gOriginalTextureValidate);
    [descriptor release];
}

static BOOL TraceSetupBlitPipelines(id self, SEL selector) {
    Trace(@"CALL\tsetupBlitPipelines\tbegin");
    BOOL result = gOriginalSetupBlitPipelines(self, selector);
    Trace(@"CALL\tsetupBlitPipelines\tresult=%d", result);
    return result;
}

static BOOL TraceSetupReporting(id self, SEL selector) {
    Trace(@"CALL\tsetupReporting\tbegin");
    BOOL result = gOriginalSetupReporting(self, selector);
    Trace(@"CALL\tsetupReporting\tresult=%d", result);
    return result;
}

static id TraceInitWithDescriptor(id self, SEL selector, id descriptor) {
    Trace(@"CALL\tinitWithDescriptor:\tbegin\tdescriptor=%@", descriptor);
    id result = gOriginalInitWithDescriptor(self, selector, descriptor);
    Trace(@"CALL\tinitWithDescriptor:\tresult=%@", result);
    return result;
}

static id TraceIOSurfaceInitWithDescriptor(id self, SEL selector, id descriptor) {
    Trace(@"CALL\tPGIOSurfaceHostDevice initWithDescriptor:\tbegin"
          "\tdescriptor=%@\tmmioLength=%@",
          descriptor,
          [descriptor valueForKey:@"mmioLength"]);
    id result =
        gOriginalIOSurfaceInitWithDescriptor(self, selector, descriptor);
    Trace(@"CALL\tPGIOSurfaceHostDevice initWithDescriptor:\tresult=%@",
          result);
    if (result != nil) {
        // This is the last component of the PVG device stack constructed by
        // VMM. Give its asynchronously started FIFO workers a bounded window
        // to finish the initial Metal capability exchange before VMM
        // finalizes all host devices.
        const char *configured = getenv("PVG_SETTLE_USEC");
        useconds_t delay = configured && configured[0]
            ? (useconds_t)strtoul(configured, NULL, 10)
            : 1000000;
        if (delay > 1000000) {
            delay = 1000000;
        }
        Trace(@"CALL\tPGIOSurfaceHostDevice initWithDescriptor:"
              "\tsettle-usec=%u",
              delay);
        usleep(delay);
    }
    return result;
}

static id TraceNewDisplay(id self, SEL selector, id descriptor,
                          NSUInteger port, uint32_t serialNumber) {
    Trace(@"CALL\tnewDisplayWithDescriptor:port:serialNum:\tbegin"
          "\tdescriptor=%@\tport=%lu\tserial=%u",
          descriptor, (unsigned long)port, serialNumber);
    id result =
        gOriginalNewDisplay(self, selector, descriptor, port, serialNumber);
    Trace(@"CALL\tnewDisplayWithDescriptor:port:serialNum:\tresult=%@",
          result);
    return result;
}

static id TraceDisplayInit(id self, SEL selector, id device, id descriptor,
                           NSUInteger port, uint32_t serialNumber) {
    Trace(@"CALL\t_PGDisplay init\tbegin\tdevice=%@\tdescriptor=%@"
          "\tport=%lu\tserial=%u",
          device, descriptor, (unsigned long)port, serialNumber);
    id result = gOriginalDisplayInit(
        self, selector, device, descriptor, port, serialNumber);
    Trace(@"CALL\t_PGDisplay init\tresult=%@", result);
    return result;
}

static id TracePipelineCacheInit(id self, SEL selector, id device) {
    Trace(@"CALL\tPGDisplayPipelineCache initWithDevice:\tbegin"
          "\tdevice=%@",
          device);
    id result = gOriginalPipelineCacheInit(self, selector, device);
    Trace(@"CALL\tPGDisplayPipelineCache initWithDevice:\tresult=%@",
          result);
    return result;
}

static id TracePGNewDeviceWithDescriptor(id descriptor) {
    id device = nil;
    id mapper = nil;
    id mmioLength = nil;
    id displayPortCount = nil;
    id createTask = nil;
    id destroyTask = nil;
    id mapMemory = nil;
    id unmapMemory = nil;
    id readMemory = nil;
    @try {
        device = [descriptor valueForKey:@"device"];
        mapper = [descriptor valueForKey:@"usingIOSurfaceMapper"];
        mmioLength = [descriptor valueForKey:@"mmioLength"];
        displayPortCount = [descriptor valueForKey:@"displayPortCount"];
        createTask = [descriptor valueForKey:@"createTask"];
        destroyTask = [descriptor valueForKey:@"destroyTask"];
        mapMemory = [descriptor valueForKey:@"mapMemory"];
        unmapMemory = [descriptor valueForKey:@"unmapMemory"];
        readMemory = [descriptor valueForKey:@"readMemory"];
    } @catch (NSException *exception) {
        Trace(@"CALL\tPGNewDeviceWithDescriptor\tdescriptor-read-exception=%@",
              exception);
    }
    Trace(@"CALL\tPGNewDeviceWithDescriptor\tbegin\tdescriptor=%@"
          "\tdevice=%@\tusingIOSurfaceMapper=%@\tmmioLength=%@"
          "\tdisplayPortCount=%@",
          descriptor, device, mapper, mmioLength, displayPortCount);
    static bool installedIPadOS15MetalFallback;
    if (device != nil && HostIPadOSMajorVersion() == 15 &&
        !__atomic_exchange_n(&installedIPadOS15MetalFallback, true,
                             __ATOMIC_ACQ_REL)) {
        // On iPadOS 15 the VMM loads this interposer before
        // ParavirtualizedGraphics, so its constructor cannot patch the
        // concrete Metal device class yet. Do it at the first factory call,
        // after both the framework and MTLDevice exist but before _PGDevice
        // compiles its required blit pipelines. iPadOS 14 and 16 retain their
        // established, independent paths.
        InstallMetalLibraryFallback(device);
    }
    NSDictionary *blocks = @{
        @"createTask": createTask ?: [NSNull null],
        @"destroyTask": destroyTask ?: [NSNull null],
        @"mapMemory": mapMemory ?: [NSNull null],
        @"unmapMemory": unmapMemory ?: [NSNull null],
        @"readMemory": readMemory ?: [NSNull null],
    };
    for (NSString *name in blocks) {
        id block = blocks[name];
        if (block == (id)[NSNull null])
            continue;
        const uintptr_t *words = (const uintptr_t *)(const void *)block;
        void *invoke = (void *)ptrauth_strip(
            (void *)words[2], ptrauth_key_function_pointer);
        Dl_info info = {0};
        dladdr(invoke, &info);
        Trace(@"CALLBACK\t%@\tblock=%p\tinvoke=%p\tbase=%p"
              "\toffset=0x%llx\timage=%s",
              name, block, invoke, info.dli_fbase,
              (unsigned long long)((uintptr_t)invoke -
                                   (uintptr_t)info.dli_fbase),
              info.dli_fname ?: "(unknown)");
    }

    // iPadOS extended-VA processes have only enough address space for three
    // 16 GiB reservations. macOS PVG asks the VMM to reserve 16 GiB for every
    // graphics client, so the third ordinary client otherwise fails to exist.
    // Keep PVG's logical 16 GiB task size but reduce the VMM's sparse host
    // reservation. The map wrapper verifies whether the guest ever crosses
    // the physical reservation before forwarding each fixed remap.
    const char *reservationText = getenv("PVG_TASK_RESERVATION_MB");
    uint64_t reservationMB = reservationText && reservationText[0]
        ? strtoull(reservationText, NULL, 10) : 0;
    const char *largeReservationText = getenv(
        "PVG_LARGE_TASK_RESERVATION_MB");
    gLargeTaskReservationMB = largeReservationText &&
        largeReservationText[0]
        ? strtoull(largeReservationText, NULL, 10) : 0;
    const char *largeTaskCountText = getenv("PVG_LARGE_TASK_COUNT");
    uint64_t largeTaskCount = largeTaskCountText && largeTaskCountText[0]
        ? strtoull(largeTaskCountText, NULL, 10) : 0;
    gLargeTaskLimit = (uint32_t)MIN(
        largeTaskCount,
        sizeof(gLargeTaskPointers) / sizeof(gLargeTaskPointers[0]));
    const char *minimumReservationText = getenv(
        "PVG_MIN_TASK_RESERVATION_MB");
    gMinimumTaskReservationMB = minimumReservationText &&
        minimumReservationText[0]
        ? strtoull(minimumReservationText, NULL, 10) : 64;
    const char *overflowReservationText = getenv(
        "PVG_TASK_OVERFLOW_MB");
    gTaskOverflowReservationMB = overflowReservationText &&
        overflowReservationText[0]
        ? strtoull(overflowReservationText, NULL, 10) : 0;
    if (gTaskOverflowReservationMB != 0 &&
        !InstallSegmentedPGTaskAddressHooks()) {
        dprintf(STDERR_FILENO,
                "VirtualMac PVG: segmented address hooks unavailable; "
                "using the established 512 MiB fixed reservation\n");
        gTaskOverflowReservationMB = 0;
        reservationMB = MAX(reservationMB, 512);
    }
    if (createTask != nil) {
        PVGCreateTaskBlock originalCreate = (PVGCreateTaskBlock)createTask;
        PVGCreateTaskBlock wrappedCreate = ^void *(uint64_t length,
                                                    void **baseAddress) {
            uint64_t effectiveLength = length;
            int32_t largeSlot = ClaimLargeTaskSlot(length);
            uint64_t selectedReservationMB = largeSlot >= 0
                ? gLargeTaskReservationMB : reservationMB;
            if (selectedReservationMB != 0 && length == (16ULL << 30))
                effectiveLength = selectedReservationMB << 20;
            void *task = CreateTaskWithAdaptiveReservation(
                originalCreate, length, effectiveLength, baseAddress);
            FinishLargeTaskSlot(largeSlot, task);
            uint64_t actualLength = task != NULL
                ? ((const uint64_t *)task)[1] : 0;
            if (task != NULL && baseAddress != NULL &&
                gTaskOverflowReservationMB != 0) {
                RegisterSegmentedTask(
                    task, *baseAddress, actualLength, length,
                    originalCreate);
            }
            Trace(@"TASK_RESERVE\trequested=%llu\teffective=%llu"
                  "\tactual=%llu\tresult=%p\tbase=%p",
                  (unsigned long long)length,
                  (unsigned long long)effectiveLength,
                  (unsigned long long)actualLength,
                  task,
                  baseAddress ? *baseAddress : NULL);
            return task;
        };
        [descriptor setValue:wrappedCreate forKey:@"createTask"];
    }
    if (destroyTask != nil) {
        PVGDestroyTaskBlock originalDestroy =
            (PVGDestroyTaskBlock)destroyTask;
        PVGDestroyTaskBlock wrappedDestroy = ^(void *task) {
            PVGSegmentedTask *segmented = RemoveSegmentedTask(task);
            @try {
                if (segmented != NULL) {
                    pthread_mutex_lock(&segmented->mutex);
                    for (uint32_t index = 1;
                         index < segmented->segmentCount; index++) {
                        originalDestroy(segmented->segments[index].task);
                    }
                    pthread_mutex_unlock(&segmented->mutex);
                }
                originalDestroy(task);
            } @finally {
                ReleaseLargeTaskSlotForPointer(task);
                if (segmented != NULL) {
                    [segmented->createTask release];
                    pthread_mutex_destroy(&segmented->mutex);
                    free(segmented);
                }
            }
        };
        [descriptor setValue:wrappedDestroy forKey:@"destroyTask"];
    }
    if (mapMemory != nil) {
        PVGMapMemoryBlock originalMap = (PVGMapMemoryBlock)mapMemory;
        PVGMapMemoryBlock wrappedMap = ^BOOL(
            void *task, uint32_t segmentCount, uint64_t offset,
            BOOL readonly, const uint64_t *ranges) {
            uint64_t mappedLength = 0;
            for (uint32_t index = 0; index < segmentCount; index++) {
                uint64_t length = ranges[index * 2 + 1];
                if (UINT64_MAX - mappedLength < length) {
                    mappedLength = UINT64_MAX;
                    break;
                }
                mappedLength += length;
            }
            uint64_t base = task ? ((const uint64_t *)task)[0] : 0;
            uint64_t reserved = task ? ((const uint64_t *)task)[1] : 0;
            uint64_t end = UINT64_MAX - offset < mappedLength
                ? UINT64_MAX : offset + mappedLength;
            // Never let a fixed remap escape the sparse reservation. The VM
            // allocator may happen to leave a gap after it, which made the
            // old 1 GiB limit appear to work until a graphics-heavy UI such
            // as Launchpad crossed into unowned address space and killed the
            // VMM. Report a clean map failure instead of corrupting adjacent
            // virtual allocations.
            BOOL withinReservation = task && end <= reserved;
            BOOL result = withinReservation
                ? originalMap(task, segmentCount, offset, readonly, ranges)
                : MapSegmentedTaskRange(
                    originalMap, task, segmentCount, offset, mappedLength,
                    readonly, ranges);
            if (!result) {
                uint64_t failure = __atomic_add_fetch(
                    &gTaskMapFailures, 1, __ATOMIC_RELAXED);
                dprintf(STDERR_FILENO,
                        "VirtualMac PVG: task map failed task=%p "
                        "base=0x%llx reserved=%llu offset=%llu length=%llu "
                        "end=%llu within=%d segments=%u readonly=%d "
                        "failure=%llu\n",
                        task,
                        (unsigned long long)base,
                        (unsigned long long)reserved,
                        (unsigned long long)offset,
                        (unsigned long long)mappedLength,
                        (unsigned long long)end,
                        withinReservation,
                        segmentCount,
                        readonly,
                        (unsigned long long)failure);
            }
            if (gDebugLogging) {
                uint64_t count = __atomic_add_fetch(
                    &gTaskMapCount, 1, __ATOMIC_RELAXED);
                uint64_t previousHighWater = __atomic_load_n(
                    &gTaskMapHighWater, __ATOMIC_RELAXED);
                BOOL raisedHighWater = NO;
                while (end > previousHighWater) {
                    if (__atomic_compare_exchange_n(
                            &gTaskMapHighWater, &previousHighWater, end, NO,
                            __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
                        raisedHighWater = YES;
                        break;
                    }
                }
                BOOL crossedHighWaterBucket = raisedHighWater &&
                    ((end >> 24) != (previousHighWater >> 24));
                // Crossing the primary reservation is normal when segmented
                // tasks are active. Logging every overflow page made debug
                // mode open and append this file hundreds of thousands of
                // times during boot, materially changing graphics timing.
                // Segment creation plus high-water buckets retain enough
                // evidence without putting I/O in the mapping hot path.
                if (count <= 16 || !result || crossedHighWaterBucket) {
                    Trace(@"TASK_MAP\tcount=%llu\ttask=%p\tbase=0x%llx"
                          "\treserved=%llu\toffset=%llu\tlength=%llu"
                          "\tend=%llu\twithin=%d\thighwater=%d\tsegments=%u"
                          "\treadonly=%d\tresult=%d",
                          (unsigned long long)count, task,
                          (unsigned long long)base,
                          (unsigned long long)reserved,
                          (unsigned long long)offset,
                          (unsigned long long)mappedLength,
                          (unsigned long long)end,
                          withinReservation,
                          crossedHighWaterBucket,
                          segmentCount, readonly, result);
                }
            }
            return result;
        };
        [descriptor setValue:wrappedMap forKey:@"mapMemory"];
    }
    if (unmapMemory != nil) {
        PVGUnmapMemoryBlock originalUnmap =
            (PVGUnmapMemoryBlock)unmapMemory;
        PVGUnmapMemoryBlock wrappedUnmap = ^BOOL(
            void *task, uint64_t offset, uint64_t length) {
            uint64_t reserved = task ? ((const uint64_t *)task)[1] : 0;
            if (task != NULL && UINT64_MAX - offset >= length &&
                offset + length <= reserved) {
                return originalUnmap(task, offset, length);
            }
            return UnmapSegmentedTaskRange(
                originalUnmap, task, offset, length);
        };
        [descriptor setValue:wrappedUnmap forKey:@"unmapMemory"];
    }
    id result = PGNewDeviceWithDescriptor(descriptor);
    Trace(@"CALL\tPGNewDeviceWithDescriptor\tresult=%@", result);
    if (result != nil && HostPredatesIPadOS16()) {
        // The iPadOS 15 Objective-C runtime cannot safely round-trip Ventura
        // IMPs through method_setImplementation, so its per-IOSurface settle
        // hook is intentionally disabled.  Settle once at the enclosing PVG
        // factory boundary instead.  Without this, the guest's first
        // WindowServer reaches __WSSystemCanCompositeWithMetal before PVG's
        // asynchronous Metal setup is ready, aborts, and only its retry works.
        Trace(@"CALL\tPGNewDeviceWithDescriptor\tpre-iPadOS16-settle-usec=1000000");
        usleep(1000000);
    }
    return result;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} gInterposePGNewDeviceWithDescriptor
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&TracePGNewDeviceWithDescriptor,
        (const void *)&PGNewDeviceWithDescriptor,
    };

static id TraceNewDefaultLibraryWithBundle(id self,
                                           SEL selector,
                                           NSBundle *bundle,
                                           NSError **error)
    __attribute__((ns_returns_retained));

static id TraceNewDefaultLibraryWithBundle(id self,
                                           SEL selector,
                                           NSBundle *bundle,
                                           NSError **error) {
    Trace(@"METAL_HOOK\tenter\tselector=%@\tdevice=%p\tbundle=%@",
          NSStringFromSelector(selector),
          self,
          bundle.bundlePath);
    NSError *fallbackError = nil;
    id library = nil;
    if (gSerializedMetallib != nil) {
        library = [self newLibraryWithData:gSerializedMetallib
                                     error:&fallbackError];
    }

    NSString *resourceName = HostMetalLibraryResourceName();
    NSURL *url = [[NSBundle mainBundle]
        URLForResource:resourceName
        withExtension:@"metallib"];
    if (url == nil) {
        url = [bundle URLForResource:resourceName
                       withExtension:@"metallib"];
    }
    if (library == nil && url != nil) {
        fallbackError = nil;
        library = [self newLibraryWithURL:url error:&fallbackError];
    }
    Trace(@"METAL_HOOK\tfallback\turl=%@\tresult=%@\terror=%@",
          url.path,
          library,
          fallbackError);
    if (library != nil && error != NULL) {
        *error = nil;
    } else if (error != NULL) {
        *error = fallbackError;
    }
    return library;
}

static void InstallMetalLibraryFallback(id<MTLDevice> device) {
    SEL selector = @selector(newDefaultLibraryWithBundle:error:);
    Class cls = object_getClass(device);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        Trace(@"METAL_HOOK\tmissing\tclass=%@", cls);
        return;
    }

    gOriginalNewDefaultLibrarySelector = selector;
    gOriginalNewDefaultLibraryWithBundle =
        (id (*)(id, SEL, NSBundle *, NSError **))method_getImplementation(method);

    Class pvgClass = NSClassFromString(@"_PGDevice");
    Method setupMethod =
        class_getInstanceMethod(pvgClass, NSSelectorFromString(@"setupBlitPipelines"));
    Dl_info pvgInfo = {0};
    if (setupMethod == NULL ||
        dladdr((const void *)method_getImplementation(setupMethod), &pvgInfo) == 0) {
        Trace(@"METAL_HOOK\tfailed-to-find-pvg-image");
        return;
    }

    uintptr_t targetAddress = (uintptr_t)ptrauth_strip(
        (void *)TraceNewDefaultLibraryWithBundle,
        ptrauth_key_function_pointer);
    // Exact macOS 13.2.1 (22D68) calls to
    // -[MTLDevice newDefaultLibraryWithBundle:error:] in
    // PGDisplayPipelineCache and _PGDevice.
    const uintptr_t callOffsets[] = {0xe6d8, 0xed24};
    for (size_t index = 0;
         index < sizeof(callOffsets) / sizeof(callOffsets[0]);
         index++) {
        uint32_t *callInstruction =
            (uint32_t *)((uintptr_t)pvgInfo.dli_fbase + callOffsets[index]);
        uintptr_t callAddress = (uintptr_t)callInstruction;
        intptr_t delta = (intptr_t)targetAddress - (intptr_t)callAddress;
        if ((delta & 3) != 0 ||
            delta < -(1LL << 27) ||
            delta >= (1LL << 27)) {
            Trace(@"METAL_HOOK\tbranch-out-of-range\tcall=%p\ttarget=%p",
                  callInstruction,
                  (void *)targetAddress);
            return;
        }

        uintptr_t page =
            callAddress & ~((uintptr_t)getpagesize() - 1);
        if (mprotect((void *)page,
                     (size_t)getpagesize(),
                     PROT_READ | PROT_WRITE) != 0) {
            Trace(@"METAL_HOOK\ttext-mprotect-write-failed\terrno=%d", errno);
            return;
        }
        uint32_t originalInstruction = *callInstruction;
        uint32_t replacementInstruction =
            0x94000000U | ((uint32_t)(delta >> 2) & 0x03ffffffU);
        *callInstruction = replacementInstruction;
        __builtin___clear_cache(
            (char *)callInstruction,
            (char *)callInstruction + sizeof(*callInstruction));
        if (mprotect((void *)page,
                     (size_t)getpagesize(),
                     PROT_READ | PROT_EXEC) != 0) {
            Trace(@"METAL_HOOK\ttext-mprotect-read-failed\terrno=%d", errno);
            return;
        }

        Trace(@"METAL_HOOK\tpatched\tcall=%p\ttarget=%p"
               "\tinstruction=%08x->%08x",
              callInstruction,
              (void *)targetAddress,
              originalInstruction,
              replacementInstruction);
    }

    Trace(@"METAL_HOOK\tinstalled\tclass=%@\toriginal=%p\treplacement=%p",
          cls,
          gOriginalNewDefaultLibraryWithBundle,
          TraceNewDefaultLibraryWithBundle);
}

static void InstallRequiredIPadOS14MetalLibraryFallback(
    Class pvgDeviceClass) {
    NSBundle *bundle = [NSBundle bundleForClass:pvgDeviceClass];
    NSURL *url = [bundle URLForResource:@"default.ipados14"
                          withExtension:@"metallib"];
    NSData *metallib = [NSData dataWithContentsOfURL:url];
    if (metallib != nil) {
        void *bytes = malloc(metallib.length);
        if (bytes != NULL) {
            memcpy(bytes, metallib.bytes, metallib.length);
            gSerializedMetallib = dispatch_data_create(
                bytes, metallib.length, NULL,
                DISPATCH_DATA_DESTRUCTOR_FREE);
        }
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device != nil && gSerializedMetallib != nil)
        InstallMetalLibraryFallback(device);
}

static void InstallBoolHook(Class cls,
                            SEL selector,
                            BOOL (**original)(id, SEL),
                            IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        Trace(@"HOOK\t%@\tmissing", NSStringFromSelector(selector));
        return;
    }
    *original = (BOOL (*)(id, SEL))method_setImplementation(method, replacement);
    Trace(@"HOOK\t%@\tinstalled", NSStringFromSelector(selector));
}

static void ProbeMetalLibrary(Class pvgDeviceClass) {
    NSBundle *bundle = [NSBundle bundleForClass:pvgDeviceClass];
    NSString *resourceName = HostMetalLibraryResourceName();
    NSURL *url = [bundle URLForResource:resourceName
                          withExtension:@"metallib"];
    Trace(@"BUNDLE\tpath=%@\tmetallib=%@", bundle.bundlePath, url.path);

    NSData *serializedMetallib = [NSData dataWithContentsOfURL:url];
    if (serializedMetallib != nil) {
        void *bytes = malloc(serializedMetallib.length);
        if (bytes != NULL) {
            memcpy(bytes, serializedMetallib.bytes, serializedMetallib.length);
            gSerializedMetallib =
                dispatch_data_create(bytes,
                                     serializedMetallib.length,
                                     NULL,
                                     DISPATCH_DATA_DESTRUCTOR_FREE);
        }
    }
    Trace(@"METAL\tserialized-metallib-bytes=%lu",
          (unsigned long)serializedMetallib.length);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Trace(@"METAL\tdevice=%@", device);
    if (device == nil) {
        return;
    }
    if (gDebugLogging)
        InstallCommandBufferTrace(device);
    if (getenv("PVG_METALLIB_FALLBACK") != NULL ||
        HostIPadOSMajorVersion() == 14) {
        InstallMetalLibraryFallback(device);
    }

    // Loading the compatibility metallib is functional. Enumerating every
    // function and compiling diagnostic pipelines is not, and is too costly
    // for a normal VM boot.
    if (!gDebugLogging)
        return;

    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibraryWithBundle:bundle error:&error];
    Trace(@"METAL\tnewDefaultLibraryWithBundle\tresult=%@\terror=%@", library, error);
    if (library == nil && url != nil) {
        error = nil;
        library = [device newLibraryWithURL:url error:&error];
        Trace(@"METAL\tnewLibraryWithURL\tresult=%@\terror=%@", library, error);
    }
    if (library == nil) {
        return;
    }

    NSArray<NSString *> *names =
        [library.functionNames sortedArrayUsingSelector:@selector(compare:)];
    Trace(@"METAL\tfunctions=%@", names);
    for (NSString *name in names) {
        if (![name hasPrefix:@"Blit"]) {
            continue;
        }
        id<MTLFunction> function = [library newFunctionWithName:name];
        error = nil;
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&error];
        Trace(@"METAL\tcompute-pipeline=%d\tfunction=%@\terror=%@",
              pipeline != nil,
              name,
              error);
    }
}

__attribute__((constructor))
static void InstallPVGTrace(void) {
    @autoreleasepool {
        const char *debugValue = getenv("VZ_DEBUG_LOGGING");
        gDebugLogging = debugValue && debugValue[0] &&
            strcmp(debugValue, "0") != 0;
        BOOL tracing = getenv("PVG_TRACE") != NULL;
        BOOL requiresIPadOS14Fallback =
            HostIPadOSMajorVersion() == 14;
        if (!tracing && !requiresIPadOS14Fallback) {
            return;
        }
        if (tracing && gDebugLogging) {
            unlink(TracePath());
            Trace(@"TRACE\tloaded\tpid=%d", getpid());
        }

        void *factory = dlsym(RTLD_DEFAULT, "PGNewDeviceWithDescriptor");
        Dl_info factoryInfo = {0};
        dladdr(factory, &factoryInfo);
        Trace(@"SYMBOL\tPGNewDeviceWithDescriptor=%p\tbase=%p\toffset=0x%llx"
              "\timage=%s",
              factory,
              factoryInfo.dli_fbase,
              (unsigned long long)((uintptr_t)factory -
                                   (uintptr_t)factoryInfo.dli_fbase),
              factoryInfo.dli_fname ?: "(unknown)");

        Class cls = NSClassFromString(@"_PGDevice");
        Trace(@"CLASS\t_PGDevice=%@", cls);
        if (cls == Nil) {
            return;
        }
        if (requiresIPadOS14Fallback && !tracing) {
            InstallRequiredIPadOS14MetalLibraryFallback(cls);
            return;
        }

        SEL initSelector = NSSelectorFromString(@"initWithDescriptor:");
        SEL blitSelector = NSSelectorFromString(@"setupBlitPipelines");
        SEL reportingSelector = NSSelectorFromString(@"setupReporting");
        SEL getTaskSelector = NSSelectorFromString(@"getTaskID:");
        SEL createTaskSelector = NSSelectorFromString(
            @"createTaskID:taskRoot:length:restoring:");
        SEL deleteTaskSelector = NSSelectorFromString(@"deleteTaskID:");
        if (gDebugLogging) {
            TraceMethod(cls, initSelector);
            TraceMethod(cls, blitSelector);
            TraceMethod(cls, reportingSelector);
            TraceMethod(cls, getTaskSelector);
            TraceMethod(cls, createTaskSelector);
            TraceMethod(cls, deleteTaskSelector);
        }
        const char *pause = getenv("PVG_TRACE_PAUSE_SECONDS");
        if (gDebugLogging && pause != NULL) {
            unsigned int seconds = (unsigned int)strtoul(pause, NULL, 10);
            Trace(@"TRACE\tpausing=%u", seconds);
            sleep(seconds);
            Trace(@"TRACE\tresumed");
        }
        ProbeMetalLibrary(cls);
        InstallTextureDescriptorCompatibility();
        if (gDebugLogging)
            InstallMetalSerializerReferenceTrace();

        // Functional reservation selection and recycling use only the stable
        // descriptor block ABI on every supported iPadOS release. These
        // authenticated Objective-C method hooks are diagnostics only; saved
        // Ventura arm64e IMPs cannot safely round-trip through older runtimes.
        BOOL canInstallAuthenticatedMethods = !HostPredatesIPadOS16();
        if (gDebugLogging && canInstallAuthenticatedMethods) {
            Method createTaskMethod = class_getInstanceMethod(
                cls, createTaskSelector);
            if (createTaskMethod != NULL) {
                gOriginalCreateTaskID =
                    (void (*)(id, SEL, uint32_t, uint32_t, uint64_t, BOOL))
                        method_setImplementation(
                            createTaskMethod, (IMP)TraceCreateTaskID);
                Trace(@"HOOK\tcreateTaskID:\tinstalled");
            }
            Method deleteTaskMethod = class_getInstanceMethod(
                cls, deleteTaskSelector);
            if (deleteTaskMethod != NULL) {
                gOriginalDeleteTaskID =
                    (BOOL (*)(id, SEL, uint32_t))method_setImplementation(
                        deleteTaskMethod, (IMP)TraceDeleteTaskID);
                Trace(@"HOOK\tdeleteTaskID:\tinstalled");
            }
        }

        BOOL traceMethods = gDebugLogging &&
            getenv("PVG_TRACE_METHODS") != NULL;
        if (traceMethods && canInstallAuthenticatedMethods) {
            Method getTaskMethod = class_getInstanceMethod(
                cls, getTaskSelector);
            if (getTaskMethod != NULL) {
                gOriginalGetTaskID =
                    (id (*)(id, SEL, uint32_t))method_setImplementation(
                        getTaskMethod, (IMP)TraceGetTaskID);
                Trace(@"HOOK\tgetTaskID:\tinstalled");
            } else {
                Trace(@"HOOK\tgetTaskID:\tmissing");
            }
            Method initMethod = class_getInstanceMethod(cls, initSelector);
            if (initMethod != NULL) {
                gOriginalInitWithDescriptor =
                    (id (*)(id, SEL, id))method_setImplementation(
                        initMethod, (IMP)TraceInitWithDescriptor);
                Trace(@"HOOK\tinitWithDescriptor:\tinstalled");
            }
            Class surfaceClass =
                NSClassFromString(@"PGIOSurfaceHostDevice");
            Method surfaceInitMethod =
                class_getInstanceMethod(surfaceClass, initSelector);
            if (surfaceInitMethod != NULL) {
                gOriginalIOSurfaceInitWithDescriptor =
                    (id (*)(id, SEL, id))method_setImplementation(
                        surfaceInitMethod,
                        (IMP)TraceIOSurfaceInitWithDescriptor);
                Trace(@"HOOK\tPGIOSurfaceHostDevice initWithDescriptor:"
                      "\tinstalled");
            } else {
                Trace(@"HOOK\tPGIOSurfaceHostDevice initWithDescriptor:"
                      "\tmissing");
            }
            Method newDisplayMethod = class_getInstanceMethod(
                cls,
                NSSelectorFromString(
                    @"newDisplayWithDescriptor:port:serialNum:"));
            if (newDisplayMethod != NULL) {
                gOriginalNewDisplay =
                    (id (*)(id, SEL, id, NSUInteger, uint32_t))
                        method_setImplementation(
                            newDisplayMethod, (IMP)TraceNewDisplay);
                Trace(@"HOOK\tnewDisplayWithDescriptor:port:serialNum:"
                      "\tinstalled");
            }
            Class displayClass = NSClassFromString(@"_PGDisplay");
            Method displayInitMethod = class_getInstanceMethod(
                displayClass,
                NSSelectorFromString(
                    @"initWithDevice:descriptor:port:serialNum:"));
            if (displayInitMethod != NULL) {
                gOriginalDisplayInit =
                    (id (*)(id, SEL, id, id, NSUInteger, uint32_t))
                        method_setImplementation(
                            displayInitMethod, (IMP)TraceDisplayInit);
                Trace(@"HOOK\t_PGDisplay init\tinstalled");
            }
            Class cacheClass =
                NSClassFromString(@"PGDisplayPipelineCache");
            Method cacheInitMethod = class_getInstanceMethod(
                cacheClass, NSSelectorFromString(@"initWithDevice:"));
            if (cacheInitMethod != NULL) {
                gOriginalPipelineCacheInit =
                    (id (*)(id, SEL, id))method_setImplementation(
                        cacheInitMethod, (IMP)TracePipelineCacheInit);
                Trace(@"HOOK\tPGDisplayPipelineCache initWithDevice:"
                      "\tinstalled");
            }
            InstallBoolHook(cls,
                            blitSelector,
                            &gOriginalSetupBlitPipelines,
                            (IMP)TraceSetupBlitPipelines);
            InstallBoolHook(cls,
                            reportingSelector,
                            &gOriginalSetupReporting,
                            (IMP)TraceSetupReporting);
        } else if (traceMethods) {
            Trace(@"HOOK\tmethod-tracing-skipped\thost-pre-iPadOS16");
        }
    }
}
