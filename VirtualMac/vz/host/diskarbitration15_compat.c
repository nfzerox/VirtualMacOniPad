#include "VZPaths.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdarg.h>
#include <stdio.h>

typedef CFTypeRef DASessionRef;
typedef CFTypeRef DADiskRef;
typedef CFTypeRef DADissenterRef;
typedef unsigned int DADiskEjectOptions;
typedef unsigned int DADiskMountOptions;
typedef void (*DADiskEjectCallback)(DADiskRef, DADissenterRef, void *);
typedef void (*DADiskMountCallback)(DADiskRef, DADissenterRef, void *);

static void trace_call(const char *name)
{
    FILE *file = fopen(VZTemporaryPath("installation-usb.log"), "a");
    if (!file)
        return;
    fprintf(file, "[DiskArbitration15Compat] %s\n", name);
    fclose(file);
}

static CFMutableDictionaryRef create_placeholder(CFAllocatorRef allocator)
{
    return CFDictionaryCreateMutable(allocator, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

DASessionRef DASessionCreate(CFAllocatorRef allocator)
{
    trace_call("DASessionCreate");
    return create_placeholder(allocator);
}

void DASessionSetDispatchQueue(DASessionRef session, dispatch_queue_t queue)
{
    (void)session;
    (void)queue;
    trace_call("DASessionSetDispatchQueue");
}

void DASessionScheduleWithRunLoop(DASessionRef session, CFRunLoopRef run_loop,
                                  CFStringRef mode)
{
    (void)session;
    (void)run_loop;
    (void)mode;
    trace_call("DASessionScheduleWithRunLoop");
}

void DASessionUnscheduleFromRunLoop(DASessionRef session,
                                    CFRunLoopRef run_loop, CFStringRef mode)
{
    (void)session;
    (void)run_loop;
    (void)mode;
    trace_call("DASessionUnscheduleFromRunLoop");
}

DADiskRef DADiskCreateFromBSDName(CFAllocatorRef allocator,
                                  DASessionRef session, const char *name)
{
    (void)session;
    (void)name;
    trace_call("DADiskCreateFromBSDName");
    return create_placeholder(allocator);
}

DADiskRef DADiskCreateFromVolumePath(CFAllocatorRef allocator,
                                     DASessionRef session, CFURLRef path)
{
    (void)session;
    (void)path;
    trace_call("DADiskCreateFromVolumePath");
    return create_placeholder(allocator);
}

DADiskRef DADiskCopyWholeDisk(DADiskRef disk)
{
    trace_call("DADiskCopyWholeDisk");
    return disk ? CFRetain(disk) : NULL;
}

CFStringRef DADissenterGetStatusString(DADissenterRef dissenter)
{
    (void)dissenter;
    trace_call("DADissenterGetStatusString");
    return NULL;
}

void DADiskEject(DADiskRef disk, DADiskEjectOptions options,
                 DADiskEjectCallback callback, void *context)
{
    (void)options;
    trace_call("DADiskEject");
    if (callback)
        callback(disk, NULL, context);
}

void DADiskMountWithArguments(DADiskRef disk, CFURLRef path,
                              DADiskMountOptions options,
                              DADiskMountCallback callback, void *context,
                              CFStringRef argument, ...)
{
    (void)path;
    (void)options;
    (void)argument;
    trace_call("DADiskMountWithArguments");
    if (callback)
        callback(disk, NULL, context);
}
