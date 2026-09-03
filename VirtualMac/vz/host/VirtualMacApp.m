#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <QuartzCore/CADisplayLink.h>
#import "NSViewShim.h"
#import "VZVMLibraryViewController.h"
#import "VZAppSettings.h"
#import "VZDiagnostics.h"
#import "VZFailureDetailsViewController.h"
#import "VZGamepadBridge.h"
#import "VZProgressViewController.h"
#import "VZSettingsViewController.h"
#import "VZLocalization.h"
#import "VZSupport.h"
#import "VZGuestTools.h"
#import "VZGuestRuntimePolicy.h"
#import "VZTrackpadScrollBridge.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach-o/loader.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern int memorystatus_control(uint32_t command, int32_t pid,
                                uint32_t flags, void *buffer,
                                size_t buffer_size);

typedef struct {
    int32_t priority;
    uint64_t user_data;
} VZMemorystatusPriorityProperties;

static BOOL gVMJetsamProtectionActive;

static void setVMJetsamProtection(BOOL active)
{
    if (gVMJetsamProtectionActive == active)
        return;

    // The extracted VMM runs as a priority-180 system service on iPadOS 16,
    // while RunningBoard normally places the UIKit host in foreground band
    // 100. Under a real VM-page shortage that ordering kills the lightweight
    // app first and only then tears down its multi-gigabyte VMM. Keep the UI
    // one band above the VMM while a guest is running, so jetsam reclaims the
    // process that owns the memory and the surviving app can report the stop.
    // XNU 20/21 use the same bands before their iPadOS 16 tenfold renumbering.
    // https://github.com/apple-oss-distributions/xnu/blob/xnu-7195.141.2/bsd/sys/kern_memorystatus.h
    // https://github.com/apple-oss-distributions/xnu/blob/xnu-8019.41.5/bsd/sys/kern_memorystatus.h
    // https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.81.2/bsd/sys/kern_memorystatus.h
    NSInteger hostMajor = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    VZMemorystatusPriorityProperties properties = {
        .priority = active ? (hostMajor >= 16 ? 190 : 19)
                           : 0,
        .user_data = 0,
    };
    const uint32_t setPriorityProperties = 2;
    const uint32_t priorityIsAssertion = 1;
    errno = 0;
    // Clear only our assertion band when the VM stops. RunningBoard retains
    // ownership of the app's ordinary requested foreground/background band.
    int result = memorystatus_control(setPriorityProperties, getpid(),
        priorityIsAssertion, &properties, sizeof(properties));
    int error = errno;
    printf("[VirtualMac] VM jetsam protection active=%d priority=%d "
           "result=%d errno=%d\n", active, properties.priority,
           result, error);
    if (result == 0)
        gVMJetsamProtectionActive = active;
}

static id gVirtualMachine;
static id gVirtualMachineDelegate;
static UIView *gFramebufferView;
static id gFramebuffer;
static id gKeyboard;
static id gPointingDevice;
static UIView *gInputView;
static UIView *gDisplayContainer;
static CALayer *gDisplayLayer;
static UIImageView *gCursorView;
static UILabel *gStatusLabel;
static UIView *gHUDView;
static UIPanGestureRecognizer *gTouchScrollRecognizer;
static UIPinchGestureRecognizer *gPinchRecognizer;
static UIRotationGestureRecognizer *gRotationRecognizer;
static UITapGestureRecognizer *gSmartMagnifyRecognizer;
static BOOL gSoftwareKeyboardRequested;
static NSLayoutConstraint *gHUDHorizontalConstraint;
static NSLayoutConstraint *gHUDVerticalConstraint;
static IMP gOriginalFrameUpdate;
static IMP gOriginalCursorUpdate;
static uint64_t gFrameUpdateCount;
static uint64_t gCursorUpdateCount;
static uint64_t gPointerEventCount;
static uint64_t gPointerButtonEventCount;
static uint64_t gScrollEventCount;
static uint64_t gKeyEventCount;
static uint8_t gShiftPressedMask;
// Debug-only scroll diagnostics. Keep the timing and histogram work out of
// the normal input path; all writers/readers run on the main thread.
static uint64_t gScrollRateWindowEvents;
static double gScrollRateWindowStart;
static double gScrollRateLastWindow;
static double gScrollRatePeak;
static uint64_t gHealthScrollBeganEvents;
static uint64_t gHealthScrollChangedEvents;
static uint64_t gHealthScrollEndedEvents;
static uint64_t gLastHealthScrollCount;
static uint64_t gLastHealthPointerCount;
static uint64_t gLastHealthKeyCount;
static double gLastHealthSampleTime;
// Scroll coalescing state: gesture lifecycle + accumulated deltas flushed at
// most once per display frame by queueScrollWheel/flushPendingScroll.
static uint64_t gScrollReceivedEventCount;
static BOOL gScrollGestureActive;
static BOOL gScrollBeganDelivered;
static BOOL gScrollEndPending;
static NSUInteger gScrollEndPhase;
static CGVector gPendingScrollRaw;
static CGVector gPendingScrollAccelerated;
static BOOL gPendingScrollDirectionInverted;
static NSUInteger gPendingScrollDeviceCategory;
static CADisplayLink *gScrollDisplayLink;
static uint64_t gLastHealthReceivedCount;
static BOOL gDebugLogging;
static VZGamepadBridge *gGamepadBridge;
static BOOL gFixExternalDisplayScrollDirection;
static CGFloat gScrollingSpeed = 0.25;
static BOOL gShowCursorWhenUsingTouch = YES;
static BOOL gLastInputWasDirectTouch;
static BOOL gCursorSuppressedForDirectTouch;
static BOOL gRootHideInformationVisible;
static BOOL gRootHidePivotalActionApproved;
static BOOL gVideoMemoryAlertPresented;
static BOOL gCompatibilityNoticePresented;
static NSMutableArray *gRootHideInformationCompletions;
// Globe-held state, tracked from the Darwin relay (the tweak reports the
// globe's raw HID press, which is reliable and prompt). The tweak translates
// globe+<key> chords at the HID layer and relays the translated key; this flag
// only lets the app drop raw chord keys that also reach its press path, so the
// guest never sees both the raw key and the translated key.
static BOOL gGlobeDown;
static uint64_t gLastHealthFrameCount;
static uint64_t gLastHealthInteractionCount;
static NSUInteger gFrameStallIntervals;
static CGPoint gMouseLocation;
// UIKit's pointer has its own absolute coordinate that cannot be warped when
// a direct touchscreen tap moves the guest cursor. Track raw host motion
// separately and apply its deltas to the guest coordinate so the next click
// remains at the touchscreen-selected location.
static CGPoint gHostPointerLocation;
static BOOL gHostPointerLocationValid;
static BOOL gUIKitHoverActive;
static CGSize gLastInputBoundsSize;
static CGFloat gLastPinchScale = 1.0;
static CGFloat gLastRotation;
// UIKit reports an indirect-pointer click as a touch while GameController
// reports the same physical click independently. Keep both lifetimes and send
// their union so either source releasing first cannot break a drag.
static NSUInteger gHardwareMouseButtons;
static NSUInteger gTouchButtons;
// A light trackpad or Magic Mouse surface tap stops synthesized momentum in
// VirtualMacApplication before UIKit dispatches the event. With iPadOS Tap to
// Click enabled, the same contact can subsequently arrive as both an indirect
// UITouch button and a GameController button. Suppress only that contact's
// synthetic click; a later deliberate click must continue to reach the guest.
static CFTimeInterval gSuppressSurfaceClickUntil;
static NSUInteger gSuppressedHardwareMouseButtons;
static CGPoint gLastPointerLocation = {NAN, NAN};
static NSUInteger gLastPointerButtons = NSUIntegerMax;
static CGSize gDisplayPixelSize = {1920, 1440};
static CGSize gCursorPixelSize;
static CGPoint gCursorHotspot;
static CFTimeInterval gLastPredictedCursorTime;
static void (*gHostVMStarted)(void);
static SEL S(const char *name);
static void setObj(id object, const char *selector, id value);
static void sendKey(UIKeyboardHIDUsage usage, BOOL pressed);
static void sendPointer(CGPoint point, CGRect bounds, NSUInteger pressedButtons);
static void updateExternalCursorForNormalizedLocation(CGPoint location);
static void notePointerInputSource(BOOL directTouch);
static void setStatus(NSString *status);
static void flushPendingScroll(void);
static void resetScrollCoalescing(void);
static void resetScrollDiagnostics(void);
// External display (Keynote-style: UIWindow.screen = externalScreen)
static UIWindow *gExternalWindow;
static UIView *gExternalMirrorView;
static UIImageView *gExternalCursorView;

static CGRect displayViewportRect(CGSize contentSize, CGRect bounds);
static void updateDisplayGeometry(void);
static void logFramebufferState(id view, id framebuffer, const char *phase);
static BOOL externalDisplayEnabled(void);
static void connectExternalDisplay(void);
static void connectExternalDisplayWithScreen(UIScreen *screen);
static void disconnectExternalDisplay(void);
static void startVirtualMachine(UIView *container, id delegate,
                                NSString *bundlePath,
                                NSDictionary *options);
static UIViewController *VZTopPresentedController(
    UIViewController *controller);

static NSString *VZInstallationFailureExplanation(NSString *failure)
{
    if ([failure containsString:@"Unexpected device state 'DFU'"] ||
        [failure containsString:@"Code=4014"] ||
        [failure containsString:@"error: 4014"]) {
        return VZL(@"Another usbmuxd service took control of the virtual DFU device before it entered RestoreOS. Uninstall usbmuxd from Sileo and try again.");
    }
    if ([failure containsString:@"AMRestorePerformRestoreModeRestoreWithError failed with error: 100"] ||
        [failure containsString:@"error: 100"]) {
        return VZDeviceString(
            VZL(@"Verify your iPad has sufficient free storage and try again."),
            VZL(@"Verify your iPhone has sufficient free storage and try again."));
    }
    return nil;
}

static NSString *VZHostHardwareIdentifier(void)
{
    size_t length = 0;
    if (sysctlbyname("hw.machine", NULL, &length, NULL, 0) != 0 ||
        length < 2)
        return @"";
    char *bytes = calloc(1, length);
    if (!bytes)
        return @"";
    NSString *identifier = @"";
    if (sysctlbyname("hw.machine", bytes, &length, NULL, 0) == 0)
        identifier = [NSString stringWithUTF8String:bytes] ?: @"";
    free(bytes);
    return identifier;
}

static BOOL VZHostOSVersionSupported(BOOL phone)
{
    NSOperatingSystemVersion version =
        NSProcessInfo.processInfo.operatingSystemVersion;
    if (phone) {
        if (version.majorVersion != 16)
            return NO;
    } else if (version.majorVersion < 14 || version.majorVersion > 16) {
        return NO;
    }
    if (version.majorVersion < 16)
        return YES;
    return version.minorVersion < 3 ||
        (version.minorVersion == 3 && version.patchVersion <= 1);
}

static BOOL VZHostHardwareSupported(BOOL phone, NSString *identifier)
{
    if (phone)
        return [@[@"iPhone15,2", @"iPhone15,3"]
            containsObject:identifier];
    static NSSet<NSString *> *supportedIPads;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // M1 iPad Pro (11-inch 3rd generation and 12.9-inch 5th
        // generation), M1 iPad Air (5th generation), and M2 iPad Pro
        // (11-inch 4th generation and 12.9-inch 6th generation), including
        // every Wi-Fi and cellular board identifier.
        supportedIPads = [[NSSet alloc] initWithArray:@[
            @"iPad13,4", @"iPad13,5", @"iPad13,6", @"iPad13,7",
            @"iPad13,8", @"iPad13,9", @"iPad13,10", @"iPad13,11",
            @"iPad13,16", @"iPad13,17",
            @"iPad14,3", @"iPad14,4", @"iPad14,5", @"iPad14,6"
        ]];
    });
    return [supportedIPads containsObject:identifier];
}

static void VZPresentCompatibilityNotice(UIViewController *controller)
{
    if (gCompatibilityNoticePresented)
        return;
    // UI simulation must never make real hardware fail compatibility checks.
    BOOL phone = VZHostIsPhoneDevice();
    NSString *identifier = VZHostHardwareIdentifier();
    if (VZHostHardwareSupported(phone, identifier) &&
        VZHostOSVersionSupported(phone))
        return;
    gCompatibilityNoticePresented = YES;
    NSString *title = VZDeviceString(
        VZL(@"This iPad is incompatible with Virtual Mac"),
        VZL(@"This iPhone is incompatible with Virtual Mac"));
    NSString *message = phone
        ? VZL(@"Virtual Mac requires iPhone 14 Pro and iPhone 14 Pro Max running iOS 16 up to 16.3.1, or iPad Pro (M1, M2) and iPad Air (M1) running iPadOS 14 up to 16.3.1.")
        : VZL(@"Virtual Mac requires iPad Pro (M1, M2) or iPad Air (M1) running iPadOS 14 up to 16.3.1, or iPhone 14 Pro and iPhone 14 Pro Max running iOS 16 up to 16.3.1.");
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [VZTopPresentedController(controller)
        presentViewController:alert animated:YES completion:nil];
    printf("[VirtualMac] compatibility notice idiom=%s hardware=%s os=%s\n",
           phone ? "phone" : "pad", identifier.UTF8String,
           NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
}

static UIViewController *VZTopPresentedController(UIViewController *controller)
{
    while (controller.presentedViewController &&
           !controller.presentedViewController.isBeingDismissed)
        controller = controller.presentedViewController;
    return controller;
}

static void VZContinueAfterRootHideInformation(
    UIViewController *presenter, void (^continuation)(void))
{
    if (!VZIsRootHideEnvironment()) {
        if (continuation)
            continuation();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (continuation) {
            if (!gRootHideInformationCompletions)
                gRootHideInformationCompletions =
                    [[NSMutableArray alloc] init];
            id copied = [continuation copy];
            [gRootHideInformationCompletions addObject:copied];
            [copied release];
        }
        if (gRootHideInformationVisible)
            return;
        gRootHideInformationVisible = YES;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:
                VZL(@"Switch to the Official Version of Dopamine")
            message:VZL(@"Virtual Mac does not support the Dopamine-roothide environment. Remove the roothide jailbreak from Dopamine-roothide > Settings > Remove Jailbreak, then switch to the official version of Dopamine.")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            gRootHideInformationVisible = NO;
            NSArray *callbacks = [[gRootHideInformationCompletions copy]
                autorelease];
            [gRootHideInformationCompletions removeAllObjects];
            for (void (^callback)(void) in callbacks)
                callback();
        }]];
        [VZTopPresentedController(presenter)
            presentViewController:alert animated:YES completion:nil];
    });
}

// On iPadOS 15 and 16.2, CoreUI's candidate bar artwork can ask CoreImage for
// its legacy EAGL backend. Platform/unsandboxed apps receive a null GL entry
// point and crash in CI::GLContext before Virtual Mac code runs. CoreUI only
// requires an ordinary CIContext here, so use the supported Metal backend.
static id VZCoreUISharedMetalContext(id object, SEL selector) {
    (void)object; (void)selector;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        context = [[CIContext contextWithMTLDevice:device] retain];
    });
    return context;
}

#if 0
static NSString *VZLatestKeyboardRenderingCrash(void) {
    NSString *root = @"/var/mobile/Library/Logs/CrashReporter";
    NSArray *directoryNames = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:root error:nil];
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *name in directoryNames) {
        if ([name hasPrefix:@"VirtualMac-"] &&
            [name.pathExtension.lowercaseString isEqualToString:@"ips"])
            [candidates addObject:name];
    }
    NSArray *names = candidates;
    names = [names sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *left, NSString *right) {
            NSString *leftPath = [root stringByAppendingPathComponent:left];
            NSString *rightPath = [root stringByAppendingPathComponent:right];
            NSDate *leftDate = [[NSFileManager.defaultManager
                attributesOfItemAtPath:leftPath error:nil]
                fileModificationDate] ?: NSDate.distantPast;
            NSDate *rightDate = [[NSFileManager.defaultManager
                attributesOfItemAtPath:rightPath error:nil]
                fileModificationDate] ?: NSDate.distantPast;
            return [rightDate compare:leftDate];
        }];
    NSUInteger examined = 0;
    for (NSString *name in names) {
        if (++examined > 8)
            break;
        NSString *path = [root stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:nil];
        NSString *report = data.length
            ? [[[NSString alloc] initWithData:data
                encoding:NSUTF8StringEncoding] autorelease] : nil;
        if ([report containsString:@"CI::GLContext::GLContext"] &&
            [report containsString:@"CUIShapeEffectStack sharedCIContext"])
            return name;
    }
    return nil;
}

static void VZEnableKeyboardRenderingFixAfterCrash(void) {
    static NSString * const processedCrashKey =
        @"LastKeyboardRenderingCrashReport";
    NSString *crash = VZLatestKeyboardRenderingCrash();
    if (!crash.length || [crash isEqualToString:
        [VZAppSettings.sharedSettings stringForKey:processedCrashKey]])
        return;
    [VZAppSettings.sharedSettings setString:crash forKey:processedCrashKey];
    [VZAppSettings.sharedSettings setBool:YES
        forKey:VZKeyboardCrashWorkaroundKey];
    printf("[VirtualMac] enabled keyboard-rendering fix after crash %s\n",
        crash.UTF8String);
}
#endif

static void installKeyboardRenderingFix(void) {
    // This preference is either enabled explicitly or after the exact CoreUI
    // crash is observed on a previous launch. Do not guess from the OS version.
    if (![VZAppSettings.sharedSettings
            boolForKey:VZKeyboardCrashWorkaroundKey])
        return;
    dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI",
           RTLD_LAZY | RTLD_LOCAL);
    Class shapeEffects = objc_getClass("CUIShapeEffectStack");
    Method method = class_getClassMethod(shapeEffects,
        sel_registerName("sharedCIContext"));
    if (!method)
        return;
    class_replaceMethod(object_getClass(shapeEffects),
        method_getName(method), (IMP)VZCoreUISharedMetalContext,
        method_getTypeEncoding(method));
    printf("[VirtualMac] installed Metal keyboard-rendering fix\n");
}

static NSUInteger activePointerButtons(void) {
    return gHardwareMouseButtons | gTouchButtons;
}

static void notePointerInputSource(BOOL directTouch) {
    gLastInputWasDirectTouch = directTouch;
    BOOL suppress = directTouch && !gShowCursorWhenUsingTouch;
    if (gCursorSuppressedForDirectTouch == suppress)
        return;
    gCursorSuppressedForDirectTouch = suppress;
    BOOL show = !suppress && gCursorView.image && gInputView &&
        !gInputView.hidden;
    gCursorView.hidden = !show;
    if (gExternalCursorView) {
        gExternalCursorView.hidden = !show;
        if (show)
            updateExternalCursorForNormalizedLocation(gLastPointerLocation);
    }
}

static BOOL shouldShowStatusLabel(void) {
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if ([processInfo.arguments containsObject:@"--show-status-label"])
        return YES;
    return [VZAppSettings.sharedSettings boolForKey:VZShowStatusLabelKey];
}

static void resetPointerSession(BOOL releaseButtons) {
    gHostPointerLocationValid = NO;
    gUIKitHoverActive = NO;
    gSuppressSurfaceClickUntil = 0;
    gSuppressedHardwareMouseButtons = 0;
    resetScrollCoalescing();
    VZTrackpadScrollBridgeReset();
    notePointerInputSource(NO);
    if (releaseButtons && (gTouchButtons || gHardwareMouseButtons)) {
        gTouchButtons = 0;
        gHardwareMouseButtons = 0;
        if (gInputView)
            sendPointer(gMouseLocation, gInputView.bounds, 0);
    }
}

static void startHealthMonitor(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    gLastHealthSampleTime = CACurrentMediaTime();
    dispatch_source_set_event_handler(timer, ^{
        NSInteger state = gVirtualMachine
            ? ((NSInteger(*)(id, SEL))objc_msgSend)(
                  gVirtualMachine, S("state"))
            : -1;
        uint64_t frames = __atomic_load_n(
            &gFrameUpdateCount, __ATOMIC_RELAXED);
        uint64_t interactions = __atomic_load_n(
            &gPointerButtonEventCount, __ATOMIC_RELAXED) +
            __atomic_load_n(&gScrollEventCount, __ATOMIC_RELAXED) +
            __atomic_load_n(&gKeyEventCount, __ATOMIC_RELAXED);
        double now = CACurrentMediaTime();
        double elapsed = MAX(now - gLastHealthSampleTime, 1e-3);
        uint64_t scroll = __atomic_load_n(
            &gScrollEventCount, __ATOMIC_RELAXED);
        uint64_t pointer = __atomic_load_n(
            &gPointerEventCount, __ATOMIC_RELAXED);
        uint64_t keys = __atomic_load_n(
            &gKeyEventCount, __ATOMIC_RELAXED);
        uint64_t received = gScrollReceivedEventCount;
        uint64_t scrollInTick = scroll - gLastHealthScrollCount;
        uint64_t receivedInTick = received - gLastHealthReceivedCount;
        uint64_t pointerInTick = pointer - gLastHealthPointerCount;
        uint64_t keysInTick = keys - gLastHealthKeyCount;
        if (gDebugLogging &&
            (scrollInTick || pointerInTick || keysInTick)) {
            // Debug logging distinguishes raw UIKit delivery from the
            // coalesced events injected into the guest.
            printf("[VirtualMac] input-rate scroll=%.0f/s received=%.0f/s "
                   "window=%.0f/s peak=%.0f/s began=%llu changed=%llu "
                   "ended=%llu pointer=%.0f/s keys=%.0f/s\n",
                   (double)scrollInTick / elapsed,
                   (double)receivedInTick / elapsed,
                   gScrollRateLastWindow, gScrollRatePeak,
                   (unsigned long long)gHealthScrollBeganEvents,
                   (unsigned long long)gHealthScrollChangedEvents,
                   (unsigned long long)gHealthScrollEndedEvents,
                   (double)pointerInTick / elapsed,
                   (double)keysInTick / elapsed);
            gHealthScrollBeganEvents = 0;
            gHealthScrollChangedEvents = 0;
            gHealthScrollEndedEvents = 0;
        }
        if (gDebugLogging && state >= 0) {
            printf("[VirtualMac] health state=%ld frames=%llu cursors=%llu "
                   "pointer=%llu scroll=%llu keys=%llu\n",
                   (long)state,
                   (unsigned long long)frames,
                   (unsigned long long)__atomic_load_n(
                       &gCursorUpdateCount, __ATOMIC_RELAXED),
                   (unsigned long long)__atomic_load_n(
                       &gPointerEventCount, __ATOMIC_RELAXED),
                   (unsigned long long)__atomic_load_n(
                       &gScrollEventCount, __ATOMIC_RELAXED),
                   (unsigned long long)__atomic_load_n(
                       &gKeyEventCount, __ATOMIC_RELAXED));
        }
        if (state == 1 && frames != 0 && frames == gLastHealthFrameCount &&
            interactions != gLastHealthInteractionCount) {
            gFrameStallIntervals++;
            if (gFrameStallIntervals == 3 ||
                gFrameStallIntervals % 6 == 0) {
                printf("[VirtualMac] display stall intervals=%lu frames=%llu "
                       "scroll-window=%.0f/s scroll-peak=%.0f/s\n",
                       (unsigned long)gFrameStallIntervals,
                       (unsigned long long)frames,
                       gScrollRateLastWindow, gScrollRatePeak);
                logFramebufferState(
                    gFramebufferView, gFramebuffer, "stalled");
            }
        } else {
            gFrameStallIntervals = 0;
        }
        gLastHealthFrameCount = frames;
        gLastHealthInteractionCount = interactions;
        gLastHealthScrollCount = scroll;
        gLastHealthReceivedCount = received;
        gLastHealthPointerCount = pointer;
        gLastHealthKeyCount = keys;
        gLastHealthSampleTime = now;
    });
    dispatch_resume(timer);
}

typedef struct {
    const void *object;
    const void *control;
} VZFrameUpdateSharedPtr;

static id CLS(const char *name) { return (id)objc_getClass(name); }
static SEL S(const char *name) { return sel_registerName(name); }
static id m0(id object, const char *selector) {
    return ((id(*)(id, SEL))objc_msgSend)(object, S(selector));
}
static id NEW(const char *className) {
    return m0(m0(CLS(className), "alloc"), "init");
}
static void setObj(id object, const char *selector, id value) {
    ((void(*)(id, SEL, id))objc_msgSend)(object, S(selector), value);
}
static NSURL *fileURL(NSString *path) {
    return [NSURL fileURLWithPath:path];
}

static CGPoint clampPointerLocation(CGPoint point, CGRect bounds) {
    return CGPointMake(
        fmin(CGRectGetMaxX(bounds), fmax(CGRectGetMinX(bounds), point.x)),
        fmin(CGRectGetMaxY(bounds), fmax(CGRectGetMinY(bounds), point.y)));
}

static void sendPointer(CGPoint point, CGRect bounds,
                        NSUInteger pressedButtons) {
    if (!gPointingDevice || bounds.size.width <= 0 ||
        bounds.size.height <= 0)
        return;
    // gInputView covers the visible guest viewport normally, but expands to
    // the complete iPad window while mirroring. Mapping its complete bounds
    // then makes the iPad an edge-to-edge input surface for the external
    // screen instead of leaving dead input regions in the iPad letterbox.
    CGRect guestViewport = gExternalWindow
        ? displayViewportRect(gDisplayPixelSize, bounds) : bounds;
    point = clampPointerLocation(point, guestViewport);
    gMouseLocation = point;
    CGPoint normalized = CGPointMake(
        fmin(1.0, fmax(0.0,
            (point.x - guestViewport.origin.x) / guestViewport.size.width)),
        fmin(1.0, fmax(0.0,
            (point.y - guestViewport.origin.y) / guestViewport.size.height)));
    // Draw the already-decoded guest cursor at the host event location now.
    // Waiting for the pointer round-trip through VMM/PVG adds a very visible
    // frame or two of latency on an iPad trackpad.
    if (gCursorView && !gCursorView.hidden && gCursorView.image) {
        CGFloat scaleX = guestViewport.size.width / gDisplayPixelSize.width;
        CGFloat scaleY = guestViewport.size.height / gDisplayPixelSize.height;
        CGSize size = CGSizeMake(gCursorPixelSize.width * scaleX,
                                 gCursorPixelSize.height * scaleY);
        CGPoint origin = CGPointMake(
            gInputView.frame.origin.x + point.x - gCursorHotspot.x * scaleX,
            gInputView.frame.origin.y + point.y - gCursorHotspot.y * scaleY);
        gCursorView.frame = (CGRect){origin, size};
        gLastPredictedCursorTime = CACurrentMediaTime();
    }
    updateExternalCursorForNormalizedLocation(normalized);
    BOOL buttonsChanged = pressedButtons != gLastPointerButtons;
    if (!buttonsChanged && CGPointEqualToPoint(normalized,
                                               gLastPointerLocation))
        return;
    gLastPointerLocation = normalized;
    gLastPointerButtons = pressedButtons;
    if (buttonsChanged)
        __sync_add_and_fetch(&gPointerButtonEventCount, 1);
    id event = ((id(*)(id, SEL, CGPoint, NSInteger))objc_msgSend)(
        m0(CLS("_VZScreenCoordinatePointerEvent"), "alloc"),
        S("initWithLocation:pressedButtons:"),
        normalized, (NSInteger)pressedButtons);
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendPointerEvents:"), @[event]);
    [event release];
    uint64_t count = __sync_add_and_fetch(&gPointerEventCount, 1);
    if (count <= 8 || buttonsChanged)
        printf("[VirtualMac] input pointer=%llu location=%.4f,%.4f buttons=0x%lx\n",
               (unsigned long long)count, normalized.x, normalized.y,
               (unsigned long)pressedButtons);
}

static void sendIndirectPointerLocation(CGPoint hostPoint, CGRect bounds) {
    // Trackpad coordinates are already absolute in the input view. Prefer reliable native absolute tracking; 
    // after touching the screen, the next trackpad movement/click simply uses its own location.
    notePointerInputSource(NO);
    sendPointer(hostPoint, bounds, activePointerButtons());
}

static void sendMagnification(double magnification, NSUInteger phase) {
    if (!gPointingDevice)
        return;
    id event = ((id(*)(id, SEL, double, NSUInteger))objc_msgSend)(
        m0(CLS("_VZMagnifyEvent"), "alloc"),
        S("initWithMagnification:phase:"), magnification, phase);
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendMagnifyEvents:"), @[event]);
    [event release];
    if (gDebugLogging)
        printf("[VirtualMac] input magnify delta=%.4f phase=0x%lx\n",
               magnification, (unsigned long)phase);
}

static void sendRotation(double rotation, NSUInteger phase) {
    if (!gPointingDevice)
        return;
    id event = ((id(*)(id, SEL, double, NSUInteger))objc_msgSend)(
        m0(CLS("_VZRotationEvent"), "alloc"),
        S("initWithRotation:phase:"), rotation, phase);
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendRotationEvents:"), @[event]);
    [event release];
    if (gDebugLogging)
        printf("[VirtualMac] input rotate delta=%.4f phase=0x%lx\n",
               rotation, (unsigned long)phase);
}

static void sendSmartMagnification(void) {
    if (!gPointingDevice)
        return;
    id event = NEW("_VZSmartMagnifyEvent");
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendSmartMagnifyEvents:"), @[event]);
    [event release];
    if (gDebugLogging)
        printf("[VirtualMac] input smart magnify\n");
}

static void sendMouseDelta(float deltaX, float deltaY) {
    dispatch_async(dispatch_get_main_queue(), ^{
        notePointerInputSource(NO);
        CGRect bounds = gInputView.bounds;
        gMouseLocation.x =
            fmin(CGRectGetMaxX(bounds), fmax(CGRectGetMinX(bounds),
                                             gMouseLocation.x + deltaX));
        gMouseLocation.y =
            fmin(CGRectGetMaxY(bounds), fmax(CGRectGetMinY(bounds),
                                             gMouseLocation.y - deltaY));
        sendPointer(gMouseLocation, bounds, activePointerButtons());
    });
}

static void sendMouseButton(NSUInteger mask, BOOL pressed) {
    dispatch_async(dispatch_get_main_queue(), ^{
        notePointerInputSource(NO);
        if (pressed && CACurrentMediaTime() <= gSuppressSurfaceClickUntil) {
            gSuppressedHardwareMouseButtons |= mask;
            gHardwareMouseButtons &= ~mask;
            if (gDebugLogging)
                printf("[VirtualMac] suppressed momentum-interrupt "
                       "hardware click button=0x%lx\n",
                       (unsigned long)mask);
            return;
        }
        if (!pressed && (gSuppressedHardwareMouseButtons & mask)) {
            gSuppressedHardwareMouseButtons &= ~mask;
            gHardwareMouseButtons &= ~mask;
            return;
        }
        if (pressed)
            gHardwareMouseButtons |= mask;
        else
            gHardwareMouseButtons &= ~mask;
        sendPointer(gMouseLocation, gInputView.bounds,
                    activePointerButtons());
    });
}

// UIScrollEvent exposes momentum as a sequential private enum. VZ accepts
// NSEvent-compatible phase bits and converts those to its wire enum.
static NSUInteger hidMomentumPhaseFromUIKitPhase(NSUInteger phase) {
    switch (phase) {
    case 0x01: return 1;
    case 0x02: return 4;
    case 0x03: return 8;
    case 0x04: return 16;
    default: return 0;
    }
}

// Immediate injection of one scroll event into the guest pointing device.
// Applies the device transforms, builds _VZScrollWheelEvent, and maintains
// the scroll diagnostics counters. Main thread only.
static void sendScrollWheelEvent(CGVector rawDelta, CGVector acceleratedDelta,
                                 BOOL directionInvertedFromDevice,
                                 NSUInteger deviceCategory,
                                 NSUInteger phase,
                                 NSUInteger momentumPhase) {
    if (!gPointingDevice)
        return;
    UIScreen *inputScreen = gInputView.window.screen;
    BOOL externalStageManager = inputScreen &&
        inputScreen != UIScreen.mainScreen;
    BOOL correctedExternalAxes = deviceCategory == 2 &&
        gFixExternalDisplayScrollDirection && externalStageManager;
    if (correctedExternalAxes) {
        // Stage Manager on an external display transposes the hardware
        // scroll axes and reverses the delta that becomes vertical after the
        // transpose. Correct both before applying the normal VZ mapping.
        rawDelta = CGVectorMake(-rawDelta.dy, rawDelta.dx);
        acceleratedDelta = CGVectorMake(-acceleratedDelta.dy,
                                        acceleratedDelta.dx);
    }
    if (deviceCategory == 0 && gShiftPressedMask) {
        // VZ's private wheel event does not carry modifier flags. Reproduce
        // AppKit's Shift+wheel convention while the separately forwarded
        // guest Shift key remains down.
        rawDelta = CGVectorMake(rawDelta.dy, -rawDelta.dx);
        acceleratedDelta = CGVectorMake(acceleratedDelta.dy,
                                        -acceleratedDelta.dx);
    }
    id event = ((id(*)(id, SEL, double, double, double, double,
                       NSUInteger, NSUInteger))objc_msgSend)(
        m0(CLS("_VZScrollWheelEvent"), "alloc"),
        S("initWithScrollingDeltaX:scrollingDeltaY:"
          "acceleratedScrollingDeltaX:acceleratedScrollingDeltaY:"
          "scrollPhase:momentumPhase:"),
        -rawDelta.dy, rawDelta.dx,
        -acceleratedDelta.dy, acceleratedDelta.dx, phase, momentumPhase);
    if (!event)
        return;
    ((void(*)(id, SEL, id))objc_msgSend)(
        gPointingDevice, S("sendScrollWheelEvents:"), @[event]);
    [event release];
    uint64_t count = __sync_add_and_fetch(&gScrollEventCount, 1);
    if (gDebugLogging) {
        // Bucket events into 1s windows only when diagnostics are requested.
        double now = CACurrentMediaTime();
        if (now - gScrollRateWindowStart >= 1.0) {
            double rate = gScrollRateWindowEvents /
                MAX(now - gScrollRateWindowStart, 1e-3);
            gScrollRateLastWindow = rate;
            if (rate > gScrollRatePeak)
                gScrollRatePeak = rate;
            gScrollRateWindowEvents = 0;
            gScrollRateWindowStart = now;
        }
        gScrollRateWindowEvents++;
        if (momentumPhase == 0 && phase == 1)
            gHealthScrollBeganEvents++;
        else if (momentumPhase == 0 && phase == 4)
            gHealthScrollChangedEvents++;
        else if (momentumPhase == 0 && phase == 8)
            gHealthScrollEndedEvents++;
    }
    if (count <= 12 || (gDebugLogging &&
                        (phase != 4 || momentumPhase != 4)))
        printf("[VirtualMac] input scroll=%llu raw=%.3f,%.3f "
               "accelerated=%.3f,%.3f inverted=%d device=%lu "
               "phase=0x%lx momentum=0x%lx external-axis-fix=%d\n",
               (unsigned long long)count, rawDelta.dx, rawDelta.dy,
               acceleratedDelta.dx, acceleratedDelta.dy,
               directionInvertedFromDevice, (unsigned long)deviceCategory,
               (unsigned long)phase, (unsigned long)momentumPhase,
               correctedExternalAxes);
}

static BOOL gTrackpadDirectionInverted;
static BOOL gSurfaceMouseDirectionInverted;

static void emitTrackpadScroll(CGVector rawDelta,
                               CGVector acceleratedDelta,
                               NSUInteger phase,
                               NSUInteger momentumPhase,
                               __unused void *context) {
    sendScrollWheelEvent(rawDelta, acceleratedDelta,
                         gTrackpadDirectionInverted, 2, phase,
                         momentumPhase);
}

static void emitTouchScroll(CGVector rawDelta,
                            CGVector acceleratedDelta,
                            NSUInteger phase,
                            NSUInteger momentumPhase,
                            __unused void *context) {
    sendScrollWheelEvent(rawDelta, acceleratedDelta, YES, 1, phase,
                         momentumPhase);
}

static void emitSurfaceMouseScroll(CGVector rawDelta,
                                   CGVector acceleratedDelta,
                                   NSUInteger phase,
                                   NSUInteger momentumPhase,
                                   __unused void *context) {
    sendScrollWheelEvent(rawDelta, acceleratedDelta,
                         gSurfaceMouseDirectionInverted, 1, phase,
                         momentumPhase);
}

// Immediate single-event path kept for the scripted input command; the
// gesture recognizers go through queueScrollWheel for per-frame coalescing.
static void sendScrollWheel(CGVector rawDelta, CGVector acceleratedDelta,
                            BOOL directionInvertedFromDevice,
                            NSUInteger deviceCategory,
                            NSUInteger phase) {
    sendScrollWheelEvent(rawDelta, acceleratedDelta,
                         directionInvertedFromDevice, deviceCategory,
                         phase, 0);
}

// ---- Scroll coalescing ----
// Physical wheels can deliver several UIKit scroll events per display frame
// (HID mice report up to 1000 Hz). Injecting every one synchronously floods
// the guest event queue and reads as stutter. Instead, accumulate the raw
// deltas and inject at most one event per frame on a CADisplayLink, the same
// strategy macOS uses for wheel input. All state here is main-thread only.

@interface VZScrollFlusher : NSObject
@end

@implementation VZScrollFlusher
- (void)flushTick
{
    flushPendingScroll();
}
@end

static VZScrollFlusher *gScrollFlusher;

static void resumeScrollFlush(void) {
    if (!gScrollDisplayLink) {
        if (!gScrollFlusher)
            gScrollFlusher = [[VZScrollFlusher alloc] init];
        gScrollDisplayLink = [CADisplayLink
            displayLinkWithTarget:gScrollFlusher
                         selector:@selector(flushTick)];
        [gScrollDisplayLink retain];
        [gScrollDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                 forMode:NSRunLoopCommonModes];
        gScrollDisplayLink.paused = YES;
    }
    gScrollDisplayLink.paused = NO;
}

// Physical wheel notches arrive as a single UIKit event whose accelerated
// delta can reach hundreds of points on fast spins. Forwarding that whole
// jump in one event makes the guest lurch once per notch at low event rates;
// instead slice each burst into per-frame chunks of at most this many points
// so the guest sees a continuous, smooth stream (like macOS wheel delivery).
static const double kScrollMaxDeltaPerEvent = 40.0;

static void flushPendingScroll(void) {
    gScrollDisplayLink.paused = YES;
    if (!gPointingDevice) {
        resetScrollCoalescing();
        return;
    }
    BOOL sendBegan = gScrollGestureActive && !gScrollBeganDelivered;
    BOOL hasPendingDelta = gPendingScrollRaw.dx != 0 ||
        gPendingScrollRaw.dy != 0 ||
        gPendingScrollAccelerated.dx != 0 ||
        gPendingScrollAccelerated.dy != 0;
    if (!sendBegan && !hasPendingDelta && !gScrollEndPending)
        return; // nothing to deliver this frame

    // Slice this frame's delta: the whole pending delta when it fits under
    // the per-event cap, otherwise a proportional slice so the raw and
    // accelerated components keep the ratio the device reported.
    double maxDelta = MAX(fabs(gPendingScrollAccelerated.dx),
                          fabs(gPendingScrollAccelerated.dy));
    CGVector deltaRaw = gPendingScrollRaw;
    CGVector deltaAccel = gPendingScrollAccelerated;
    if (gPendingScrollDeviceCategory == 0 &&
        maxDelta > kScrollMaxDeltaPerEvent) {
        double ratio = kScrollMaxDeltaPerEvent / maxDelta;
        deltaRaw = CGVectorMake(gPendingScrollRaw.dx * ratio,
                                gPendingScrollRaw.dy * ratio);
        deltaAccel = CGVectorMake(gPendingScrollAccelerated.dx * ratio,
                                  gPendingScrollAccelerated.dy * ratio);
    }
    gPendingScrollRaw = CGVectorMake(
        gPendingScrollRaw.dx - deltaRaw.dx,
        gPendingScrollRaw.dy - deltaRaw.dy);
    gPendingScrollAccelerated = CGVectorMake(
        gPendingScrollAccelerated.dx - deltaAccel.dx,
        gPendingScrollAccelerated.dy - deltaAccel.dy);
    BOOL drained = gPendingScrollRaw.dx == 0 && gPendingScrollRaw.dy == 0 &&
        gPendingScrollAccelerated.dx == 0 &&
        gPendingScrollAccelerated.dy == 0;
    if (sendBegan || deltaRaw.dx != 0 || deltaRaw.dy != 0 ||
        deltaAccel.dx != 0 || deltaAccel.dy != 0) {
        // Mouse wheels are phase-less on a real Mac. Trackpad and direct
        // touch input retain their began/changed lifecycle so AppKit can
        // rubber-band and finalize the gesture normally.
        NSUInteger eventPhase = gPendingScrollDeviceCategory == 0
            ? 0 : (sendBegan ? 1 : 4);
        sendScrollWheelEvent(deltaRaw, deltaAccel,
                             gPendingScrollDirectionInverted,
                             gPendingScrollDeviceCategory,
                             eventPhase, 0);
        gScrollBeganDelivered = YES;
    }
    if (drained && gScrollEndPending) {
        // Close a direct two-finger touch gesture only after all coalesced
        // deltas have been delivered. Hardware wheels are phase-less below.
        sendScrollWheelEvent(CGVectorMake(0, 0), CGVectorMake(0, 0),
                             gPendingScrollDirectionInverted,
                             gPendingScrollDeviceCategory,
                             gScrollEndPhase ? gScrollEndPhase : 8, 0);
        gScrollEndPending = NO;
        gScrollEndPhase = 0;
        gScrollGestureActive = NO;
        gScrollBeganDelivered = NO;
    }

    // Keep the link alive only while delta remains to stream.
    if (!drained)
        gScrollDisplayLink.paused = NO;
}

static void queueScrollWheel(CGVector rawDelta, CGVector acceleratedDelta,
                             BOOL directionInvertedFromDevice,
                             NSUInteger deviceCategory,
                             NSUInteger phase) {
    if (gDebugLogging)
        gScrollReceivedEventCount++;
    BOOL eventHasDelta = rawDelta.dx != 0 || rawDelta.dy != 0 ||
        acceleratedDelta.dx != 0 || acceleratedDelta.dy != 0;
    // Hardware wheel input (deviceCategory 0) is discrete wheel semantics:
    // the guest receives phase-less scroll events, exactly like a real Mac
    // mouse wheel, so AppKit scroll views apply each delta directly. The
    // began/changed/ended gesture lifecycle applies to the direct two-finger
    // touch pan (deviceCategory 1) and high-resolution trackpad input
    // (deviceCategory 2), which are real gestures.
    // WebKit applies deltas regardless of phase, which is why browsers felt
    // smooth while AppKit scroll views stuttered.
    if (deviceCategory == 0) {
        gPendingScrollRaw = CGVectorMake(
            gPendingScrollRaw.dx + rawDelta.dx,
            gPendingScrollRaw.dy + rawDelta.dy);
        gPendingScrollAccelerated = CGVectorMake(
            gPendingScrollAccelerated.dx + acceleratedDelta.dx,
            gPendingScrollAccelerated.dy + acceleratedDelta.dy);
        gPendingScrollDirectionInverted = directionInvertedFromDevice;
        gPendingScrollDeviceCategory = deviceCategory;
        if (eventHasDelta)
            resumeScrollFlush();
        return;
    }
    switch (phase) {
    case 1: // began
        gScrollGestureActive = YES;
        gScrollBeganDelivered = NO;
        gScrollEndPending = NO;
        gScrollEndPhase = 0;
        break;
    case 8: // ended
        gScrollEndPhase = 8;
        gScrollEndPending = YES;
        // UIKit repeats the last non-accelerated sample in the recognizer's
        // terminal callback. A real Mac sends a zero-delta phase-ended event;
        // accumulating the stale sample makes content jump on finger release.
        rawDelta = CGVectorMake(0, 0);
        acceleratedDelta = CGVectorMake(0, 0);
        eventHasDelta = NO;
        break;
    case 16: // cancelled / failed
        gScrollEndPhase = 16;
        gScrollEndPending = YES;
        rawDelta = CGVectorMake(0, 0);
        acceleratedDelta = CGVectorMake(0, 0);
        eventHasDelta = NO;
        break;
    case 4: // changed
        if (!gScrollGestureActive) {
            // Robustness: a changed event without a began must still reach
            // the guest; deliver it as a standalone changed.
            gScrollGestureActive = YES;
            gScrollBeganDelivered = YES;
        }
        if (eventHasDelta) {
            // A continuing stream cancels the pending end.
            gScrollEndPending = NO;
            gScrollEndPhase = 0;
        }
        break;
    default:
        break;
    }
    gPendingScrollRaw = CGVectorMake(
        gPendingScrollRaw.dx + rawDelta.dx,
        gPendingScrollRaw.dy + rawDelta.dy);
    gPendingScrollAccelerated = CGVectorMake(
        gPendingScrollAccelerated.dx + acceleratedDelta.dx,
        gPendingScrollAccelerated.dy + acceleratedDelta.dy);
    gPendingScrollDirectionInverted = directionInvertedFromDevice;
    gPendingScrollDeviceCategory = deviceCategory;
    // Resume the link only when there is something to deliver this frame.
    if (phase == 1 || gScrollEndPending || eventHasDelta)
        resumeScrollFlush();
}

static void resetScrollCoalescing(void) {
    gScrollGestureActive = NO;
    gScrollBeganDelivered = NO;
    gScrollEndPending = NO;
    gScrollEndPhase = 0;
    gPendingScrollRaw = CGVectorMake(0, 0);
    gPendingScrollAccelerated = CGVectorMake(0, 0);
    gPendingScrollDirectionInverted = NO;
    gPendingScrollDeviceCategory = 0;
    if (gScrollDisplayLink)
        gScrollDisplayLink.paused = YES;
}

static void resetScrollDiagnostics(void) {
    gScrollRateWindowEvents = 0;
    gScrollRateWindowStart = CACurrentMediaTime();
    gScrollRateLastWindow = 0;
    gScrollRatePeak = 0;
    gHealthScrollBeganEvents = 0;
    gHealthScrollChangedEvents = 0;
    gHealthScrollEndedEvents = 0;
    gLastHealthScrollCount = __atomic_load_n(
        &gScrollEventCount, __ATOMIC_RELAXED);
    gLastHealthReceivedCount = gScrollReceivedEventCount;
    gLastHealthPointerCount = __atomic_load_n(
        &gPointerEventCount, __ATOMIC_RELAXED);
    gLastHealthKeyCount = __atomic_load_n(
        &gKeyEventCount, __ATOMIC_RELAXED);
    gLastHealthSampleTime = CACurrentMediaTime();
}

static void installGCMouse(void) {
    GCMouse *mouse = GCMouse.current;
    printf("[VirtualMac] GC mouse current=%p input=%p\n",
           mouse, mouse.mouseInput);
    if (!mouse)
        return;
    mouse.mouseInput.mouseMovedHandler =
        ^(GCMouseInput *input, float deltaX, float deltaY) {
        (void)input;
        // UIKit hover is the authoritative absolute path for a trackpad.
        // Some devices also appear as GCMouse; accepting both makes motion
        // jump or hit artificial edges after system UI steals the pointer.
        if (gUIKitHoverActive)
            return;
        sendMouseDelta(deltaX, deltaY);
    };
    mouse.mouseInput.leftButton.pressedChangedHandler =
        ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        sendMouseButton(1, pressed);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler =
        ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        sendMouseButton(2, pressed);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler =
        ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        sendMouseButton(4, pressed);
    };
}

static void scheduleInputSelfTest(void) {
    if (unlink("/tmp/vz-input-self-test") != 0)
        return;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        CGRect bounds = gInputView.bounds;
        CGPoint point = CGPointMake(
            CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.75,
            CGRectGetMidY(bounds));
        printf("[VirtualMac] input self-test begin\n");
        sendPointer(point, bounds, 0);
        sendKey((UIKeyboardHIDUsage)0x39, YES);  // Caps Lock
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            sendKey((UIKeyboardHIDUsage)0x39, NO);
            printf("[VirtualMac] input self-test sent pointer and Caps Lock\n");
        });
    });
}

static void pollInputCommand(void) {
    NSString *path = @"/tmp/vz-input-command";
    NSString *command = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (command.length && unlink(path.fileSystemRepresentation) == 0) {
        NSArray<NSString *> *fields = [command
            componentsSeparatedByCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        for (NSString *field in fields) {
            if (field.length)
                [tokens addObject:field];
        }
        if (tokens.count == 2 && [tokens[0] isEqualToString:@"tapkey"]) {
            UIKeyboardHIDUsage usage = (UIKeyboardHIDUsage)tokens[1].intValue;
            printf("[VirtualMac] input command tapkey HID=0x%x\n",
                   (unsigned int)usage);
            sendKey(usage, YES);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ sendKey(usage, NO); });
        } else if (tokens.count == 3 &&
                   [tokens[0] isEqualToString:@"key"]) {
            UIKeyboardHIDUsage usage = (UIKeyboardHIDUsage)tokens[1].intValue;
            BOOL pressed = tokens[2].boolValue;
            printf("[VirtualMac] input command key HID=0x%x pressed=%d\n",
                   (unsigned int)usage, pressed);
            sendKey(usage, pressed);
        } else if (tokens.count == 4 &&
                   [tokens[0] isEqualToString:@"click"]) {
            CGFloat x = MAX(0, MIN(1, tokens[1].doubleValue));
            CGFloat y = MAX(0, MIN(1, tokens[2].doubleValue));
            NSUInteger button = MAX(1, MIN(4, tokens[3].integerValue));
            CGRect bounds = gInputView.bounds;
            CGPoint point = CGPointMake(CGRectGetWidth(bounds) * x,
                                        CGRectGetHeight(bounds) * y);
            printf("[VirtualMac] input command click %.3f,%.3f button=0x%lx\n",
                   x, y, (unsigned long)button);
            sendPointer(point, bounds, button);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ sendPointer(point, bounds, 0); });
        } else if (tokens.count == 4 &&
                   [tokens[0] isEqualToString:@"scroll"]) {
            double x = tokens[1].doubleValue;
            double y = tokens[2].doubleValue;
            NSUInteger phase = tokens[3].integerValue;
            printf("[VirtualMac] input command scroll %.3f,%.3f phase=0x%lx\n",
                   x, y, (unsigned long)phase);
            sendScrollWheel(CGVectorMake(x, y), CGVectorMake(x, y),
                            NO, 0, phase);
        } else if (tokens.count == 3 &&
                   [tokens[0] isEqualToString:@"magnify"]) {
            double delta = tokens[1].doubleValue;
            NSUInteger phase = tokens[2].integerValue;
            printf("[VirtualMac] input command magnify %.4f phase=0x%lx\n",
                   delta, (unsigned long)phase);
            sendMagnification(delta, phase);
        } else if (tokens.count == 3 &&
                   [tokens[0] isEqualToString:@"rotate"]) {
            double delta = tokens[1].doubleValue;
            NSUInteger phase = tokens[2].integerValue;
            printf("[VirtualMac] input command rotate %.4f phase=0x%lx\n",
                   delta, (unsigned long)phase);
            sendRotation(delta, phase);
        } else if (tokens.count == 1 &&
                   [tokens[0] isEqualToString:@"smartmagnify"]) {
            printf("[VirtualMac] input command smart magnify\n");
            sendSmartMagnification();
        } else if (tokens.count == 1 &&
                   [tokens[0] isEqualToString:@"screenshot"]) {
            // Development-only host-side capture. This captures the iPad
            // app's own view hierarchy rather than using macOS screencapture,
            // which is gated by guest Screen Recording TCC.
            UIView *captureView = gInputView.window ?: gInputView;
            UIGraphicsBeginImageContextWithOptions(
                captureView.bounds.size, NO, UIScreen.mainScreen.scale);
            BOOL drew = [captureView drawViewHierarchyInRect:captureView.bounds
                                          afterScreenUpdates:YES];
            UIImage *hostImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            NSData *png = hostImage ? UIImagePNGRepresentation(hostImage) : nil;
            BOOL saved = [png writeToFile:@"/tmp/VirtualMac-host.png"
                               atomically:YES];
            printf("[VirtualMac] input command screenshot drew=%d saved=%d "
                   "bytes=%lu\n", drew, saved, (unsigned long)png.length);
        } else {
            printf("[VirtualMac] invalid input command: %s\n",
                   command.UTF8String);
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ pollInputCommand(); });
}

static BOOL gForceStopPending;
static dispatch_source_t gControlTimer;

static void writeStopMarker(const char *path, const char *message) {
    FILE *marker = fopen(path, "w");
    if (!marker)
        return;
    fputs(message, marker);
    fputc('\n', marker);
    fclose(marker);
}

static void forceStopVirtualMachine(void) {
    if (!gVirtualMachine || gForceStopPending)
        return;

    NSInteger state = ((NSInteger(*)(id, SEL))objc_msgSend)(
        gVirtualMachine, S("state"));
    if (state == 0) {
        writeStopMarker("/tmp/vz-guest-stopped", "already stopped");
        return;
    }
    if (![gVirtualMachine respondsToSelector:S("stopWithCompletionHandler:")]) {
        writeStopMarker("/tmp/vz-force-stop-failed",
                        "stopWithCompletionHandler: unavailable");
        return;
    }

    gForceStopPending = YES;
    printf("[VirtualMac] direct virtual machine stop requested state=%ld\n",
           (long)state);
    void (^completion)(NSError *) = ^(NSError *error) {
        gForceStopPending = NO;
        if (error) {
            const char *description = [[error description] UTF8String];
            writeStopMarker("/tmp/vz-force-stop-failed",
                            description ?: "unknown direct stop error");
            printf("[VirtualMac] direct virtual machine stop failed: %s\n",
                   description ?: "unknown error");
            return;
        }
        writeStopMarker("/tmp/vz-guest-stopped", "direct stop complete");
        printf("[VirtualMac] direct virtual machine stop complete\n");
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([gVirtualMachineDelegate respondsToSelector:
                    S("finishVMAndShowLibraryWithError:")])
                ((void(*)(id, SEL, id))objc_msgSend)(
                    gVirtualMachineDelegate,
                    S("finishVMAndShowLibraryWithError:"), nil);
        });
    };
    ((void(*)(id, SEL, id))objc_msgSend)(
        gVirtualMachine, S("stopWithCompletionHandler:"), completion);
}

static void startControlMonitor(void) {
    gControlTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(
        gControlTimer,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(gControlTimer, ^{
        if (unlink("/tmp/vz-request-guest-stop") == 0)
            forceStopVirtualMachine();
        if (unlink("/tmp/vz-request-force-stop") == 0)
            forceStopVirtualMachine();
    });
    dispatch_resume(gControlTimer);
}

// Translate USB HID usages reported by UIKit to the macOS virtual key codes
// consumed by _VZKeyEvent. Cover the standard alphanumeric, navigation,
// function, and modifier keys used by the built-in iPad keyboard.
static NSInteger macVirtualKeyCode(UIKeyboardHIDUsage usage) {
    static const int16_t alphaAndNumberRow[] = {
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,
    };
    NSInteger raw = (NSInteger)usage;
    if (raw >= 0x04 && raw <= 0x27)
        return alphaAndNumberRow[raw - 0x04];
    switch (raw) {
    case 0x28: return 36;  // Return
    case 0x29: return 53;  // Escape
    case 0x2a: return 51;  // Delete / Backspace
    case 0x2b: return 48;  // Tab
    case 0x2c: return 49;  // Space
    case 0x2d: return 27;  // -
    case 0x2e: return 24;  // =
    case 0x2f: return 33;  // [
    case 0x30: return 30;  // ]
    case 0x31: return 42;  // Backslash
    case 0x33: return 41;  // ;
    case 0x34: return 39;  // Quote
    case 0x35: return 50;  // Grave
    case 0x36: return 43;  // Comma
    case 0x37: return 47;  // Period
    case 0x38: return 44;  // Slash
    case 0x39: return 57;  // Caps Lock
    case 0x3a: return 122; // F1
    case 0x3b: return 120; // F2
    case 0x3c: return 99;  // F3
    case 0x3d: return 118; // F4
    case 0x3e: return 96;  // F5
    case 0x3f: return 97;  // F6
    case 0x40: return 98;  // F7
    case 0x41: return 100; // F8
    case 0x42: return 101; // F9
    case 0x43: return 109; // F10
    case 0x44: return 103; // F11
    case 0x45: return 111; // F12
    case 0x46: return 105; // Print Screen / F13
    case 0x47: return 107; // Scroll Lock / F14
    case 0x48: return 113; // Pause / F15
    case 0x49: return 114; // Insert / Help
    case 0x4a: return 115; // Home
    case 0x4b: return 116; // Page Up
    case 0x4c: return 117; // Forward Delete
    case 0x4d: return 119; // End
    case 0x4e: return 121; // Page Down
    case 0x4f: return 124; // Right Arrow
    case 0x50: return 123; // Left Arrow
    case 0x51: return 125; // Down Arrow
    case 0x52: return 126; // Up Arrow
    case 0x53: return 71;  // Keypad Clear / Num Lock
    case 0x54: return 75;  // Keypad /
    case 0x55: return 67;  // Keypad *
    case 0x56: return 78;  // Keypad -
    case 0x57: return 69;  // Keypad +
    case 0x58: return 76;  // Keypad Enter
    case 0x59: return 83;  // Keypad 1
    case 0x5a: return 84;  // Keypad 2
    case 0x5b: return 85;  // Keypad 3
    case 0x5c: return 86;  // Keypad 4
    case 0x5d: return 87;  // Keypad 5
    case 0x5e: return 88;  // Keypad 6
    case 0x5f: return 89;  // Keypad 7
    case 0x60: return 91;  // Keypad 8
    case 0x61: return 92;  // Keypad 9
    case 0x62: return 82;  // Keypad 0
    case 0x63: return 65;  // Keypad decimal
    case 0x64: return 10;  // ISO non-US backslash
    case 0x67: return 81;  // Keypad =
    case 0x87: return 94;  // JIS underscore / Ro
    case 0x89: return 93;  // JIS Yen
    case 0x8a: return 104; // JIS Kana / conversion
    case 0x8b: return 102; // JIS Eisu / non-conversion
    case 0x8c: return 95;  // JIS keypad comma
    case 0x90: return 104; // LANG1 / Kana
    case 0x91: return 102; // LANG2 / Eisu
    case 0xe0: return 59;  // Left Control
    case 0xe1: return 56;  // Left Shift
    case 0xe2: return 58;  // Left Option
    case 0xe3: return 55;  // Left Command
    case 0xe4: return 62;  // Right Control
    case 0xe5: return 60;  // Right Shift
    case 0xe6: return 61;  // Right Option
    case 0xe7: return 54;  // Right Command
    default: return -1;
    }
}

static void sendKey(UIKeyboardHIDUsage usage, BOOL pressed) {
    if (usage == 0xe1) {
        if (pressed) gShiftPressedMask |= 1;
        else gShiftPressedMask &= ~1;
    } else if (usage == 0xe5) {
        if (pressed) gShiftPressedMask |= 2;
        else gShiftPressedMask &= ~2;
    }
    if (!gKeyboard)
        return;
    NSInteger keyCode = macVirtualKeyCode(usage);
    if (keyCode < 0) {
        printf("[VirtualMac] input unmapped HID usage=0x%lx\n",
               (unsigned long)usage);
        return;
    }
    id event = ((id(*)(id, SEL, NSInteger, unsigned short))objc_msgSend)(
        m0(CLS("_VZKeyEvent"), "alloc"), S("initWithType:keyCode:"),
        pressed ? 0 : 1, (unsigned short)keyCode);
    ((void(*)(id, SEL, id))objc_msgSend)(
        gKeyboard, S("sendKeyEvents:"), @[event]);
    [event release];
    uint64_t count = __sync_add_and_fetch(&gKeyEventCount, 1);
    if (count <= 12)
        printf("[VirtualMac] input key=%llu HID=0x%lx mac=%ld pressed=%d\n",
               (unsigned long long)count, (unsigned long)usage,
               (long)keyCode, pressed);
}

// The tweak translates globe+<key> chords at the HID layer (lines mirror a
// MacBook's Fn+arrow / Fn+Delete) and relays the translated key. When a raw
// chord key still reaches the app's press path — the globe does, so others may
// — drop it while the globe is held so the guest never gets the raw key on top
// of the translated one. Deliberately NOT a translation: iPadOS's input-method
// switcher eats globe+arrow before the app ever sees it, so the tweak must own
// the translation.
static BOOL VZIsGlobeChordSource(UIKeyboardHIDUsage usage)
{
    return usage == 0x52 || usage == 0x51 || usage == 0x50 ||
        usage == 0x4f || usage == 0x2a || usage == 0x28;
}

static BOOL sendPresses(NSSet<UIPress *> *presses, BOOL pressed) {
    // When no guest keyboard is active, UIKit owns hardware key events (for
    // example numeric input in the VM configuration alert). Treating a press
    // as handled merely because it has a HID key swallowed those keystrokes.
    if (!gKeyboard || !gInputView || gInputView.hidden || !gInputView.window)
        return NO;
    BOOL handled = NO;
    for (UIPress *press in presses) {
        if (!press.key)
            continue;
        UIKeyboardHIDUsage usage = press.key.keyCode;
        // The globe/Fn key reaches the app's press path as a Consumer-page
        // usage (0x29D on-device). The tweak already swallows it system-wide;
        // swallow the app's own copy too so it never reaches the guest.
        if (usage == 0x29d || usage == 0x22d || usage == 0x18a) {
            handled = YES;
            continue;
        }
        if (gGlobeDown && VZIsGlobeChordSource(usage)) {
            // Tweak relays the translated key; drop the raw chord key.
            handled = YES;
            continue;
        }
        sendKey(usage, pressed);
        handled = YES;
    }
    return handled;
}

static void shellShortcutNotification(CFNotificationCenterRef center,
                                      void *observer, CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)object;
    (void)userInfo;
    NSString *notification = (NSString *)name;
    BOOL pressed = [notification hasSuffix:@".down"];
    UIKeyboardHIDUsage usage = 0;
    if ([notification containsString:@"command-space"])
        usage = (UIKeyboardHIDUsage)0x2c;
    else if ([notification containsString:@"command-tab"])
        usage = (UIKeyboardHIDUsage)0x2b;
    else if ([notification containsString:@"command-grave"])
        usage = (UIKeyboardHIDUsage)0x35;
    else if ([notification containsString:@"globe"]) {
        // The tweak tracks held state from raw HID; the app mirrors it here so
        // sendPresses can drop raw chord keys while the globe is held. Nothing
        // is injected for the globe itself.
        gGlobeDown = pressed;
        printf("[VirtualMac] SpringBoard globe relay pressed=%d\n", pressed);
        return;
    } else if ([notification containsString:@"pageup"])
        usage = (UIKeyboardHIDUsage)0x4b;
    else if ([notification containsString:@"pagedown"])
        usage = (UIKeyboardHIDUsage)0x4e;
    else if ([notification containsString:@"home"])
        usage = (UIKeyboardHIDUsage)0x4a;
    else if ([notification containsString:@"end"])
        usage = (UIKeyboardHIDUsage)0x4d;
    else if ([notification containsString:@"forward-delete"])
        usage = (UIKeyboardHIDUsage)0x4c;
    else if ([notification containsString:@"keypad-enter"])
        usage = (UIKeyboardHIDUsage)0x58;
    if (usage) {
        printf("[VirtualMac] SpringBoard shortcut relay usage=0x%lx pressed=%d\n",
               (unsigned long)usage, pressed);
        sendKey(usage, pressed);
    }
}

static void installShellShortcutRelay(void) {
    CFNotificationCenterRef center =
        CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *shortcut in @[@"command-space", @"command-tab",
                                  @"command-grave", @"globe",
                                  @"pageup", @"pagedown", @"home", @"end",
                                  @"forward-delete", @"keypad-enter"]) {
        for (NSString *state in @[@"down", @"up"]) {
            NSString *name = [NSString stringWithFormat:
                @"com.mac.virtual.%@.%@", shortcut, state];
            CFNotificationCenterAddObserver(
                center, NULL, shellShortcutNotification,
                (CFStringRef)name, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }
}

static void videoMemoryExhaustedNotification(CFNotificationCenterRef center,
                                             void *observer,
                                             CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gVirtualMachine || gVideoMemoryAlertPresented)
            return;
        gVideoMemoryAlertPresented = YES;
        UIWindow *window = nil;
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        window = window ?: UIApplication.sharedApplication.windows.firstObject;
        UIViewController *controller = window.rootViewController;
        NSString *path = nil;
        @try { path = [controller valueForKey:@"activeVMBundlePath"]; }
        @catch (__unused NSException *exception) {}
        NSString *virtualMacName = path.lastPathComponent.stringByDeletingPathExtension;
        if (!virtualMacName.length)
            virtualMacName = VZL(@"Virtual Mac");
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:VZL(@"Out of Video Memory")
            message:[NSString stringWithFormat:
                VZL(@"%@ is out of video memory. macOS may appear frozen."),
                virtualMacName]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleDefault handler:nil]];
        [VZTopPresentedController(controller)
            presentViewController:alert animated:YES completion:nil];
    });
}

static void installVideoMemoryWarningRelay(void) {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        videoMemoryExhaustedNotification,
        CFSTR("com.mac.virtual.video-memory-exhausted"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

@interface NSObject (VZScrollEventSPI)
- (CGVector)nonAcceleratedDelta;
- (CGVector)acceleratedDelta;
- (BOOL)directionInvertedFromDevice;
- (NSUInteger)_scrollDeviceCategory;
- (NSUInteger)momentumPhase;
- (id)_hidEvent;
@end

static void VZDescribeRawScrollHIDEvent(id event)
{
    static NSUInteger sampleCount;
    if (!gDebugLogging || sampleCount++ >= 24 ||
        ![event respondsToSelector:@selector(_hidEvent)])
        return;
    id hidEvent = [event _hidEvent];
    if (!hidEvent) {
        printf("[VirtualMac] scroll HID event unavailable class=%s\n",
               object_getClassName(event));
        return;
    }
    CFStringRef description = CFCopyDescription((__bridge CFTypeRef)hidEvent);
    printf("[VirtualMac] scroll HID class=%s description=%s\n",
           object_getClassName(hidEvent),
           description ? [(__bridge NSString *)description UTF8String] : "(none)");
    if (description)
        CFRelease(description);
}

@interface UIPanGestureRecognizer (VZScrollEventSPI)
- (void)_scrollingChangedWithEvent:(id)event;
@end

@interface NSObject (VZHoverEventSPI)
- (NSInteger)_trackpadFingerDownCount;
@end

// UIScrollView uses _UIInterruptScrollDecelerationGestureRecognizer to watch
// UIHoverEvent's trackpad finger count at the event-environment boundary. A
// normal UIHoverGestureRecognizer receives cursor movement, but not every
// stationary light contact. Observe the same UIEvent before UIKit dispatches
// it instead: this adds no recognizer, recognition delay, or touch handling.
@interface VirtualMacApplication : UIApplication {
    BOOL _vzTrackpadInterruptionArmed;
    BOOL _vzSurfaceMouseInterruptionArmed;
}
@end

@implementation VirtualMacApplication

- (void)sendEvent:(UIEvent *)event
{
    // Do no private event inspection in the ordinary UIKit input path. While
    // one of our two synthesized momentum pipelines is active, however, a
    // light contact on either a trackpad or Magic Mouse must stop it just as
    // it stops UIScrollView deceleration. At this dispatch boundary the
    // scroll-ended event is observed before it starts momentum, so a nonzero
    // count here is a subsequent physical contact rather than the old lift.
    BOOL trackpadMomentum = VZTrackpadScrollBridgeHasMomentum();
    BOOL surfaceMouseMomentum = VZSurfaceMouseScrollBridgeHasMomentum();
    BOOL touchMomentum = VZTouchScrollBridgeHasMomentum();
    if (!trackpadMomentum)
        _vzTrackpadInterruptionArmed = NO;
    if (!surfaceMouseMomentum)
        _vzSurfaceMouseInterruptionArmed = NO;
    if ((trackpadMomentum || surfaceMouseMomentum) &&
        [event respondsToSelector:@selector(_trackpadFingerDownCount)]) {
        NSInteger contactCount = [event _trackpadFingerDownCount];
        // UIKit may deliver one final nonzero hover packet after the scroll-
        // ended packet has started our timer. Do not mistake those same
        // fingers for a new touch. A zero-contact packet arms interruption;
        // only a later physical contact can stop the active momentum.
        if (contactCount == 0) {
            _vzTrackpadInterruptionArmed |= trackpadMomentum;
            _vzSurfaceMouseInterruptionArmed |= surfaceMouseMomentum;
        } else {
            BOOL stopTrackpad = trackpadMomentum &&
                _vzTrackpadInterruptionArmed;
            BOOL stopSurfaceMouse = surfaceMouseMomentum &&
                _vzSurfaceMouseInterruptionArmed;
            if ((stopTrackpad || stopSurfaceMouse) && gDebugLogging)
                printf("[VirtualMac] new surface contact interrupted %s "
                       "momentum\n",
                       stopTrackpad && stopSurfaceMouse ? "input" :
                       stopTrackpad ? "trackpad" : "Magic Mouse");
            if (stopTrackpad)
                VZTrackpadScrollBridgeInterruptMomentum();
            if (stopSurfaceMouse)
                VZSurfaceMouseScrollBridgeInterruptMomentum();
            if (stopTrackpad || stopSurfaceMouse) {
                // Tap-to-click is synthesized at contact release and may be
                // delivered through UIKit, GameController, or both. Keep the
                // interruption contact click-free without poisoning the next
                // independently initiated click.
                gSuppressSurfaceClickUntil = CACurrentMediaTime() + 0.40;
            }
        }
    }
    if (touchMomentum && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.type == UITouchTypeDirect &&
                touch.phase == UITouchPhaseBegan) {
                if (gDebugLogging)
                    printf("[VirtualMac] new direct touch interrupted touch "
                           "momentum\n");
                VZTouchScrollBridgeInterruptMomentum();
                break;
            }
        }
    }
    [super sendEvent:event];
}

@end

// Pencil relay declarations are needed by VZInputView's hover handler. Keep
// the wire values in one enum so the handler cannot accidentally depend on a
// later file-scope definition. These values match pencil-probe's
// PencilEventType raw values.
enum {
    kPencilEventPoint = 0,
    kPencilEventProximityEnter = 1,
    kPencilEventProximityLeave = 2,
    kPencilEventHover = 3,
    kPencilEventHoverEnd = 4,
};
static BOOL pencilRelayEnabled(void);
static bool pencilVsockSend(uint8_t type, float pressure,
                            float nx, float ny,
                            float altitude, float azimuth);

@interface VZRawScrollRecognizer : UIPanGestureRecognizer {
    CGVector _vzRawDelta;
    CGVector _vzAcceleratedDelta;
    BOOL _vzDirectionInverted;
    NSUInteger _vzUIKitDeviceCategory;
    NSUInteger _vzMomentumPhase;
    NSUInteger _vzHIDPhase;
    NSTimeInterval _vzEventTimestamp;
    uint64_t _vzLastHIDTimestamp;
    BOOL _vzForwardedRawHID;
}
- (CGVector)vzRawDelta;
- (CGVector)vzAcceleratedDelta;
- (BOOL)vzDirectionInverted;
- (NSUInteger)vzUIKitDeviceCategory;
- (NSUInteger)vzMomentumPhase;
- (NSUInteger)vzHIDPhase;
- (BOOL)vzForwardedRawHID;
- (NSTimeInterval)vzEventTimestamp;
@end

@implementation VZRawScrollRecognizer

- (void)_scrollingChangedWithEvent:(id)event
{
    VZDescribeRawScrollHIDEvent(event);
    _vzRawDelta = [event nonAcceleratedDelta];
    _vzAcceleratedDelta = [event acceleratedDelta];
    _vzDirectionInverted = [event directionInvertedFromDevice];
    // UIScrollEvent identifies iPad trackpad input as category 2 on the
    // supported iPadOS 14-16 UIKit implementations. This is the distinction
    // the public gesture recognizer API omits: both a wheel and trackpad
    // otherwise arrive through the same UIPanGestureRecognizer path.
    _vzUIKitDeviceCategory =
        [event respondsToSelector:@selector(_scrollDeviceCategory)]
        ? [event _scrollDeviceCategory] : 0;
    _vzMomentumPhase = [event respondsToSelector:@selector(momentumPhase)]
        ? [event momentumPhase] : 0;
    _vzEventTimestamp = [event timestamp];
    id hidEvent = [event respondsToSelector:@selector(_hidEvent)]
        ? [event _hidEvent] : nil;
    static uint64_t (*getTimestamp)(CFTypeRef);
    static uint32_t (*getFlags)(CFTypeRef);
    static dispatch_once_t hidOnce;
    dispatch_once(&hidOnce, ^{
        getTimestamp = dlsym(RTLD_DEFAULT, "IOHIDEventGetTimeStamp");
        getFlags = dlsym(RTLD_DEFAULT, "IOHIDEventGetEventFlags");
    });
    uint64_t hidTimestamp = hidEvent && getTimestamp
        ? getTimestamp((__bridge CFTypeRef)hidEvent) : 0;
    uint32_t hidFlags = hidEvent && getFlags
        ? getFlags((__bridge CFTypeRef)hidEvent) : 0;
    NSUInteger hidPhaseBits = (hidFlags >> 24) & 0xff;
    _vzHIDPhase = ((hidPhaseBits & 0x01) ? 0x01 : 0) |
                  ((hidPhaseBits & 0x02) ? 0x04 : 0) |
                  ((hidPhaseBits & 0x04) ? 0x08 : 0) |
                  ((hidPhaseBits & 0x08) ? 0x10 : 0) |
                  ((hidPhaseBits & 0x80) ? 0x20 : 0);
    // UIKit may offer one HID packet to the recognizer twice. Forward at the
    // HID boundary exactly once; duplicate terminal events confuse AppKit's
    // scroll sequence state and are especially visible on direction changes.
    _vzForwardedRawHID = hidEvent && getFlags;
    if (_vzForwardedRawHID &&
        (hidTimestamp == 0 || hidTimestamp != _vzLastHIDTimestamp)) {
        _vzLastHIDTimestamp = hidTimestamp;
        NSUInteger category = _vzUIKitDeviceCategory;
        if (category == 1 || category == 2) {
            // Ghidra analysis of iPadOS 16.3.1 UIKitCore
            // -[UIScrollEvent _scrollDeviceCategory] shows that source 0x0c
            // digitizers are split into categories 1 and 2 by surface height.
            // The official iPad Magic Keyboard is category 1; other tested
            // trackpads are category 2. Both carry the same HID contact
            // lifecycle and belong on the Mac trackpad path. Source 0x0b
            // wheel/surface mice remain UIKit categories 3-5 below.
            // The HID root contains physical trackpad mickeys and reliable
            // contact phases. Its accelerated child is tuned for iPadOS, not
            // AppKit/VZ, so run only the root through Ventura's Mac curve.
            // Ignore iPadOS momentum packets: the Mac bridge produces the
            // corresponding 60 Hz stream and a MayBegin packet cancels it.
            gTrackpadDirectionInverted = _vzDirectionInverted;
            if (_vzMomentumPhase == 0) {
                VZTrackpadScrollBridgeHandle(_vzRawDelta, _vzHIDPhase,
                                             _vzEventTimestamp);
            }
        } else if (category == 3) {
            // Magic Mouse surface reports have contact phases but no native
            // macOS momentum on supported iPadOS. Reconstruct that stage in
            // an independent pipeline; a conventional wheel remains below.
            gSurfaceMouseDirectionInverted = _vzDirectionInverted;
            if (_vzMomentumPhase == 0)
                VZSurfaceMouseScrollBridgeHandle(
                    _vzRawDelta, _vzHIDPhase, _vzEventTimestamp);
            else
                sendScrollWheelEvent(
                    _vzRawDelta, _vzAcceleratedDelta,
                    _vzDirectionInverted, 1, 0,
                    hidMomentumPhaseFromUIKitPhase(_vzMomentumPhase));
        } else {
            // A wheel has no contact phase. Preserve the proven display-rate
            // coalescing for high-report-rate mice; Magic Mouse momentum is
            // already generated by the host HID stack and remains immediate.
            queueScrollWheel(_vzRawDelta, _vzAcceleratedDelta,
                             _vzDirectionInverted, 0, 0);
        }
    }
    static NSUInteger sourceSamples;
    if (gDebugLogging && sourceSamples++ < 8)
        printf("[VirtualMac] UIKit scroll source class=%s category=%lu "
               "event-phase=%lu\n",
               object_getClassName(event),
               (unsigned long)_vzUIKitDeviceCategory,
               (unsigned long)[event phase]);
    [super _scrollingChangedWithEvent:event];
}

- (CGVector)vzRawDelta { return _vzRawDelta; }
- (CGVector)vzAcceleratedDelta { return _vzAcceleratedDelta; }
- (BOOL)vzDirectionInverted { return _vzDirectionInverted; }
- (NSUInteger)vzUIKitDeviceCategory { return _vzUIKitDeviceCategory; }
- (NSUInteger)vzMomentumPhase { return _vzMomentumPhase; }
- (NSUInteger)vzHIDPhase { return _vzHIDPhase; }
- (BOOL)vzForwardedRawHID { return _vzForwardedRawHID; }
- (NSTimeInterval)vzEventTimestamp { return _vzEventTimestamp; }

@end

static void sendSoftwareKey(UIKeyboardHIDUsage usage, BOOL shifted);

@interface VZInputView : UIView <UIPointerInteractionDelegate, UIKeyInput> {
    UIInputView *_vzAccessoryView;
    UIStackView *_vzAccessoryStack;
    NSMutableSet<NSNumber *> *_vzHeldSoftwareModifiers;
    CGPoint _vzDirectTouchStart;
    CGPoint _vzLastDirectTap;
    NSTimeInterval _vzLastDirectTapTime;
    BOOL _vzDirectTouchActive;
    BOOL _vzDirectTouchDragging;
    NSMutableDictionary<NSValue *, NSValue *> *_vzDirectTouchOrigins;
    NSMutableDictionary<NSValue *, NSValue *> *_vzDirectTouchPositions;
    NSMutableSet<NSValue *> *_vzActiveDirectTouchKeys;
    NSTimeInterval _vzDirectGestureStartTime;
    CGFloat _vzDirectGestureMaximumMovement;
    NSUInteger _vzDirectGestureGeneration;
    BOOL _vzTwoFingerCandidate;
    BOOL _vzLongPressConsumed;
    BOOL _vzDirectPrimaryPressed;
    BOOL _vzPencilRelayStrokeClaimed;
    BOOL _vzPencilRelayStrokeConnected;
    BOOL _vzPencilHoverActive;
    BOOL _vzSuppressIndirectPointerClick;
}
@end

@implementation VZInputView

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

- (BOOL)hasText { return YES; }

- (UIView *)inputAccessoryView
{
    if (GCKeyboard.coalescedKeyboard)
        return nil;
    if (_vzAccessoryView)
        return _vzAccessoryView;
    _vzHeldSoftwareModifiers = [[NSMutableSet alloc] init];
    _vzAccessoryView = [[UIInputView alloc]
        initWithFrame:CGRectMake(0, 0, 0, 52)
        inputViewStyle:UIInputViewStyleKeyboard];
    UIScrollView *scroll = [[[UIScrollView alloc] init] autorelease];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.showsHorizontalScrollIndicator = YES;
    scroll.directionalLockEnabled = YES;
    UIStackView *stack = [[[UIStackView alloc] init] autorelease];
    _vzAccessoryStack = [stack retain];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 6;
    NSArray *keys = @[
        @[@"esc", @0x29, @NO],
        @[@"tab", @0x2b, @NO],
        @[@"⇧", @0xe1, @YES], @[@"⌃", @0xe0, @YES],
        @[@"⌥", @0xe2, @YES], @[@"⌘", @0xe3, @YES],
        @[@"←", @0x50, @NO], @[@"↓", @0x51, @NO],
        @[@"↑", @0x52, @NO], @[@"→", @0x4f, @NO],
        @[@"home", @0x4a, @NO], @[@"end", @0x4d, @NO],
        @[@"pg up", @0x4b, @NO], @[@"pg dn", @0x4e, @NO],
        @[@"F1", @0x3a, @NO], @[@"F2", @0x3b, @NO],
        @[@"F3", @0x3c, @NO], @[@"F4", @0x3d, @NO],
        @[@"F5", @0x3e, @NO], @[@"F6", @0x3f, @NO],
        @[@"F7", @0x40, @NO], @[@"F8", @0x41, @NO],
        @[@"F9", @0x42, @NO], @[@"F10", @0x43, @NO],
        @[@"F11", @0x44, @NO], @[@"F12", @0x45, @NO],
    ];
    for (NSArray *key in keys) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setTitle:key[0] forState:UIControlStateNormal];
        [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:17
            weight:UIFontWeightSemibold];
        button.tag = [key[1] integerValue];
        button.accessibilityHint = [key[2] boolValue]
            ? VZL(@"Double-tap to hold or release this modifier") : nil;
        [button addTarget:self action:@selector(accessoryKeyPressed:)
            forControlEvents:UIControlEventTouchUpInside];
        button.layer.cornerRadius = 7;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.layer.borderWidth = 0.5;
        button.layer.borderColor = UIColor.separatorColor.CGColor;
        button.backgroundColor = UIColor.secondarySystemBackgroundColor;
        CGFloat width = [key[0] length] > 3 ? 62 : 48;
        [button.widthAnchor constraintEqualToConstant:width].active = YES;
        [stack addArrangedSubview:button];
    }
    [scroll addSubview:stack];
    [_vzAccessoryView addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:_vzAccessoryView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_vzAccessoryView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_vzAccessoryView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_vzAccessoryView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.topAnchor constant:5],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.bottomAnchor constant:-5],
    ]];
    return _vzAccessoryView;
}

- (void)accessoryKeyPressed:(UIButton *)sender
{
    UIKeyboardHIDUsage usage = (UIKeyboardHIDUsage)sender.tag;
    BOOL modifier = usage >= 0xe0 && usage <= 0xe7;
    if (modifier) {
        NSNumber *key = @(usage);
        BOOL hold = ![_vzHeldSoftwareModifiers containsObject:key];
        if (hold) [_vzHeldSoftwareModifiers addObject:key];
        else [_vzHeldSoftwareModifiers removeObject:key];
        sender.backgroundColor = hold ? UIColor.systemGray3Color
                                      : UIColor.secondarySystemBackgroundColor;
        [sender setTitleColor:UIColor.labelColor
                     forState:UIControlStateNormal];
        sender.accessibilityTraits = hold
            ? (sender.accessibilityTraits | UIAccessibilityTraitSelected)
            : (sender.accessibilityTraits & ~UIAccessibilityTraitSelected);
        sendKey(usage, hold);
    } else {
        sendSoftwareKey(usage, NO);
    }
}

- (void)releaseSoftwareModifiers
{
    for (NSNumber *usage in _vzHeldSoftwareModifiers)
        sendKey((UIKeyboardHIDUsage)usage.unsignedIntegerValue, NO);
    [_vzHeldSoftwareModifiers removeAllObjects];
    for (UIView *view in _vzAccessoryStack.arrangedSubviews) {
        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (id)view;
            button.backgroundColor = UIColor.secondarySystemBackgroundColor;
            [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
            button.accessibilityTraits &= ~UIAccessibilityTraitSelected;
        }
    }
}

- (BOOL)resignFirstResponder
{
    [self releaseSoftwareModifiers];
    return [super resignFirstResponder];
}

static void sendSoftwareKey(UIKeyboardHIDUsage usage, BOOL shifted)
{
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, YES);
    sendKey(usage, YES);
    sendKey(usage, NO);
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, NO);
}

static void sendSoftwareChord(UIKeyboardHIDUsage usage, BOOL shifted,
                              BOOL option)
{
    if (option) sendKey((UIKeyboardHIDUsage)0xE2, YES);
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, YES);
    sendKey(usage, YES);
    sendKey(usage, NO);
    if (shifted) sendKey((UIKeyboardHIDUsage)0xE1, NO);
    if (option) sendKey((UIKeyboardHIDUsage)0xE2, NO);
}

- (void)insertText:(NSString *)text
{
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character >= 'a' && character <= 'z')
            sendSoftwareKey((UIKeyboardHIDUsage)(0x04 + character - 'a'), NO);
        else if (character >= 'A' && character <= 'Z')
            sendSoftwareKey((UIKeyboardHIDUsage)(0x04 + character - 'A'), YES);
        else if (character >= '1' && character <= '9')
            sendSoftwareKey((UIKeyboardHIDUsage)(0x1e + character - '1'), NO);
        else if (character == '0') sendSoftwareKey((UIKeyboardHIDUsage)0x27, NO);
        else if (character == ' ') sendSoftwareKey((UIKeyboardHIDUsage)0x2c, NO);
        else if (character == '\t') sendSoftwareKey((UIKeyboardHIDUsage)0x2b, NO);
        else if (character == '\n' || character == '\r') sendSoftwareKey((UIKeyboardHIDUsage)0x28, NO);
        else {
            NSString *shiftedNumbers = @"!@#$%^&*()";
            NSString *oneCharacter = [NSString stringWithCharacters:&character length:1];
            NSUInteger numberPosition = [shiftedNumbers rangeOfString:oneCharacter].location;
            if (numberPosition != NSNotFound) {
                UIKeyboardHIDUsage usage = numberPosition == 9
                    ? (UIKeyboardHIDUsage)0x27
                    : (UIKeyboardHIDUsage)(0x1e + numberPosition);
                sendSoftwareKey(usage, YES);
                continue;
            }
            switch (character) {
            case 0x00a3: // £: Option-3 on the macOS U.S. layout.
                sendSoftwareChord((UIKeyboardHIDUsage)0x20, NO, YES); continue;
            case 0x20ac: // €: Option-Shift-2.
                sendSoftwareChord((UIKeyboardHIDUsage)0x1f, YES, YES); continue;
            case 0x00a5: case 0xffe5: // ¥ / full-width yen: Option-Y.
                sendSoftwareChord((UIKeyboardHIDUsage)0x1c, NO, YES); continue;
            case 0x2026: // …: Option-semicolon.
                sendSoftwareChord((UIKeyboardHIDUsage)0x33, NO, YES); continue;
            case 0x2018: // ‘: Option-right bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x30, NO, YES); continue;
            case 0x2019: // ’: Option-Shift-right bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x30, YES, YES); continue;
            case 0x201c: // “: Option-left bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x2f, NO, YES); continue;
            case 0x201d: // ”: Option-Shift-left bracket.
                sendSoftwareChord((UIKeyboardHIDUsage)0x2f, YES, YES); continue;
            default: break;
            }
            NSString *plain = @"-=[]\\;',./`";
            NSString *shift = @"_+{}|:\"<>?~";
            NSUInteger position = [plain rangeOfString:oneCharacter].location;
            BOOL shifted = NO;
            if (position == NSNotFound) {
                position = [shift rangeOfString:oneCharacter].location;
                shifted = position != NSNotFound;
            }
            static const UIKeyboardHIDUsage usages[] = {0x2d,0x2e,0x2f,0x30,0x31,0x33,0x34,0x36,0x37,0x38,0x35};
            if (position != NSNotFound)
                sendSoftwareKey(usages[position], shifted);
        }
    }
}

- (void)deleteBackward { sendSoftwareKey((UIKeyboardHIDUsage)0x2a, NO); }

- (void)dealloc
{
    [self releaseSoftwareModifiers];
    [_vzAccessoryView release];
    [_vzAccessoryStack release];
    [_vzHeldSoftwareModifiers release];
    [_vzDirectTouchOrigins release];
    [_vzDirectTouchPositions release];
    [_vzActiveDirectTouchKeys release];
    [super dealloc];
}

- (void)handleHover:(UIHoverGestureRecognizer *)recognizer
{
    CGPoint location = [recognizer locationInView:self];
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
    case UIGestureRecognizerStateChanged:
        notePointerInputSource(NO);
        gUIKitHoverActive = YES;
        sendIndirectPointerLocation(location, self.bounds);
        // Apple Pencil hover: zOffset is available from iPadOS 16.1 and is
        // zero for devices without hover support, including trackpads. The
        // supported M2 iPad can therefore relay position on 16.1-16.3.1.
        // UIKit added hover tilt only in 16.4, so older hosts send neutral
        // tilt while preserving the useful position/proximity lifecycle.
        if (@available(iOS 16.1, *)) {
            if (pencilRelayEnabled() && recognizer.zOffset > 0) {
                _vzPencilHoverActive = YES;
                CGRect b = self.bounds;
                float nx = (b.size.width > 0)
                    ? (float)(location.x / b.size.width) : 0;
                float ny = (b.size.height > 0)
                    ? (float)(location.y / b.size.height) : 0;
                float altitude = (float)M_PI_2;
                float azimuth = 0;
                if (@available(iOS 16.4, *)) {
                    altitude = (float)recognizer.altitudeAngle;
                    azimuth =
                        (float)[recognizer azimuthAngleInView:self];
                }
                pencilVsockSend(kPencilEventHover, 0, nx, ny,
                                altitude, azimuth);
            }
        }
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        // A UIKit hover session can end while an indirect-pointer touch still
        // owns the physical button. Releasing buttons here truncated every
        // trackpad click-drag. Lifecycle and touch cancellation paths own
        // stuck-button cleanup instead.
        gUIKitHoverActive = NO;
        gHostPointerLocationValid = NO;
        // Notify the guest that the Pencil left hover range.
        // If the pen touched the screen (hover → touch transition),
        // pencil-probe's state machine handles the brief leave/enter.
        if (_vzPencilHoverActive) {
            _vzPencilHoverActive = NO;
            CGRect b = self.bounds;
            float nx = (b.size.width > 0)
                ? (float)(location.x / b.size.width) : 0;
            float ny = (b.size.height > 0)
                ? (float)(location.y / b.size.height) : 0;
            pencilVsockSend(kPencilEventHoverEnd, 0, nx, ny,
                            (float)M_PI_2, 0);
        }
        break;
    default:
        break;
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)recognizer
{
    NSUInteger phase = 0;
    double delta = 0;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        gLastPinchScale = recognizer.scale;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        // Indirect trackpad pinch scale is cumulative and, unlike direct
        // touch pinch, does not honor assigning scale=1 as a delta reset.
        // VZ/NSEvent magnification is incremental, so derive the frame delta.
        delta = recognizer.scale - gLastPinchScale;
        gLastPinchScale = recognizer.scale;
        break;
    case UIGestureRecognizerStateEnded: phase = 8; break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: phase = 16; break;
    default: return;
    }
    sendMagnification(delta, phase);
}

- (void)handleRotation:(UIRotationGestureRecognizer *)recognizer
{
    NSUInteger phase = 0;
    double delta = 0;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        gLastRotation = recognizer.rotation;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        delta = recognizer.rotation - gLastRotation;
        gLastRotation = recognizer.rotation;
        break;
    case UIGestureRecognizerStateEnded: phase = 8; break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: phase = 16; break;
    default: return;
    }
    sendRotation(delta, phase);
}

- (void)handleSmartMagnify:(UITapGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateRecognized)
        sendSmartMagnification();
}

- (void)handleScroll:(VZRawScrollRecognizer *)recognizer
{
    // Hardware scroll packets are forwarded directly from
    // -_scrollingChangedWithEvent: before UIPanGestureRecognizer alters their
    // phase or coalescing. This target remains installed solely so UIKit keeps
    // the private scrolling recognizer active.
    if (recognizer.vzForwardedRawHID)
        return;
    // NSEventPhase and the private VZ event use the same bit values:
    // began=1, changed=4, ended=8, cancelled=16. The recognizer captures the
    // incremental hardware deltas before UIKit builds cumulative translation.
    NSUInteger phase = 0;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        break;
    case UIGestureRecognizerStateEnded:
        phase = 8;
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        phase = 16;
        break;
    default:
        return;
    }
    // The real Ventura VMM receives phase-less events from a mouse and
    // began/changed/ended events from a trackpad. UIKit category 2 is the
    // trackpad source on iPadOS 14-16; all other indirect sources keep mouse
    // wheel semantics. Direct touch uses the separate category 1 path.
    NSUInteger deviceCategory = recognizer.vzUIKitDeviceCategory;
    if (deviceCategory == 1 || deviceCategory == 2) {
        // UIKit exposes the iPad trackpad's nonaccelerated stream but omits
        // the Mac driver's acceleration and momentum stages. The bridge ports
        // Ventura's MultitouchHID/IOHID behavior, normalizes UIKit's fractional
        // post-pause jitter, and discards UIKit's repeated terminal sample.
        if (gDebugLogging)
            gScrollReceivedEventCount++;
        gTrackpadDirectionInverted = recognizer.vzDirectionInverted;
        VZTrackpadScrollBridgeHandle(recognizer.vzRawDelta, phase,
                                     recognizer.vzEventTimestamp);
    } else if (deviceCategory == 3) {
        gSurfaceMouseDirectionInverted = recognizer.vzDirectionInverted;
        if (recognizer.vzMomentumPhase == 0)
            VZSurfaceMouseScrollBridgeHandle(
                recognizer.vzRawDelta, phase,
                recognizer.vzEventTimestamp);
        else
            sendScrollWheelEvent(
                recognizer.vzRawDelta, recognizer.vzAcceleratedDelta,
                recognizer.vzDirectionInverted, 1, 0,
                hidMomentumPhaseFromUIKitPhase(
                    recognizer.vzMomentumPhase));
    } else {
        queueScrollWheel(recognizer.vzRawDelta,
                         recognizer.vzAcceleratedDelta,
                         recognizer.vzDirectionInverted,
                         deviceCategory,
                         phase);
    }
}

- (void)handleTouchScroll:(UIPanGestureRecognizer *)recognizer
{
    NSUInteger phase = 0;
    CGPoint delta = CGPointZero;
    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        phase = 1;
        break;
    case UIGestureRecognizerStateChanged:
        phase = 4;
        delta = [recognizer translationInView:self];
        [recognizer setTranslation:CGPointZero inView:self];
        break;
    case UIGestureRecognizerStateEnded:
        phase = 8;
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        phase = 16;
        break;
    default:
        return;
    }
    notePointerInputSource(YES);
    // A direct two-finger pan follows the content under the fingers (natural
    // scrolling), while captured hardware-wheel deltas describe wheel
    // rotation. Rotate and invert the UIKit translation before entering the
    // shared VZ event mapping. This intentionally affects direct touch only.
    CGVector translation = CGVectorMake(-delta.y, delta.x);
    VZTouchScrollBridgeHandle(translation, phase, CACurrentMediaTime(),
                              gScrollingSpeed);
}

- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction
                       regionForRequest:(UIPointerRegionRequest *)request
                          defaultRegion:(UIPointerRegion *)defaultRegion
{
    (void)interaction;
    (void)request;
    (void)defaultRegion;
    // Do not mutate guest input from this delegate. UIKit calls it during
    // region invalidation and system-UI transitions, not only real motion.
    return [UIPointerRegion regionWithRect:self.bounds identifier:@"VirtualMacDisplay"];
}

- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction
                        styleForRegion:(UIPointerRegion *)region
{
    (void)interaction;
    (void)region;
    return [UIPointerStyle hiddenPointerStyle];
}

- (BOOL)usesDeferredDirectTouchClicks
{
    VZAppSettings *settings = VZAppSettings.sharedSettings;
    return [settings boolForKey:VZTouchTwoFingerRightClickKey] ||
        [settings boolForKey:VZTouchLongPressRightClickKey];
}

- (NSValue *)directTouchKey:(UITouch *)touch
{
    return [NSValue valueWithNonretainedObject:touch];
}

- (void)ensureDirectTouchTracking
{
    if (!_vzDirectTouchOrigins)
        _vzDirectTouchOrigins = [[NSMutableDictionary alloc] init];
    if (!_vzDirectTouchPositions)
        _vzDirectTouchPositions = [[NSMutableDictionary alloc] init];
    if (!_vzActiveDirectTouchKeys)
        _vzActiveDirectTouchKeys = [[NSMutableSet alloc] init];
}

- (CGPoint)directTouchMidpoint
{
    if (!_vzDirectTouchPositions.count)
        return _vzDirectTouchStart;
    CGFloat x = 0;
    CGFloat y = 0;
    for (NSValue *value in _vzDirectTouchPositions.allValues) {
        CGPoint point = value.CGPointValue;
        x += point.x;
        y += point.y;
    }
    return CGPointMake(x / _vzDirectTouchPositions.count,
                       y / _vzDirectTouchPositions.count);
}

- (void)emitDirectClickAtPoint:(CGPoint)point button:(NSUInteger)button
{
    // Move first, matching the native indirect-pointer path. The down/up pair
    // is emitted together only after the direct-touch gesture is known, so a
    // two-finger tap never leaks a primary click into the guest.
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());
    gTouchButtons = button;
    sendPointer(point, self.bounds, activePointerButtons());
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());
}

- (void)resetDeferredDirectTouch
{
    _vzDirectGestureGeneration++;
    _vzDirectTouchActive = NO;
    _vzDirectTouchDragging = NO;
    _vzTwoFingerCandidate = NO;
    _vzLongPressConsumed = NO;
    _vzDirectPrimaryPressed = NO;
    _vzDirectGestureMaximumMovement = 0;
    [_vzDirectTouchOrigins removeAllObjects];
    [_vzDirectTouchPositions removeAllObjects];
    [_vzActiveDirectTouchKeys removeAllObjects];
}

- (void)beginDeferredDirectTouches:(NSSet<UITouch *> *)touches
                         withEvent:(UIEvent *)event
{
    (void)event;
    [self ensureDirectTouchTracking];
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect)
            continue;
        NSValue *key = [self directTouchKey:touch];
        CGPoint point = [touch locationInView:self];
        if (!_vzDirectTouchOrigins[key])
            _vzDirectTouchOrigins[key] = [NSValue valueWithCGPoint:point];
        _vzDirectTouchPositions[key] = [NSValue valueWithCGPoint:point];
        [_vzActiveDirectTouchKeys addObject:key];
        if (!_vzDirectTouchActive) {
            _vzDirectTouchActive = YES;
            _vzDirectTouchDragging = NO;
            _vzTwoFingerCandidate = NO;
            _vzLongPressConsumed = NO;
            // Preserve the original fast-path double-tap semantics: decide
            // the accommodated guest coordinate at touch-down, before the
            // guest observes any pointer movement.  Applying it at touch-up
            // made the pointer visit the second physical coordinate between
            // clicks, which defeats AppKit's double-click hit testing.
            BOOL accommodate = [VZAppSettings.sharedSettings
                boolForKey:VZTouchDoubleTapAccommodationKey];
            if (accommodate &&
                touch.timestamp - _vzLastDirectTapTime <= 0.20) {
                CGFloat dx = point.x - _vzLastDirectTap.x;
                CGFloat dy = point.y - _vzLastDirectTap.y;
                if (hypot(dx, dy) <= 30.0)
                    point = _vzLastDirectTap;
            }
            _vzDirectTouchStart = point;
            _vzDirectGestureStartTime = touch.timestamp;
            _vzDirectGestureMaximumMovement = 0;
            _vzDirectGestureGeneration++;
        }
    }

    NSUInteger count = _vzActiveDirectTouchKeys.count;
    if (count == 2) {
        if (_vzDirectPrimaryPressed) {
            gTouchButtons = 0;
            sendPointer(_vzDirectTouchStart, self.bounds,
                        activePointerButtons());
            _vzDirectPrimaryPressed = NO;
        }
        _vzTwoFingerCandidate = YES;
        // Invalidate a pending one-finger long press as soon as the second
        // finger arrives. Two-finger scrolling remains owned by its pan
        // recognizer and cancels this candidate after actual movement.
        _vzDirectGestureGeneration++;
    } else if (count > 2) {
        _vzTwoFingerCandidate = NO;
        _vzDirectGestureGeneration++;
    }

    CGPoint point = count > 1 ? [self directTouchMidpoint]
                              : _vzDirectTouchStart;
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());

    if (count == 1 && [VZAppSettings.sharedSettings
            boolForKey:VZTouchLongPressRightClickKey]) {
        NSUInteger generation = _vzDirectGestureGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!_vzDirectTouchActive || _vzDirectTouchDragging ||
                _vzTwoFingerCandidate || _vzLongPressConsumed ||
                _vzActiveDirectTouchKeys.count != 1 ||
                generation != _vzDirectGestureGeneration)
                return;
            _vzLongPressConsumed = YES;
            [self emitDirectClickAtPoint:[self directTouchMidpoint] button:2];
        });
    } else if (count == 1) {
        // Waiting until touch-up made every tap feel laggy and changed drag
        // timing.  Keep only a very short arbitration window for a second
        // finger, then restore the normal touch-down press while the finger
        // is still held.
        NSUInteger generation = _vzDirectGestureGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!_vzDirectTouchActive || _vzDirectTouchDragging ||
                _vzTwoFingerCandidate || _vzLongPressConsumed ||
                _vzActiveDirectTouchKeys.count != 1 ||
                generation != _vzDirectGestureGeneration)
                return;
            _vzDirectPrimaryPressed = YES;
            gTouchButtons = 1;
            sendPointer(_vzDirectTouchStart, self.bounds,
                        activePointerButtons());
        });
    }
}

- (void)moveDeferredDirectTouches:(NSSet<UITouch *> *)touches
                         withEvent:(UIEvent *)event
{
    (void)event;
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect)
            continue;
        NSValue *key = [self directTouchKey:touch];
        CGPoint point = [touch locationInView:self];
        _vzDirectTouchPositions[key] = [NSValue valueWithCGPoint:point];
        CGPoint origin = [_vzDirectTouchOrigins[key] CGPointValue];
        _vzDirectGestureMaximumMovement = MAX(
            _vzDirectGestureMaximumMovement,
            hypot(point.x - origin.x, point.y - origin.y));
    }

    if (_vzActiveDirectTouchKeys.count != 1) {
        if (_vzActiveDirectTouchKeys.count > 2)
            _vzTwoFingerCandidate = NO;
        return;
    }
    if (_vzLongPressConsumed)
        return;

    CGPoint point = [self directTouchMidpoint];
    if (!_vzDirectTouchDragging) {
        CGFloat dx = point.x - _vzDirectTouchStart.x;
        CGFloat dy = point.y - _vzDirectTouchStart.y;
        if (hypot(dx, dy) <= 8.0)
            return;
        _vzDirectTouchDragging = YES;
        _vzTwoFingerCandidate = NO;
        _vzDirectGestureGeneration++;
        if (!_vzDirectPrimaryPressed) {
            _vzDirectPrimaryPressed = YES;
            gTouchButtons = 1;
            sendPointer(_vzDirectTouchStart, self.bounds,
                        activePointerButtons());
        }
    }
    gTouchButtons = 1;
    sendPointer(point, self.bounds, activePointerButtons());
}

- (void)endDeferredDirectTouches:(NSSet<UITouch *> *)touches
                        withEvent:(UIEvent *)event
{
    CGPoint finalPoint = [self directTouchMidpoint];
    NSTimeInterval endTime = _vzDirectGestureStartTime;
    for (UITouch *touch in touches) {
        if (touch.type != UITouchTypeDirect)
            continue;
        NSValue *key = [self directTouchKey:touch];
        CGPoint point = [touch locationInView:self];
        _vzDirectTouchPositions[key] = [NSValue valueWithCGPoint:point];
        CGPoint origin = [_vzDirectTouchOrigins[key] CGPointValue];
        _vzDirectGestureMaximumMovement = MAX(
            _vzDirectGestureMaximumMovement,
            hypot(point.x - origin.x, point.y - origin.y));
        [_vzActiveDirectTouchKeys removeObject:key];
        endTime = MAX(endTime, touch.timestamp);
    }
    finalPoint = [self directTouchMidpoint];
    if (_vzActiveDirectTouchKeys.count)
        return;

    NSTimeInterval duration = endTime - _vzDirectGestureStartTime;
    if (_vzLongPressConsumed) {
        // The long-press click has already completed.
    } else if (_vzTwoFingerCandidate &&
               _vzDirectTouchOrigins.count == 2 &&
               duration <= 0.35 &&
               _vzDirectGestureMaximumMovement <= 10.0) {
        [self emitDirectClickAtPoint:finalPoint button:2];
    } else if (_vzDirectTouchOrigins.count == 1 &&
               !_vzDirectTouchDragging) {
        // A tap lands where it began, not wherever the finger happened to
        // drift before lifting. This matches the pre-381c140 path and keeps
        // small targets accurate.
        finalPoint = _vzDirectTouchStart;
        if (_vzDirectPrimaryPressed) {
            gTouchButtons = 0;
            sendPointer(finalPoint, self.bounds, activePointerButtons());
        } else {
            [self emitDirectClickAtPoint:finalPoint button:1];
        }
        _vzLastDirectTap = _vzDirectTouchStart;
        _vzLastDirectTapTime = endTime;
    } else if (_vzDirectTouchDragging) {
        gTouchButtons = 0;
        sendPointer(finalPoint, self.bounds, activePointerButtons());
        _vzLastDirectTapTime = 0;
    }
    (void)event;
    [self resetDeferredDirectTouch];
}

- (void)cancelDeferredDirectTouches:(NSSet<UITouch *> *)touches
                           withEvent:(UIEvent *)event
{
    (void)event;
    CGPoint point = [self directTouchMidpoint];
    for (UITouch *touch in touches)
        if (touch.type == UITouchTypeDirect)
            point = [touch locationInView:self];
    gTouchButtons = 0;
    sendPointer(point, self.bounds, activePointerButtons());
    [self resetDeferredDirectTouch];
}

// --- Pencil vsock relay configuration ---
//
// The guest (macOS VM) runs pencil-probe, which listens on a vsock
// port. The host (iPad) connects via VZVirtioSocketDevice. No IP
// address or network configuration is needed — vsock is VM-internal.

static const uint32_t kPencilVsockPort = 9949;
enum { kPencilPacketSize = 21 };

// Wire protocol byte offsets. Must match PencilPacket offsets in pencil-probe.
enum {
    kPencilOffsetPressure = 1,
    kPencilOffsetX = 5,
    kPencilOffsetY = 9,
    kPencilOffsetAltitude = 13,
    kPencilOffsetAzimuth = 17,
};

// VZVirtioSocketDevice from the running VM.
// Set after VM start via pencilVsockSetup().
static id gPencilVsockDevice = nil;

// Retained VZVirtioSocketConnection. Must stay alive while we use
// its file descriptor; releasing it invalidates the fd.
static id gPencilVsockConnection = nil;

// --- Pencil vsock relay ---
//
// Virtualization.framework only exposes mouse events to the guest —
// there is no API for tablet pressure or tilt. This relay works around
// that limitation by sending Apple Pencil data over vsock to a small
// receiver (pencil-probe) running inside the guest VM. The receiver
// injects synthetic macOS tablet events via CGEventPost, which drawing
// apps (e.g. Clip Studio Paint) recognize as pen pressure.
//
// Wire format (little-endian, 21 bytes per event):
//   [0]      uint8   type (0=point, 1=proximity_enter, 2=proximity_leave)
//   [1..4]   float32 pressure (0.0–1.0, normalized)
//   [5..8]   float32 x (0.0–1.0, screen-relative)
//   [9..12]  float32 y (0.0–1.0, screen-relative)
//   [13..16] float32 altitude (0=parallel, π/2=perpendicular)
//   [17..20] float32 azimuth  (0–2π, tilt direction)
//
// Coordinates are normalized so the protocol works regardless of
// screen resolution differences between host and guest.
// Altitude/azimuth are raw UITouch angles; the guest converts
// them to CGEvent tiltX/tiltY.

static int gPencilVsockFd = -1;
static BOOL gPencilRelayEnabled;
static uint64_t gPencilConnectionGeneration;

// After a failed connect, suppress retries for this many seconds.
// Without this, every Pencil touch would trigger an async connect
// attempt.
static CFAbsoluteTime gPencilRetryAfter = 0;
static const CFTimeInterval kPencilRetryInterval = 5.0;

// Prevent concurrent connection attempts. The connect is async
// (VZVirtioSocketDevice.connectToPort:completionHandler:), so
// multiple touch events could trigger concurrent calls.
static volatile int gPencilVsockConnecting = 0;
static void pencilVsockConnect(void);

static BOOL pencilRelayEnabled(void) {
    return __atomic_load_n(&gPencilRelayEnabled, __ATOMIC_ACQUIRE);
}

static void pencilVsockReset(void) {
    __atomic_store_n(&gPencilRelayEnabled, NO, __ATOMIC_RELEASE);
    __atomic_add_fetch(&gPencilConnectionGeneration, 1, __ATOMIC_ACQ_REL);
    gPencilVsockFd = -1;
    gPencilVsockConnecting = 0;
    gPencilRetryAfter = 0;
    [gPencilVsockConnection release];
    gPencilVsockConnection = nil;
    [gPencilVsockDevice release];
    gPencilVsockDevice = nil;
}

/// Grab the VZVirtioSocketDevice from the running VM.
/// Call once after the VM starts successfully.
static void pencilVsockSetup(void) {
    if (!pencilRelayEnabled())
        return;
    NSArray *devices = m0(gVirtualMachine, "socketDevices");
    if (devices.count > 0) {
        [gPencilVsockDevice release];
        gPencilVsockDevice = [devices[0] retain];
        printf("[VirtualMac] Pencil vsock device ready\n");
        pencilVsockConnect();
    } else {
        printf("[VirtualMac] Pencil relay enabled but no vsock device found\n");
    }
}

static void pencilVsockConnect(void) {
    if (gPencilVsockFd >= 0) return;
    if (gPencilVsockConnecting) return;
    if (!gPencilVsockDevice) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < gPencilRetryAfter) return;

    gPencilVsockConnecting = 1;
    uint64_t generation = __atomic_load_n(
        &gPencilConnectionGeneration, __ATOMIC_ACQUIRE);

    void (^handler)(id, NSError *) = ^(id connection, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!pencilRelayEnabled() || generation != __atomic_load_n(
                    &gPencilConnectionGeneration, __ATOMIC_ACQUIRE))
                return;
            if (error || !connection) {
                printf("[VirtualMac] Pencil vsock connect port %u failed: %s\n",
                       kPencilVsockPort,
                       error ? error.localizedDescription.UTF8String
                             : "nil connection");
                gPencilRetryAfter = CFAbsoluteTimeGetCurrent()
                                  + kPencilRetryInterval;
                gPencilVsockConnecting = 0;
                return;
            }
            int fd = (int)((NSInteger(*)(id, SEL))objc_msgSend)(
                connection, S("fileDescriptor"));

            // Never let a stalled guest receiver block UIKit's Pencil event
            // path. The relay traffic is only 21 bytes per sample.
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags >= 0)
                fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            int nsp = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nsp, sizeof(nsp));

            [gPencilVsockConnection release];
            gPencilVsockConnection = [connection retain];
            gPencilVsockFd = fd;
            gPencilVsockConnecting = 0;
            printf("[VirtualMac] Pencil vsock connected port %u fd=%d\n",
                   kPencilVsockPort, fd);
        });
    };

    ((void(*)(id, SEL, uint32_t, id))objc_msgSend)(
        gPencilVsockDevice,
        S("connectToPort:completionHandler:"),
        kPencilVsockPort, handler);
}

static void pencilWriteLE32(uint8_t *buf, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    buf[0] = (uint8_t)(bits);
    buf[1] = (uint8_t)(bits >> 8);
    buf[2] = (uint8_t)(bits >> 16);
    buf[3] = (uint8_t)(bits >> 24);
}

/// Send a single Pencil event to the guest relay.
/// Returns true if the event was successfully sent, false if the relay
/// is not connected. Callers use this to decide whether to fall through
/// to normal mouse handling — when the relay is down, the Pencil should
/// still work as a regular pointing device.
static bool pencilVsockSend(uint8_t type, float pressure,
                             float nx, float ny,
                             float altitude, float azimuth) {
    if (!pencilRelayEnabled()) return false;
    if (gPencilVsockFd < 0) pencilVsockConnect();
    // Connect is async, so the fd may not be ready yet on the first
    // touch. Fall through to mouse mode until the connection completes.
    if (gPencilVsockFd < 0) return false;

    uint8_t buf[kPencilPacketSize];
    buf[0] = type;
    pencilWriteLE32(buf + kPencilOffsetPressure, pressure);
    pencilWriteLE32(buf + kPencilOffsetX, nx);
    pencilWriteLE32(buf + kPencilOffsetY, ny);
    pencilWriteLE32(buf + kPencilOffsetAltitude, altitude);
    pencilWriteLE32(buf + kPencilOffsetAzimuth, azimuth);

    ssize_t n = send(gPencilVsockFd, buf, kPencilPacketSize, MSG_DONTWAIT);
    if (n != kPencilPacketSize) {
        printf("[VirtualMac] Pencil vsock short write=%ld error=%d; reconnecting\n",
               (long)n, n < 0 ? errno : 0);
        gPencilVsockFd = -1;
        [gPencilVsockConnection release];
        gPencilVsockConnection = nil;
        return false;
    }
    return true;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch)
        notePointerInputSource(touch.type == UITouchTypeDirect);
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self beginDeferredDirectTouches:touches withEvent:event];
        return;
    }
    // Handle Apple Pencil separately from finger/trackpad input.
    // Pencil pressure is not available through Virtualization.framework,
    // so we send it over vsock to pencil-probe in the guest, which
    // injects synthetic tablet events via CGEventPost.
    // Early-return only if vsock send succeeds: if the Pencil event also
    // fell through to the normal sendPointer() path, the guest would see
    // both a tablet event (with pressure) and a plain mouse event
    // (without), causing duplicate strokes or overriding the pressure.
    // When the relay is not running, fall through so the Pencil still
    // works as a regular pointing device (no pressure, but usable).
    if (pencilRelayEnabled()) for (UITouch *t in touches) {
        if (t.type == UITouchTypeStylus) {
            CGPoint p = [t locationInView:self];
            CGRect b = self.bounds;
            float pressure = (t.maximumPossibleForce > 0)
                ? (float)(t.force / t.maximumPossibleForce) : 0;
            float nx = (b.size.width > 0) ? (float)(p.x / b.size.width) : 0;
            float ny = (b.size.height > 0) ? (float)(p.y / b.size.height) : 0;
            float altitude = (float)t.altitudeAngle;
            float azimuth = (float)[t azimuthAngleInView:self];
            _vzPencilRelayStrokeConnected = pencilVsockSend(
                kPencilEventProximityEnter, pressure, nx, ny,
                altitude, azimuth);
            _vzPencilRelayStrokeClaimed =
                _vzPencilRelayStrokeConnected;
            if (_vzPencilRelayStrokeClaimed)
                return;
            break;
        }
    }
    if (touch) {
        // Hardware trackpad clicks reach a UIKit view as indirect-pointer
        // touches even when GameController exposes no GCMouse. Preserve
        // UIKit's native primary/secondary/middle button bits instead of
        // turning every such click into a primary click. A direct finger
        // touch has no button mask and remains a primary click.
        NSUInteger eventButtons = (NSUInteger)event.buttonMask & 0x7U;
        _vzSuppressIndirectPointerClick =
            touch.type == UITouchTypeIndirectPointer && eventButtons != 0 &&
            CACurrentMediaTime() <= gSuppressSurfaceClickUntil;
        gTouchButtons = _vzSuppressIndirectPointerClick
            ? 0 : (eventButtons ?: 1U);
        if (_vzSuppressIndirectPointerClick && gDebugLogging)
            printf("[VirtualMac] suppressed momentum-interrupt UIKit "
                   "click buttons=0x%lx\n", (unsigned long)eventButtons);
        // UIKit suspends hover updates while a trackpad button is held, but
        // the indirect UITouch continues to report every live drag position.
        // Treat it as authoritative or the guest only sees the final point.
        CGPoint point = [touch locationInView:self];
        if (touch.type == UITouchTypeDirect) {
            NSTimeInterval now = touch.timestamp;
            BOOL accommodate = [VZAppSettings.sharedSettings
                boolForKey:VZTouchDoubleTapAccommodationKey];
            if (accommodate) {
                CGFloat dx = point.x - _vzLastDirectTap.x;
                CGFloat dy = point.y - _vzLastDirectTap.y;
                // Only coalesce a deliberate, quick double-tap. A broad
                // interval makes two ordinary taps on nearby controls land
                // on the first control instead.
                if (now - _vzLastDirectTapTime <= 0.20 &&
                    hypot(dx, dy) <= 30.0)
                    point = _vzLastDirectTap;
                _vzDirectTouchStart = point;
                _vzDirectTouchActive = YES;
                _vzDirectTouchDragging = NO;
            }
        }
        // Match the working hardware-trackpad path: establish the guest
        // pointer location before pressing. Modern AppKit menu tracking needs
        // this hover/move transition before a direct tap on a menu item.
        if (touch.type == UITouchTypeDirect)
            sendPointer(point, self.bounds, gHardwareMouseButtons);
        sendPointer(point, self.bounds, activePointerButtons());
        printf("[VirtualMac] touch began type=%ld buttons=0x%lx\n",
               (long)touch.type, (unsigned long)gTouchButtons);
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self moveDeferredDirectTouches:touches withEvent:event];
        return;
    }
    // Same Pencil handling as touchesBegan — see comments there.
    // type=0 (point) for continuous drag events.
    if (_vzPencilRelayStrokeClaimed) for (UITouch *t in touches) {
        if (t.type == UITouchTypeStylus) {
            CGRect b = self.bounds;
            // Send all intermediate touches from coalescedTouchesForTouch:
            // to approach the iPad's 240Hz sampling resolution.
            // Falls back to the current touch alone when nil.
            NSArray<UITouch *> *coalesced = [event coalescedTouchesForTouch:t];
            if (!coalesced) coalesced = @[t];
            for (UITouch *ct in coalesced) {
                CGPoint p = [ct locationInView:self];
                float pressure = (ct.maximumPossibleForce > 0)
                    ? (float)(ct.force / ct.maximumPossibleForce) : 0;
                float nx = (b.size.width > 0) ? (float)(p.x / b.size.width) : 0;
                float ny = (b.size.height > 0) ? (float)(p.y / b.size.height) : 0;
                float altitude = (float)ct.altitudeAngle;
                float azimuth = (float)[ct azimuthAngleInView:self];
                if (_vzPencilRelayStrokeConnected)
                    _vzPencilRelayStrokeConnected = pencilVsockSend(
                        kPencilEventPoint, pressure, nx, ny,
                        altitude, azimuth);
                if (!_vzPencilRelayStrokeConnected) break;
            }
            return;
        }
    }
    if (touch) {
        NSUInteger eventButtons = (NSUInteger)event.buttonMask & 0x7U;
        if (eventButtons && !_vzSuppressIndirectPointerClick)
            gTouchButtons = eventButtons;
        CGPoint point = [touch locationInView:self];
        if (touch.type == UITouchTypeDirect && _vzDirectTouchActive &&
            !_vzDirectTouchDragging) {
            CGFloat dx = point.x - _vzDirectTouchStart.x;
            CGFloat dy = point.y - _vzDirectTouchStart.y;
            // Ignore finger jitter during an ordinary click. Modern AppKit
            // menus interpret tiny held movement as a drag-and-dismiss. An
            // intentional drag becomes live immediately outside tap slop.
            if (hypot(dx, dy) <= 8.0)
                return;
            _vzDirectTouchDragging = YES;
        }
        sendPointer(point, self.bounds,
                    activePointerButtons());
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event
{
    // type=2 (proximity_leave): Pencil lifted off screen.
    // Pressure is 0 because the pen is no longer touching.
    // altitude=π/2 (perpendicular): the pen has no meaningful tilt
    // at lift-off, and this gives tilt=(0,0) after conversion.
    if (_vzPencilRelayStrokeClaimed) for (UITouch *t in touches) {
        if (t.type == UITouchTypeStylus) {
            CGPoint p = [t locationInView:self];
            CGRect b = self.bounds;
            float nx = (b.size.width > 0) ? (float)(p.x / b.size.width) : 0;
            float ny = (b.size.height > 0) ? (float)(p.y / b.size.height) : 0;
            float altitude = (float)t.altitudeAngle;
            float azimuth = (float)[t azimuthAngleInView:self];
            if (_vzPencilRelayStrokeConnected)
                pencilVsockSend(kPencilEventProximityLeave, 0, nx, ny,
                                altitude, azimuth);
            _vzPencilRelayStrokeClaimed = NO;
            _vzPencilRelayStrokeConnected = NO;
            return;
        }
    }
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self endDeferredDirectTouches:touches withEvent:event];
        return;
    }
    if (touch) {
        (void)event;
        gTouchButtons = 0;
        CGPoint point = [touch locationInView:self];
        if (touch.type == UITouchTypeDirect && _vzDirectTouchActive) {
            if (!_vzDirectTouchDragging) {
                point = _vzDirectTouchStart;
                _vzLastDirectTap = point;
                _vzLastDirectTapTime = touch.timestamp;
            } else {
                _vzLastDirectTapTime = 0;
            }
            _vzDirectTouchActive = NO;
            _vzDirectTouchDragging = NO;
        }
        sendPointer(point, self.bounds,
                    activePointerButtons());
        if (touch.type == UITouchTypeIndirectPointer)
            _vzSuppressIndirectPointerClick = NO;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event
{
    UITouch *touch = [touches anyObject];
    if (touch.type == UITouchTypeDirect && [self usesDeferredDirectTouchClicks]) {
        [self cancelDeferredDirectTouches:touches withEvent:event];
        return;
    }
    [self touchesEnded:touches withEvent:event];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, YES))
        [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, NO))
        [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
               withEvent:(UIPressesEvent *)event
{
    sendPresses(presses, NO);
}

@end

@interface VZHUDView : UIView
@property(nonatomic, assign) id menuTarget;
- (instancetype)initWithTarget:(id)target;
- (void)setContentOpacity:(CGFloat)opacity;
- (void)refreshMenu;
@end

@implementation VZHUDView

- (void)refreshMenu
{
    UIButton *keyboard = (UIButton *)[self viewWithTag:1703];
    keyboard.hidden = GCKeyboard.coalescedKeyboard != nil;
    // With the keyboard action removed, the remaining 46-point More button
    // and four-point insets make a 54-point square. Match its radius so the
    // compact hardware-keyboard control is circular rather than pill-shaped.
    self.layer.cornerRadius = keyboard.hidden ? 27.0 : 18.0;
    UIButton *button = (UIButton *)[self viewWithTag:1702];
    if (!button || !self.menuTarget)
        return;
    button.menu = ((id(*)(id, SEL))objc_msgSend)(
        self.menuTarget, NSSelectorFromString(@"hudMenu"));
}

- (void)setContentOpacity:(CGFloat)opacity
{
    opacity = MAX(0.0, MIN(1.0, opacity));
    // Keep the container and buttons at alpha 1 so UIKit continues hit
    // testing them when the user chooses zero visual opacity. Only the cheap
    // solid background and symbol tint become transparent; no effect view or
    // offscreen pass is introduced.
    self.alpha = 1.0;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86 * opacity];
    UIStackView *stack = (UIStackView *)[self viewWithTag:1701];
    for (UIButton *button in stack.arrangedSubviews)
        button.tintColor = [UIColor.whiteColor colorWithAlphaComponent:opacity];
}

- (instancetype)initWithTarget:(id)target
{
    if ((self = [super initWithFrame:CGRectZero])) {
        self.menuTarget = target;
        // A small, solid translucent layer is considerably cheaper than a
        // UIVisualEffectView: no backdrop capture, blur, or offscreen effect
        // pass is introduced above the continuously updating PVG surface.
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86];
        self.layer.cornerRadius = 18;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        UIStackView *stack = [[[UIStackView alloc] init] autorelease];
        stack.tag = 1701;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 2;
        for (NSDictionary *item in @[
            @{@"icon": @"keyboard", @"selector": @"hudKeyboard:"},
            @{@"icon": @"ellipsis", @"menu": @YES},
        ]) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setImage:[UIImage systemImageNamed:item[@"icon"]]
                    forState:UIControlStateNormal];
            button.tintColor = UIColor.whiteColor;
            if ([item[@"menu"] boolValue]) {
                button.tag = 1702;
                button.menu = ((id(*)(id, SEL))objc_msgSend)(
                    target, NSSelectorFromString(@"hudMenu"));
                button.showsMenuAsPrimaryAction = YES;
                button.accessibilityLabel = VZL(@"Virtual Mac Controls");
            } else {
                button.tag = 1703;
                [button addTarget:target action:NSSelectorFromString(item[@"selector"])
                    forControlEvents:UIControlEventTouchUpInside];
            }
            [button.widthAnchor constraintEqualToConstant:46].active = YES;
            [button.heightAnchor constraintEqualToConstant:46].active = YES;
            [stack addArrangedSubview:button];
        }
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
        ]];
        [self refreshMenu];
    }
    return self;
}
@end

@interface VZViewController : UIViewController
    <VZVMLibraryViewControllerDelegate>
@property(nonatomic, retain) UINavigationController *libraryNavigationController;
@property(nonatomic, retain) VZProgressViewController *installationController;
@property(nonatomic, retain) NSTimer *installationTimer;
@property(nonatomic, copy) NSString *installationLogPath;
@property(nonatomic, copy) NSString *installationBundlePath;
@property(nonatomic, copy) NSString *installationStagingPath;
@property(nonatomic, copy) NSString *installationAttemptPath;
@property(nonatomic, copy) NSString *installationRestoreImagePath;
@property(nonatomic, retain) NSDictionary *installationOptions;
@property(nonatomic, assign) pid_t installationProcess;
@property(nonatomic, copy) NSString *activeVMBundlePath;
@property(nonatomic, assign, getter=isVMDisplayActive) BOOL vmDisplayActive;
@property(nonatomic, assign) BOOL didCheckInstallationAttempts;
- (void)presentVMLibrary;
- (void)finishVMAndShowLibraryWithError:(NSError *)error;
- (void)activateVMDisplay:(BOOL)active;
- (void)updateHUDVisibility;
- (void)updateHUDPosition;
- (UIMenu *)hudMenu;
- (void)confirmForceShutdown;
@end

@implementation VZViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(appSettingsChanged:)
        name:VZSettingsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCKeyboardDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCKeyboardDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCMouseDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(peripheralChanged:)
        name:GCMouseDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(externalScreenChanged:)
        name:UIScreenDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(externalScreenChanged:)
        name:UIScreenDidDisconnectNotification object:nil];
}

- (void)peripheralChanged:(NSNotification *)notification
{
    (void)notification;
    if (GCKeyboard.coalescedKeyboard && self.isVMDisplayActive &&
        !gInputView.hidden) {
        [gInputView becomeFirstResponder];
        [gInputView reloadInputViews];
    } else if (!gSoftwareKeyboardRequested) {
        [gInputView resignFirstResponder];
    }
    [self updateHUDVisibility];
    [(VZHUDView *)gHUDView refreshMenu];
}

- (void)externalScreenChanged:(NSNotification *)notification
{
    if ([notification.name isEqualToString:UIScreenDidConnectNotification]) {
        // Use the screen from the notification directly — UIScreen.screens
        // may not be updated yet at the time this notification fires.
        UIScreen *screen = notification.object;
        if (screen && screen != UIScreen.mainScreen && externalDisplayEnabled()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                 connectExternalDisplayWithScreen(screen);
            });
        }
    } else {
        disconnectExternalDisplay();
    }
    [(VZHUDView *)gHUDView refreshMenu];
}

- (void)appSettingsChanged:(NSNotification *)notification
{
    (void)notification;
    gFixExternalDisplayScrollDirection = [VZAppSettings.sharedSettings
        boolForKey:VZExternalDisplayScrollFixKey];
    gScrollingSpeed = MAX(0.1, MIN(1.0,
        [[VZAppSettings.sharedSettings stringForKey:VZScrollingSpeedKey]
            doubleValue]));
    gShowCursorWhenUsingTouch = [VZAppSettings.sharedSettings
        boolForKey:VZShowCursorWhenUsingTouchKey];
    notePointerInputSource(gLastInputWasDirectTouch);
    printf("[VirtualMac] scroll settings speed=%.2f\n", gScrollingSpeed);
    if (gStatusLabel)
        gStatusLabel.hidden = !shouldShowStatusLabel();
    [self updateImmersivePresentation];
    [self updateHUDPosition];
    [(VZHUDView *)gHUDView refreshMenu];
    [self updateHUDVisibility];
    updateDisplayGeometry();
    if (gTouchScrollRecognizer) {
        BOOL enabled = [VZAppSettings.sharedSettings
            boolForKey:VZTouchTwoFingerScrollingKey];
        gTouchScrollRecognizer.enabled = enabled;
        NSArray *allowed = enabled ? @[@(UITouchTypeIndirectPointer)]
                                   : @[@(UITouchTypeDirect),
                                       @(UITouchTypeIndirectPointer)];
        gPinchRecognizer.allowedTouchTypes = allowed;
        gRotationRecognizer.allowedTouchTypes = allowed;
        gSmartMagnifyRecognizer.allowedTouchTypes = allowed;
    }
}

- (void)updateHUDPosition
{
    if (!gHUDView)
        return;
    if (gHUDHorizontalConstraint)
        [gHUDHorizontalConstraint setActive:NO];
    if (gHUDVerticalConstraint)
        [gHUDVerticalConstraint setActive:NO];
    NSString *corner = [VZAppSettings.sharedSettings stringForKey:VZHUDCornerKey]
        ?: @"bottom-right";
    BOOL left = [corner hasSuffix:@"left"];
    BOOL bottom = [corner hasPrefix:@"bottom"];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    gHUDHorizontalConstraint = left
        ? [gHUDView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16]
        : [gHUDView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16];
    gHUDVerticalConstraint = bottom
        ? [gHUDView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-16]
        : [gHUDView.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16];
    [NSLayoutConstraint activateConstraints:@[
        gHUDHorizontalConstraint, gHUDVerticalConstraint]];
}

- (void)updateHUDVisibility
{
    NSString *choice = [VZAppSettings.sharedSettings stringForKey:VZHUDVisibilityKey]
        ?: @"always";
    BOOL hidden = !self.isVMDisplayActive || [choice isEqualToString:@"hidden"];
    CGFloat opacity = [[VZAppSettings.sharedSettings
        stringForKey:VZHUDOpacityKey] doubleValue];
    [(VZHUDView *)gHUDView setContentOpacity:opacity];
    gHUDView.hidden = hidden;
}

- (void)hudKeyboard:(UIButton *)sender
{
    (void)sender;
    if (gSoftwareKeyboardRequested && gInputView.isFirstResponder) {
        gSoftwareKeyboardRequested = NO;
        [gInputView resignFirstResponder];
    } else {
        gSoftwareKeyboardRequested = YES;
        [gInputView becomeFirstResponder];
        [gInputView reloadInputViews];
    }
}

- (UIMenu *)hudMenu
{
    NSString *visibility = [VZAppSettings.sharedSettings
        stringForKey:VZHUDVisibilityKey] ?: @"always";
    NSString *current = [VZAppSettings.sharedSettings stringForKey:VZHUDCornerKey]
        ?: @"bottom-right";
    BOOL bottom = [current hasPrefix:@"bottom"];
    NSMutableArray *visibilityActions = [NSMutableArray array];
    for (NSDictionary *choice in @[
        @{@"title": VZL(@"On"), @"value": @"always", @"icon": @"eye"},
        @{@"title": VZL(@"Off"), @"value": @"hidden", @"icon": @"eye.slash"},
    ]) {
        UIAction *action = [UIAction actionWithTitle:choice[@"title"]
            image:[UIImage systemImageNamed:choice[@"icon"]] identifier:nil
            handler:^(UIAction *selected) {
            (void)selected;
            [VZAppSettings.sharedSettings setString:choice[@"value"]
                forKey:VZHUDVisibilityKey];
            [self updateHUDVisibility];
            [(VZHUDView *)gHUDView refreshMenu];
            if (![choice[@"value"] isEqualToString:@"always"]) {
                UIAlertController *notice = [UIAlertController
                    alertControllerWithTitle:VZL(@"Show Virtual Mac Controls")
                    message:VZL(@"To show the controls, touch and hold the Virtual Mac icon on the Home Screen, then choose Show Virtual Mac Controls.")
                    preferredStyle:UIAlertControllerStyleAlert];
                [notice addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:notice animated:YES completion:nil];
            }
        }];
        action.state = [visibility isEqualToString:choice[@"value"]]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [visibilityActions addObject:action];
    }
    if (bottom)
        visibilityActions = [NSMutableArray arrayWithArray:
            visibilityActions.reverseObjectEnumerator.allObjects];
    UIMenu *visibilityMenu = [UIMenu menuWithTitle:VZL(@"Show Controls")
        children:visibilityActions];
    NSMutableArray *placements = [NSMutableArray array];
    for (NSDictionary *placement in @[
        @{@"title": VZL(@"Top Left"), @"value": @"top-left", @"icon": @"arrow.up.left"},
        @{@"title": VZL(@"Top Right"), @"value": @"top-right", @"icon": @"arrow.up.right"},
        @{@"title": VZL(@"Bottom Left"), @"value": @"bottom-left", @"icon": @"arrow.down.left"},
        @{@"title": VZL(@"Bottom Right"), @"value": @"bottom-right", @"icon": @"arrow.down.right"},
    ]) {
        UIAction *move = [UIAction actionWithTitle:placement[@"title"]
            image:[UIImage systemImageNamed:placement[@"icon"]]
            identifier:nil handler:^(UIAction *action) {
            (void)action;
            [VZAppSettings.sharedSettings setString:placement[@"value"]
                                              forKey:VZHUDCornerKey];
            [self updateHUDPosition];
            [(VZHUDView *)gHUDView refreshMenu];
        }];
        move.state = [current isEqualToString:placement[@"value"]]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [placements addObject:move];
    }
    if (bottom)
        placements = [NSMutableArray arrayWithArray:
            placements.reverseObjectEnumerator.allObjects];
    UIMenu *moveMenu = [UIMenu menuWithTitle:VZL(@"Move Controls") children:placements];
    NSMutableArray *machineActions = [NSMutableArray array];
    if (UIScreen.screens.count > 1) {
        BOOL extEnabled = [VZAppSettings.sharedSettings
            boolForKey:VZExternalDisplayEnabledKey];
        UIAction *extToggle = [UIAction actionWithTitle:VZL(@"Full Screen Mirroring")
            image:[UIImage systemImageNamed:@"display"]
            identifier:nil handler:^(UIAction *action) {
            (void)action;
            BOOL now = ![VZAppSettings.sharedSettings
                boolForKey:VZExternalDisplayEnabledKey];
            [VZAppSettings.sharedSettings setBool:now
                forKey:VZExternalDisplayEnabledKey];
            if (now)
                connectExternalDisplay();
            else
                disconnectExternalDisplay();
            [(VZHUDView *)gHUDView refreshMenu];
        }];
        extToggle.state = extEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;
        [machineActions addObject:extToggle];
    }
    UIAction *shutdown = [UIAction actionWithTitle:VZL(@"Force Shut Down")
        image:[UIImage systemImageNamed:@"power"] identifier:nil
        handler:^(UIAction *action) { (void)action; [self confirmForceShutdown]; }];
    shutdown.attributes = UIMenuElementAttributesDestructive;
    [machineActions addObject:shutdown];
    UIMenu *machineSection = [UIMenu menuWithTitle:@"" image:nil
        identifier:nil options:UIMenuOptionsDisplayInline
        children:machineActions];
    UIAction *settings = [UIAction actionWithTitle:VZL(@"Settings")
        image:[UIImage systemImageNamed:@"gearshape"] identifier:nil
        handler:^(UIAction *action) {
        (void)action;
        VZSettingsViewController *controller = [[[VZSettingsViewController alloc]
            initWithMachines:VZDiscoverVirtualMachines()] autorelease];
        UINavigationController *navigation = [[[UINavigationController alloc]
            initWithRootViewController:controller] autorelease];
        navigation.modalPresentationStyle = UIModalPresentationFormSheet;
        navigation.preferredContentSize = CGSizeMake(620, 720);
        [self presentViewController:navigation animated:YES completion:nil];
    }];
    UIAction *library = [UIAction actionWithTitle:VZL(@"Show Library")
        image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil
        handler:^(UIAction *action) { (void)action; [self presentVMLibrary]; }];
    UIMenu *navigationSection = [UIMenu menuWithTitle:@"" image:nil
        identifier:nil options:UIMenuOptionsDisplayInline
        children:@[settings, library]];
    NSArray *sections = bottom
        ? @[navigationSection, machineSection, moveMenu, visibilityMenu]
        : @[visibilityMenu, moveMenu, machineSection, navigationSection];
    return [UIMenu menuWithTitle:@"" children:sections];
}

- (void)confirmForceShutdown
{
    if (!gVirtualMachine)
        return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:VZL(@"Force Shut Down Virtual Mac?")
        message:VZL(@"Unsaved changes in macOS may be lost.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:VZL(@"Force Shut Down")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        forceStopVirtualMachine();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

static NSURL *persistentRestoreImageURL(NSURL *sourceURL, NSError **error)
{
    NSString *directory = VZRestoreImagesPath();
    if (![NSFileManager.defaultManager
            createDirectoryAtPath:directory
      withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
    NSString *directoryPrefix = [directory.stringByStandardizingPath
        stringByAppendingString:@"/"];
    if ([sourcePath hasPrefix:directoryPrefix])
        return sourceURL;

    NSString *filename = sourceURL.lastPathComponent.length
        ? sourceURL.lastPathComponent : @"Restore.ipsw";
    NSString *destinationPath = [directory
        stringByAppendingPathComponent:filename];
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    if ([NSFileManager.defaultManager fileExistsAtPath:destinationPath]) {
        NSDictionary *sourceAttributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:sourcePath error:nil];
        NSDictionary *destinationAttributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:destinationPath error:nil];
        // Reuse only the exact existing hard link. A different IPSW can have
        // the same filename (and even size), so size is not a safe identity.
        if ([sourceAttributes[NSFileSystemFileNumber] isEqual:
                destinationAttributes[NSFileSystemFileNumber]])
            return destinationURL;
        NSString *stem = filename.stringByDeletingPathExtension;
        NSString *extension = filename.pathExtension;
        filename = [NSString stringWithFormat:@"%@-%@%@%@", stem,
            NSUUID.UUID.UUIDString,
            extension.length ? @"." : @"", extension];
        destinationPath = [directory stringByAppendingPathComponent:filename];
        destinationURL = [NSURL fileURLWithPath:destinationPath];
    }
    // Downloads and the VM library are on the same APFS volume. A hard link
    // makes the security-scoped File Provider item permanently reachable by
    // the root installer without copying a multi-gigabyte IPSW.
    if (![NSFileManager.defaultManager linkItemAtURL:sourceURL
                                              toURL:destinationURL
                                              error:error])
        return nil;
    return destinationURL;
}

static NSString *VZInstallationLogTail(NSString *path, NSUInteger limit,
                                       BOOL omitProgress)
{
    NSString *contents = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil];
    if (!contents.length)
        return @"";
    if (omitProgress) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"INSTALL_PROGRESS\t"])
                [filtered addObject:line];
        }
        contents = [filtered componentsJoinedByString:@"\n"];
    }
    if (contents.length > limit)
        contents = [@"… earlier output omitted …\n"
            stringByAppendingString:
                [contents substringFromIndex:contents.length - limit]];
    return contents;
}

static NSString *VZInstallationConsoleText(NSString *installLogPath)
{
    NSArray *sources = @[
        @[@"INSTALLER", installLogPath ?: @"", @YES],
        @[@"INSTALLER LAUNCHER", @"/tmp/installation.stderr.log", @NO],
        @[@"INSTALLATION HOOK", @"/tmp/installationhook.log", @NO],
        @[@"VIRTUALIZATION FRAMEWORK", @"/tmp/vzxpchook.log", @NO],
        @[@"MOBILEDEVICE / RESTORE USB", @"/tmp/installation-usb.log", @NO],
        @[@"USBMUXD", @"/tmp/vz-usbmuxd.log", @NO],
        @[@"USBMUXD LAUNCHER", @"/tmp/vz-usbmuxd-launch.log", @NO],
        @[@"RESTORE VMM STDERR", @"/tmp/restore-vmm.stderr.log", @NO],
        @[@"RESTORE VMM", @"/tmp/vmmhook.log", @NO],
    ];
    NSMutableString *console = [NSMutableString string];
    for (NSArray *source in sources) {
        NSString *tail = VZInstallationLogTail(
            source[1], 16 * 1024, [source[2] boolValue]);
        if (!tail.length)
            continue;
        if (console.length)
            [console appendString:@"\n\n"];
        [console appendFormat:@"── %@ ──\n%@", source[0], tail];
    }
    return console.length ? console : VZL(@"Waiting for installation output…");
}

static void VZWriteInstallationAttempt(NSString *attemptPath, NSString *state,
                                       NSDictionary *details)
{
    if (!attemptPath.length) return;
    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:[attemptPath stringByAppendingPathComponent:@"Attempt.plist"]] ?: @{}];
    [record addEntriesFromDictionary:details ?: @{}];
    record[@"State"] = state;
    record[@"UpdatedAt"] = NSDate.date;
    [record writeToFile:[attemptPath stringByAppendingPathComponent:@"Attempt.plist"] atomically:YES];
}
- (BOOL)prefersStatusBarHidden
{
    return self.isVMDisplayActive;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return self.isVMDisplayActive && [VZAppSettings.sharedSettings
        boolForKey:VZHomeIndicatorSuppressionKey];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures
{
    return self.isVMDisplayActive && [VZAppSettings.sharedSettings
        boolForKey:VZSystemGestureSuppressionKey] ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)updateImmersivePresentation
{
    BOOL active = self.isVMDisplayActive;
    printf("[VirtualMac] presentation activeVM=%d statusBarHidden=%d "
           "homeIndicatorHidden=%d deferredEdges=0x%lx\n",
           active, active, active,
           (unsigned long)(active ? UIRectEdgeAll : UIRectEdgeNone));
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}

- (void)activateVMDisplay:(BOOL)active
{
    self.vmDisplayActive = active;
    self.view.backgroundColor = active ? UIColor.blackColor
                                       : UIColor.systemBackgroundColor;
    if (active) {
        FILE *marker = fopen("/tmp/virtual-mac-vm-active", "w");
        if (marker) {
            fputs("active\n", marker);
            fclose(marker);
        }
        resetPointerSession(YES);
    } else {
        unlink("/tmp/virtual-mac-vm-active");
    }
    [self updateImmersivePresentation];
    [self updateHUDVisibility];
}

- (void)presentVMLibrary
{
    printf("[VirtualMac] presenting VM library\n");
    BOOL crossfade = self.isVMDisplayActive;
    if (!self.libraryNavigationController) {
        VZVMLibraryViewController *library =
            [[[VZVMLibraryViewController alloc] init] autorelease];
        library.delegate = self;
        self.libraryNavigationController = [[[UINavigationController alloc]
            initWithRootViewController:library] autorelease];
        [self addChildViewController:self.libraryNavigationController];
        self.libraryNavigationController.view.frame = self.view.bounds;
        self.libraryNavigationController.view.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.libraryNavigationController.view.hidden = crossfade;
        [self.view addSubview:self.libraryNavigationController.view];
        [self.libraryNavigationController didMoveToParentViewController:self];
    } else {
        VZVMLibraryViewController *library =
            (id)self.libraryNavigationController.viewControllers.firstObject;
        [library reloadLibrary];
    }
    void (^showLibrary)(void) = ^{
        self.libraryNavigationController.view.hidden = NO;
        [self.view bringSubviewToFront:self.libraryNavigationController.view];
        gInputView.hidden = YES;
        gSoftwareKeyboardRequested = NO;
        [gInputView resignFirstResponder];
        gCursorView.hidden = YES;
        [self activateVMDisplay:NO];
    };
    if (crossfade) {
        [UIView transitionWithView:self.view duration:0.24
            options:UIViewAnimationOptionTransitionCrossDissolve |
                    UIViewAnimationOptionAllowAnimatedContent
            animations:showLibrary completion:nil];
    } else {
        showLibrary();
    }
    if (!self.didCheckInstallationAttempts) {
        self.didCheckInstallationAttempts = YES;
        NSMutableArray *interrupted = [NSMutableArray array];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:
                VZInstallationsPath() error:nil]) {
            if (![name hasSuffix:@".installation"]) continue;
            NSString *path = [VZInstallationsPath() stringByAppendingPathComponent:name];
            NSDictionary *attempt = [NSDictionary dictionaryWithContentsOfFile:
                [path stringByAppendingPathComponent:@"Attempt.plist"]];
            NSString *state = attempt[@"State"];
            if ([state isEqualToString:@"installing"] || [state isEqualToString:@"failed"])
                [interrupted addObject:@{ @"path": path, @"record": attempt ?: @{} }];
        }
        if (interrupted.count) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSMutableString *details = [NSMutableString string];
            for (NSDictionary *item in interrupted) {
                NSDictionary *record = item[@"record"];
                [details appendFormat:VZL(@"%@\nState: %@\n%@\n\n"),
                    record[@"Name"] ?: [item[@"path"] lastPathComponent],
                    record[@"State"] ?: VZL(@"Unknown"), item[@"path"]];
            }
            VZFailureDetailsViewController *controller =
                [[[VZFailureDetailsViewController alloc]
                    initWithTitle:interrupted.count == 1
                        ? VZL(@"Incomplete Installation")
                        : VZL(@"Incomplete Installations")
                    message:VZL(@"A previous macOS installation did not finish.")
                    details:details
                    options:VZFailureSupportOptionNone]
                    autorelease];
            [controller setDestructiveActionTitle:VZL(@"Delete All")
                handler:^{
                    NSMutableArray *paths = [NSMutableArray array];
                    for (NSDictionary *item in interrupted)
                        [paths addObject:item[@"path"]];
                    VZRemovePaths(paths);
                }];
            UINavigationController *navigation =
                [[[UINavigationController alloc]
                    initWithRootViewController:controller] autorelease];
            navigation.modalPresentationStyle = UIModalPresentationPageSheet;
            navigation.preferredContentSize = CGSizeMake(640, 720);
            [self presentViewController:navigation animated:YES completion:nil];
        });
    }
}

- (void)vmLibrary:(VZVMLibraryViewController *)library
    bootBundleAtPath:(NSString *)path options:(NSDictionary *)options
{
    if (gVirtualMachine) {
        if ([self.activeVMBundlePath isEqualToString:path]) {
            [self vmLibraryResumeActiveVM:library];
            return;
        }
        UIAlertController *running = [UIAlertController
            alertControllerWithTitle:VZL(@"Another Virtual Mac Is Running")
            message:VZL(@"Switch to the running Virtual Mac and shut it down before starting another one.")
            preferredStyle:UIAlertControllerStyleAlert];
        [running addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleCancel handler:nil]];
        [running addAction:[UIAlertAction
            actionWithTitle:VZL(@"Switch to Running Virtual Mac")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                [self vmLibraryResumeActiveVM:library];
            }]];
        [self presentViewController:running animated:YES completion:nil];
        return;
    }
    if (VZIsRootHideEnvironment() && !gRootHidePivotalActionApproved) {
        VZContinueAfterRootHideInformation(self, ^{
            gRootHidePivotalActionApproved = YES;
            [self vmLibrary:library bootBundleAtPath:path options:options];
            gRootHidePivotalActionApproved = NO;
        });
        return;
    }
    printf("[VirtualMac] selected VM path=%s options=%s\n", path.UTF8String,
           options.description.UTF8String);
    gVideoMemoryAlertPresented = NO;
    self.activeVMBundlePath = path;
    if (self.libraryNavigationController.view.window &&
        !self.libraryNavigationController.view.hidden) {
        [UIView transitionWithView:self.view duration:0.32
            options:UIViewAnimationOptionTransitionCrossDissolve |
                    UIViewAnimationOptionAllowAnimatedContent
            animations:^{
                self.libraryNavigationController.view.hidden = YES;
                gInputView.hidden = NO;
            } completion:nil];
    } else {
        self.libraryNavigationController.view.hidden = YES;
        gInputView.hidden = NO;
    }
    [self activateVMDisplay:YES];
    startVirtualMachine(self.view, self, path, options);
}

- (NSString *)activeVMBundlePathForLibrary:
    (VZVMLibraryViewController *)library
{
    (void)library;
    return gVirtualMachine ? self.activeVMBundlePath : nil;
}

- (void)vmLibraryResumeActiveVM:(VZVMLibraryViewController *)library
{
    (void)library;
    if (!gVirtualMachine)
        return;
    [UIView transitionWithView:self.view duration:0.24
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{
            self.libraryNavigationController.view.hidden = YES;
            gInputView.hidden = NO;
            if (gCursorView.image)
                gCursorView.hidden = gCursorSuppressedForDirectTouch;
        } completion:nil];
    [self activateVMDisplay:YES];
    if (GCKeyboard.coalescedKeyboard)
        [gInputView becomeFirstResponder];
}

- (void)vmLibraryForceShutdownActiveVM:
    (VZVMLibraryViewController *)library
{
    (void)library;
    forceStopVirtualMachine();
}

- (void)vmLibrary:(VZVMLibraryViewController *)library
    installRestoreImageAtURL:(NSURL *)url name:(NSString *)name
                     options:(NSDictionary *)options
{
    (void)library;
    if (self.installationController || self.installationTimer) {
        printf("[VirtualMac] ignored duplicate installation request\n");
        return;
    }
    if (VZIsRootHideEnvironment() && !gRootHidePivotalActionApproved) {
        VZContinueAfterRootHideInformation(self, ^{
            gRootHidePivotalActionApproved = YES;
            [self vmLibrary:library installRestoreImageAtURL:url name:name
                    options:options];
            gRootHidePivotalActionApproved = NO;
        });
        return;
    }
    NSError *imageError = nil;
    NSURL *persistentURL = persistentRestoreImageURL(url, &imageError);
    [url stopAccessingSecurityScopedResource];
    if (!persistentURL) {
        VZPresentFailureReport(self,
            VZL(@"Could Not Prepare Restore Image"),
            imageError.localizedDescription, imageError.debugDescription,
            VZFailureSupportOptionNone);
        return;
    }
    url = persistentURL;
    NSString *bundlePath = [VZVMLibraryPath() stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"bundle"]];
    NSString *attempt = [NSString stringWithFormat:@"%@-%@", name,
        NSUUID.UUID.UUIDString];
    NSString *attemptPath = [VZInstallationsPath() stringByAppendingPathComponent:
        [attempt stringByAppendingPathExtension:@"installation"]];
    NSString *stagingPath = [attemptPath stringByAppendingPathComponent:@"Staging.bundle.installing"];
    // Keep the launcher's allowlisted suffix while retaining all files inside
    // the durable attempt directory.
    NSString *logPath = [attemptPath stringByAppendingPathComponent:@"Installer.install.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:attemptPath
        withIntermediateDirectories:YES attributes:nil error:nil];
    if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        UIAlertController *exists = [UIAlertController
            alertControllerWithTitle:VZL(@"Name Already Used")
                             message:VZL(@"Delete or rename the existing Virtual Mac first.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [exists addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:exists animated:YES completion:nil];
        return;
    }
    // Restoring macOS temporarily runs both the installation service and a
    // VMM.  Passing a large runtime configuration through here can exhaust an
    // 8 GB iPad before RestoreOS starts.  Use the installer's stock 4-core,
    // 4-GiB configuration for every restore; the selected runtime values stay
    // in installationOptions and are written to the completed bundle below.
    static const NSUInteger restoreCPUCount = 4;
    static const uint64_t restoreMemorySize = 4ULL << 30;
    NSString *cpu = [@(restoreCPUCount) stringValue];
    NSString *memory = [@(restoreMemorySize) stringValue];
    NSString *storage = [options[@"StorageSize"] stringValue];
    const char *launcher =
        "/var/root/VirtualMac/install/install-launcher";
    char *arguments[] = {
        (char *)launcher,
        (char *)url.path.fileSystemRepresentation,
        (char *)stagingPath.fileSystemRepresentation,
        (char *)bundlePath.fileSystemRepresentation,
        (char *)logPath.fileSystemRepresentation,
        (char *)cpu.UTF8String,
        (char *)memory.UTF8String,
        (char *)storage.UTF8String,
        NULL,
    };
    [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    VZWriteInstallationAttempt(attemptPath, @"installing", @{
        @"Name": name, @"RestoreImage": url.path, @"Destination": bundlePath,
        @"StartedAt": NSDate.date,
    });
    pid_t process = 0;
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);
    int result = posix_spawn(&process, launcher, NULL, &attributes,
                             arguments, environ);
    posix_spawnattr_destroy(&attributes);
    if (result != 0) {
        VZWriteInstallationAttempt(attemptPath, @"failed", @{
            @"Failure": [NSString stringWithFormat:@"Could not start installer: %s", strerror(result)]
        });
        VZPresentFailureReport(self, VZL(@"Could Not Start Installer"),
            [NSString stringWithFormat:
                VZL(@"The installer could not be started: %s"),
                strerror(result)],
            [NSString stringWithFormat:
                @"posix_spawn(install-launcher)=%d (%s)",
                result, strerror(result)],
            VZFailureSupportOptionNone);
        return;
    }
    printf("[VirtualMac] installation launcher pid=%d ipsw=%s bundle=%s\n",
           process, url.path.UTF8String, bundlePath.UTF8String);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t changed;
        do {
            changed = waitpid(process, &status, 0);
        } while (changed < 0 && errno == EINTR);
        int exitCode = changed == process && WIFEXITED(status)
            ? WEXITSTATUS(status) : -1;
        int signalCode = changed == process && WIFSIGNALED(status)
            ? WTERMSIG(status) : 0;
        printf("[VirtualMac] installation launcher exited pid=%d status=%d "
               "signal=%d wait=%d\n", process,
               exitCode, signalCode, changed);
        if (exitCode != 0 || signalCode != 0 || changed != process) {
            NSString *existing = [NSString stringWithContentsOfFile:logPath
                encoding:NSUTF8StringEncoding error:nil] ?: @"";
            NSString *failure = [NSString stringWithFormat:
                @"INSTALL_FAILED\tlauncher exited status=%d signal=%d wait=%d\n",
                exitCode, signalCode, changed];
            if (![existing containsString:@"INSTALL_FAILED"]) {
                FILE *file = fopen(logPath.fileSystemRepresentation, "a");
                if (file) { fputs(failure.UTF8String, file); fclose(file); }
            }
            VZWriteInstallationAttempt(attemptPath, @"failed", @{@"Failure": failure});
        }
    });
    printf("[VirtualMac] restore resources cpu=%lu memory=%lluMiB; "
           "runtime resources cpu=%llu memory=%lluMiB\n",
           (unsigned long)restoreCPUCount, restoreMemorySize >> 20,
           [options[@"CPUCount"] unsignedLongLongValue],
           [options[@"MemorySize"] unsignedLongLongValue] >> 20);
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.installationAttemptPath = attemptPath;
    self.installationRestoreImagePath = url.path;
    self.installationProcess = process;
    self.installationLogPath = logPath;
    self.installationBundlePath = bundlePath;
    self.installationStagingPath = stagingPath;
    self.installationOptions = options;
    self.installationController = [[[VZProgressViewController alloc]
        initWithTitle:VZL(@"Installing macOS")] autorelease];
    self.installationController.statusText = VZL(@"Preparing installation…");
    self.installationController.detailText =
        VZDeviceString(
            VZL(@"Installation progress may pause for several minutes while the Virtual Mac starts the installation environment. Your iPad will remain awake."),
            VZL(@"Installation progress may pause for several minutes while the Virtual Mac starts the installation environment. Your iPhone will remain awake."));
    self.installationController.consoleText = VZL(@"Waiting for installation output…");
    self.installationController.indeterminate = YES;
    self.installationController.cancellationHandler = ^{
        UIAlertController *confirmation = [UIAlertController
            alertControllerWithTitle:VZL(@"Cancel Installation?")
                             message:VZL(@"The incomplete Virtual Mac and its installation files will be deleted.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:VZL(@"Keep Installing")
            style:UIAlertActionStyleCancel handler:nil]];
        [confirmation addAction:[UIAlertAction actionWithTitle:VZL(@"Cancel Installation")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            (void)action;
            [self.installationTimer invalidate];
            self.installationTimer = nil;
            NSString *pid = [NSString stringWithFormat:@"%d", self.installationProcess];
            const char *cancelLauncher = "/var/root/VirtualMac/install/install-launcher";
            char *cancelArguments[] = {(char *)cancelLauncher, "--cancel-install",
                (char *)pid.UTF8String,
                (char *)self.installationAttemptPath.fileSystemRepresentation, NULL};
            pid_t cancellation = 0;
            posix_spawn(&cancellation, cancelLauncher, NULL, NULL,
                        cancelArguments, environ);
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            self.installationController.cancellationHandler = nil;
            [self.installationController.navigationController
                dismissViewControllerAnimated:YES completion:^{
                self.installationController = nil;
                self.installationProcess = 0;
                [self presentVMLibrary];
            }];
        }]];
        [self.installationController presentViewController:confirmation
            animated:YES completion:nil];
    };
    UINavigationController *installationNavigation = [[[UINavigationController alloc]
        initWithRootViewController:self.installationController] autorelease];
    installationNavigation.modalPresentationStyle = UIModalPresentationPageSheet;
    installationNavigation.modalInPresentation = YES;
    installationNavigation.preferredContentSize = CGSizeMake(640, 620);
    [self presentViewController:installationNavigation animated:YES completion:nil];
    self.installationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
        repeats:YES block:^(NSTimer *timer) {
        NSString *log = [NSString stringWithContentsOfFile:self.installationLogPath
            encoding:NSUTF8StringEncoding error:nil] ?: @"";
        self.installationController.consoleText = VZInstallationConsoleText(
            self.installationLogPath);
        if ([log containsString:@"INSTALL_SUCCEEDED"]) {
            [timer invalidate];
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            self.installationController.indeterminate = NO;
            self.installationController.progress = 1.0;
            NSError *writeError = nil;
            VZWriteVMOptions(self.installationOptions,
                             self.installationBundlePath, &writeError);
            VZWriteInstallationAttempt(self.installationAttemptPath, @"complete",
                @{@"CompletedAt": NSDate.date});
            if ([VZAppSettings.sharedSettings boolForKey:VZAutoDeleteRestoreImageKey])
                VZRemovePaths(@[self.installationRestoreImagePath]);
            NSString *installedPath = [[self.installationBundlePath copy] autorelease];
            self.installationController.cancellationHandler = nil;
            [self.installationController.navigationController dismissViewControllerAnimated:YES completion:^{
                self.installationController = nil;
                self.installationTimer = nil;
                self.installationProcess = 0;
                [self presentVMLibrary];
                if (writeError) {
                    setStatus([NSString stringWithFormat:
                        VZL(@"Installed, but settings save failed: %@"), writeError]);
                    VZPresentFailureReport(self, VZL(@"Could Not Save"),
                        [NSString stringWithFormat:
                            VZL(@"Installed, but settings save failed: %@"),
                            writeError.localizedDescription],
                        writeError.debugDescription,
                        VZFailureSupportOptionNone);
                    return;
                }
                UIAlertController *success = [UIAlertController
                    alertControllerWithTitle:VZL(@"macOS Installed")
                                     message:VZL(@"The new Virtual Mac is ready to use.")
                              preferredStyle:UIAlertControllerStyleAlert];
                [success addAction:[UIAlertAction actionWithTitle:VZL(@"OK")
                    style:UIAlertActionStyleCancel handler:nil]];
                // Starting a second VZVirtualMachine in this process can
                // replace the active display plumbing and freeze the running
                // guest's framebuffer. Leave the completed VM in the library
                // and offer Start only when there is no active VM.
                if (!gVirtualMachine) {
                    [success addAction:[UIAlertAction
                        actionWithTitle:VZL(@"Start")
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                        (void)action;
                        // The installation sheet owns a mutable working copy of
                        // the configuration. Reload the durable manifest after
                        // installation so a same-session first boot receives the
                        // exact options that later library boots use, including
                        // newly introduced guest-tool feature keys.
                        NSDictionary *installedOptions =
                            VZVMOptionsForBundle(installedPath);
                        VZVMLibraryViewController *library = (id)
                            self.libraryNavigationController.viewControllers.firstObject;
                        [self vmLibrary:library bootBundleAtPath:installedPath
                                options:installedOptions];
                    }]];
                }
                [self presentViewController:success animated:YES completion:nil];
            }];
            return;
        }
        NSRange failure = [log rangeOfString:@"INSTALL_FAILED"
                                     options:NSBackwardsSearch];
        if (failure.location != NSNotFound) {
            [timer invalidate];
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            NSString *tail = [log substringFromIndex:failure.location];
            VZWriteInstallationAttempt(self.installationAttemptPath, @"failed",
                @{@"Failure": tail});
            NSString *archivePath = nil;
            if ([NSFileManager.defaultManager
                    fileExistsAtPath:self.installationStagingPath]) {
                NSDateFormatter *formatter = [[[NSDateFormatter alloc] init]
                    autorelease];
                formatter.dateFormat = @"yyyyMMdd-HHmmss";
                archivePath = [[self.installationStagingPath
                    stringByDeletingPathExtension]
                    stringByAppendingFormat:@".failed-%@",
                    [formatter stringFromDate:NSDate.date]];
                NSError *archiveError = nil;
                if (![NSFileManager.defaultManager
                        moveItemAtPath:self.installationStagingPath
                               toPath:archivePath error:&archiveError]) {
                    printf("[VirtualMac] failed to archive installer staging path: %s\n",
                           archiveError.description.UTF8String);
                    archivePath = nil;
                }
            }
            NSString *explanation = VZInstallationFailureExplanation(tail);
            self.installationController.cancellationHandler = nil;
            [self.installationController.navigationController dismissViewControllerAnimated:YES completion:^{
                self.installationController = nil;
                self.installationTimer = nil;
                self.installationProcess = 0;
                VZFailureDetailsViewController *controller =
                    [[[VZFailureDetailsViewController alloc]
                        initWithTitle:VZL(@"Installation Failed")
                        message:explanation details:tail
                        options:VZFailureSupportOptionNone]
                        autorelease];
                UINavigationController *navigation =
                    [[[UINavigationController alloc]
                        initWithRootViewController:controller] autorelease];
                navigation.modalPresentationStyle =
                    UIModalPresentationPageSheet;
                navigation.preferredContentSize = CGSizeMake(640, 720);
                [self presentViewController:navigation animated:YES
                    completion:nil];
            }];
            return;
        }
        NSRange progress = [log rangeOfString:@"INSTALL_PROGRESS\t"
                                      options:NSBackwardsSearch];
        if (progress.location != NSNotFound) {
            NSString *tail = [log substringFromIndex:NSMaxRange(progress)];
            double fraction = tail.doubleValue;
            if (fraction <= 0.0) {
                self.installationController.indeterminate = YES;
                self.installationController.statusText = VZL(@"Starting installation environment…");
                self.installationController.detailText = VZDeviceString(
                    VZL(@"The first progress value can take several minutes while the Virtual Mac changes from DFU to RestoreOS. Your iPad will remain awake."),
                    VZL(@"The first progress value can take several minutes while the Virtual Mac changes from DFU to RestoreOS. Your iPhone will remain awake."));
                return;
            }
            self.installationController.indeterminate = NO;
            self.installationController.progress = MAX(0, MIN(1, fraction));
            self.installationController.statusText = [NSString stringWithFormat:
                VZL(@"%.0f%% complete"), fraction * 100.0];
            self.installationController.detailText = VZDeviceString(
                VZL(@"Installation progress may remain unchanged while macOS prepares the next installation stage. Your iPad will remain awake."),
                VZL(@"Installation progress may remain unchanged while macOS prepares the next installation stage. Your iPhone will remain awake."));
        } else if ([log containsString:@"INSTALL_BEGIN"]) {
            self.installationController.statusText = VZL(@"Starting installation…");
        } else if ([log containsString:@"RESTORE_LOAD_OK"]) {
            self.installationController.statusText = VZL(@"Preparing virtual hardware…");
        } else if ([log containsString:@"RESTORE_LOAD_BEGIN"]) {
            self.installationController.statusText = VZL(@"Reading restore image…");
        } else if ([log containsString:@"INSTALL_PREPARE_BEGIN"]) {
            self.installationController.statusText = VZL(@"Starting installation services…");
        }
    }];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(gLastInputBoundsSize, gInputView.bounds.size)) {
        gLastInputBoundsSize = gInputView.bounds.size;
        resetPointerSession(YES);
        for (id interaction in gInputView.interactions)
            if ([interaction respondsToSelector:@selector(invalidate)])
                [interaction invalidate];
    }
    updateDisplayGeometry();
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, YES))
        [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses
           withEvent:(UIPressesEvent *)event
{
    if (!sendPresses(presses, NO))
        [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses
               withEvent:(UIPressesEvent *)event
{
    sendPresses(presses, NO);
}

- (void)virtualMachine:(id)virtualMachine didStopWithError:(NSError *)error
{
    (void)virtualMachine;
    printf("[VirtualMac] VM delegate didStopWithError=%s\n",
           error ? [[error description] UTF8String] : "(none)");
    setStatus([NSString stringWithFormat:VZL(@"Virtual Mac stopped: %@"),
                                        error.localizedDescription]);
    [self finishVMAndShowLibraryWithError:error];
}

- (void)guestDidStopVirtualMachine:(id)virtualMachine
{
    (void)virtualMachine;
    printf("[VirtualMac] VM delegate guestDidStopVirtualMachine\n");
    [self finishVMAndShowLibraryWithError:nil];
}

- (void)finishVMAndShowLibraryWithError:(NSError *)error
{
    setVMJetsamProtection(NO);
    gSoftwareKeyboardRequested = NO;
    [gGamepadBridge detachFromVirtualMachine];
    pencilVsockReset();
    disconnectExternalDisplay();
    [gDisplayLayer removeFromSuperlayer];
    gDisplayLayer = nil;
    gDisplayContainer = nil;
    gFramebuffer = nil;
    [gFramebufferView release];
    gFramebufferView = nil;
    [gVirtualMachine release];
    gVirtualMachine = nil;
    gVideoMemoryAlertPresented = NO;
    gVirtualMachineDelegate = nil;
    gKeyboard = nil;
    gShiftPressedMask = 0;
    gGlobeDown = NO;
    gPointingDevice = nil;
    resetScrollCoalescing();
    VZTrackpadScrollBridgeReset();
    gTouchButtons = 0;
    gHardwareMouseButtons = 0;
    gLastPointerButtons = NSUIntegerMax;
    gCursorView.image = nil;
    gCursorView.hidden = YES;
    gInputView.hidden = YES;
    gTouchScrollRecognizer = nil;
    gPinchRecognizer = nil;
    gRotationRecognizer = nil;
    gSmartMagnifyRecognizer = nil;
    self.activeVMBundlePath = nil;
    [self presentVMLibrary];
    if (error) {
        VZPresentFailureReport(self, VZL(@"Virtual Mac Stopped"),
            error.localizedDescription, error.debugDescription,
            VZFailureSupportOptionSuggestDebugLogging |
            VZFailureSupportOptionSuggestScreenRecording);
    }
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_libraryNavigationController release];
    _installationController.cancellationHandler = nil;
    [_installationController release];
    [_installationTimer invalidate];
    [_installationTimer release];
    [_installationLogPath release];
    [_installationBundlePath release];
    [_installationStagingPath release];
    [_installationAttemptPath release];
    [_installationRestoreImagePath release];
    [_installationOptions release];
    [_activeVMBundlePath release];
    [super dealloc];
}
@end

static CGRect aspectFitRect(CGSize contentSize, CGRect bounds) {
    if (contentSize.width <= 0 || contentSize.height <= 0 ||
        bounds.size.width <= 0 || bounds.size.height <= 0)
        return bounds;
    CGFloat scale = fmin(bounds.size.width / contentSize.width,
                         bounds.size.height / contentSize.height);
    CGSize size = CGSizeMake(contentSize.width * scale,
                             contentSize.height * scale);
    return CGRectIntegral(CGRectMake(
        CGRectGetMidX(bounds) - size.width / 2.0,
        CGRectGetMidY(bounds) - size.height / 2.0,
        size.width, size.height));
}

static CGRect aspectFillRect(CGSize contentSize, CGRect bounds) {
    if (contentSize.width <= 0 || contentSize.height <= 0 ||
        bounds.size.width <= 0 || bounds.size.height <= 0)
        return bounds;
    CGFloat scale = fmax(bounds.size.width / contentSize.width,
                         bounds.size.height / contentSize.height);
    CGSize size = CGSizeMake(contentSize.width * scale,
                             contentSize.height * scale);
    return CGRectIntegral(CGRectMake(
        CGRectGetMidX(bounds) - size.width / 2.0,
        CGRectGetMidY(bounds) - size.height / 2.0,
        size.width, size.height));
}

static CGRect displayViewportRect(CGSize contentSize, CGRect bounds) {
    BOOL fill = [[VZAppSettings.sharedSettings stringForKey:
        VZDisplayScalingKey] isEqualToString:@"fill"];
    return fill ? aspectFillRect(contentSize, bounds)
                : aspectFitRect(contentSize, bounds);
}

static void updateExternalCursorForNormalizedLocation(CGPoint location)
{
    if (!gExternalCursorView || !gExternalWindow ||
        !gCursorView.image || gCursorView.hidden)
        return;
    if (!isfinite(location.x) || !isfinite(location.y))
        location = CGPointMake(0.5, 0.5);
    location.x = fmin(1.0, fmax(0.0, location.x));
    location.y = fmin(1.0, fmax(0.0, location.y));
    CGRect viewport = aspectFitRect(gDisplayPixelSize,
                                    gExternalWindow.bounds);
    CGFloat scaleX = viewport.size.width / gDisplayPixelSize.width;
    CGFloat scaleY = viewport.size.height / gDisplayPixelSize.height;
    CGSize size = CGSizeMake(gCursorPixelSize.width * scaleX,
                             gCursorPixelSize.height * scaleY);
    CGPoint origin = CGPointMake(
        viewport.origin.x + location.x * viewport.size.width -
            gCursorHotspot.x * scaleX,
        viewport.origin.y + location.y * viewport.size.height -
            gCursorHotspot.y * scaleY);
    gExternalCursorView.image = gCursorView.image;
    gExternalCursorView.hidden = NO;
    gExternalCursorView.frame = (CGRect){origin, size};
}

static void updateDisplayGeometry(void) {
    static CGRect lastViewport = {{NAN, NAN}, {NAN, NAN}};
    static CGSize lastContainer = {NAN, NAN};
    if (!gDisplayContainer)
        return;
    CGRect viewport = displayViewportRect(gDisplayPixelSize,
                                          gDisplayContainer.bounds);
    if (gDisplayLayer)
        gDisplayLayer.frame = viewport;
    if (gInputView)
        gInputView.frame = gExternalWindow
            ? gDisplayContainer.bounds : viewport;
    if (!CGRectEqualToRect(viewport, lastViewport) ||
        !CGSizeEqualToSize(gDisplayContainer.bounds.size, lastContainer)) {
        printf("[VirtualMac] display viewport %.0fx%.0f at %.0f,%.0f "
               "guest=%.0fx%.0f container=%.0fx%.0f\n",
               viewport.size.width, viewport.size.height,
               viewport.origin.x, viewport.origin.y,
               gDisplayPixelSize.width, gDisplayPixelSize.height,
               gDisplayContainer.bounds.size.width,
               gDisplayContainer.bounds.size.height);
        lastViewport = viewport;
        lastContainer = gDisplayContainer.bounds.size;
    }
}

static void setStatus(NSString *status) {
    printf("[VirtualMac] %s\n", [status UTF8String]);
    if (!gStatusLabel)
        return;
    // Boot status is diagnostic-only and hidden by default. Avoid crossing
    // UIKit objects between the iPadOS 14 VZ worker and the main thread.
    if (!pthread_main_np())
        return;
    gStatusLabel.text = status;
}

static void traceFrameUpdate(id self, SEL selector, id framebuffer,
                             VZFrameUpdateSharedPtr update) {
    uint64_t count = __sync_add_and_fetch(&gFrameUpdateCount, 1);
    const VZFrameUpdateSharedPtr *shared = update.object;
    if (count <= 3 || (gDebugLogging && count % 300 == 0))
        printf("[VirtualMac] PVG frame=%llu framebuffer=%p update=%p control=%p\n",
               (unsigned long long)count, framebuffer,
               shared ? shared->object : NULL,
               shared ? shared->control : NULL);
    ((void(*)(id, SEL, id, VZFrameUpdateSharedPtr))gOriginalFrameUpdate)(
        self, selector, framebuffer, update);
    // Mirror rendered frame to external display.
    if (gExternalMirrorView && gDisplayLayer)
        gExternalMirrorView.layer.contents = gDisplayLayer.contents;
}

static UIImage *copyCursorImage(const uint8_t *cursor) {
    const void *pixels = *(const void *const *)(cursor + 0);
    uint32_t width = *(const uint32_t *)(cursor + 8);
    uint32_t height = *(const uint32_t *)(cursor + 12);
    uint32_t bytesPerPixel = *(const uint32_t *)(cursor + 16);
    if (!pixels || width == 0 || height == 0 || bytesPerPixel != 4 ||
        width > 4096 || height > 4096)
        return nil;
    size_t bytesPerRow = (size_t)width * bytesPerPixel;
    if (bytesPerRow > SIZE_MAX / height)
        return nil;
    CFDataRef data = CFDataCreate(
        kCFAllocatorDefault, pixels, (CFIndex)(bytesPerRow * height));
    CGDataProviderRef provider = data
        ? CGDataProviderCreateWithCFData(data) : NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = provider && colorSpace
        ? CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace,
                        (CGBitmapInfo)0x2004, provider, NULL, false,
                        kCGRenderingIntentDefault)
        : NULL;
    UIImage *result = image ? [[UIImage alloc] initWithCGImage:image] : nil;
    if (image)
        CGImageRelease(image);
    if (colorSpace)
        CGColorSpaceRelease(colorSpace);
    if (provider)
        CGDataProviderRelease(provider);
    if (data)
        CFRelease(data);
    return result;
}

static void updateCursorOverlay(VZFrameUpdateSharedPtr update) {
    // Clang passes this non-trivial C++ shared_ptr parameter indirectly even
    // though the Objective-C type encoding describes its two pointer fields.
    const VZFrameUpdateSharedPtr *shared = update.object;
    const uint8_t *cursor = shared ? shared->object : NULL;
    if (!cursor || !gCursorView)
        return;
    BOOL imageChanged = *(const uint8_t *)(cursor + 40) != 0;
    BOOL imagePresent = *(const uint8_t *)(cursor + 32) != 0;
    uint32_t width = *(const uint32_t *)(cursor + 8);
    uint32_t height = *(const uint32_t *)(cursor + 12);
    uint32_t hotspotX = *(const uint32_t *)(cursor + 24);
    uint32_t hotspotY = *(const uint32_t *)(cursor + 28);
    uint32_t guestX = *(const uint32_t *)(cursor + 48);
    uint32_t guestY = *(const uint32_t *)(cursor + 52);
    UIImage *image = imageChanged && imagePresent
        ? copyCursorImage(cursor) : nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (imageChanged) {
            gCursorView.image = image;
            gCursorView.hidden = image == nil ||
                gCursorSuppressedForDirectTouch;
            if (gExternalCursorView && gCursorView.hidden)
                gExternalCursorView.hidden = YES;
            gCursorPixelSize = image
                ? CGSizeMake(width, height) : CGSizeZero;
            gCursorHotspot = image
                ? CGPointMake(hotspotX, hotspotY) : CGPointZero;
        }
        CGRect inputViewport = displayViewportRect(
            gDisplayPixelSize, gInputView.bounds);
        CGFloat scaleX = inputViewport.size.width / gDisplayPixelSize.width;
        CGFloat scaleY = inputViewport.size.height / gDisplayPixelSize.height;
        CGSize size = CGSizeMake(gCursorPixelSize.width * scaleX,
                                 gCursorPixelSize.height * scaleY);
        CGPoint origin = CGPointMake(
            gInputView.frame.origin.x + inputViewport.origin.x +
                ((CGFloat)guestX - gCursorHotspot.x) * scaleX,
            gInputView.frame.origin.y + inputViewport.origin.y +
                ((CGFloat)guestY - gCursorHotspot.y) * scaleY);
        // A just-sent host pointer event is newer than this asynchronous PVG
        // callback. Keep the predicted position briefly; a subsequent guest
        // update reconciles it without the cursor jumping one frame backward.
        if (CACurrentMediaTime() - gLastPredictedCursorTime >= 0.05)
            gCursorView.frame = (CGRect){origin, size};
        updateExternalCursorForNormalizedLocation(CGPointMake(
            gDisplayPixelSize.width > 0 ? guestX / gDisplayPixelSize.width : 0,
            gDisplayPixelSize.height > 0 ? guestY / gDisplayPixelSize.height : 0));
        [image release];
    });
}

static void traceCursorUpdate(id self, SEL selector, id framebuffer,
                              VZFrameUpdateSharedPtr update) {
    uint64_t count = __sync_add_and_fetch(&gCursorUpdateCount, 1);
    if (count <= 8 || (gDebugLogging && count % 300 == 0)) {
        const VZFrameUpdateSharedPtr *shared = update.object;
        const uint8_t *cursor = shared ? shared->object : NULL;
        printf("[VirtualMac] PVG cursor=%llu pos=%u,%u image-change=%d "
               "image=%d size=%ux%u\n",
               (unsigned long long)count,
               cursor ? *(const uint32_t *)(cursor + 48) : 0,
               cursor ? *(const uint32_t *)(cursor + 52) : 0,
               cursor ? *(const uint8_t *)(cursor + 40) != 0 : 0,
               cursor ? *(const uint8_t *)(cursor + 32) != 0 : 0,
               cursor ? *(const uint32_t *)(cursor + 8) : 0,
               cursor ? *(const uint32_t *)(cursor + 12) : 0);
    }
    updateCursorOverlay(update);
    ((void(*)(id, SEL, id, VZFrameUpdateSharedPtr))gOriginalCursorUpdate)(
        self, selector, framebuffer, update);
}

static BOOL installFramebufferTrace(void) {
    Class framebufferViewClass = objc_getClass("_VZFramebufferView");
    Method method = class_getInstanceMethod(
        framebufferViewClass, S("framebuffer:didUpdateFrame:"));
    if (!method)
        return NO;
    IMP frameImplementation = method_getImplementation(method);
    if (frameImplementation != (IMP)&traceFrameUpdate) {
        gOriginalFrameUpdate = method_setImplementation(
            method, (IMP)&traceFrameUpdate);
    } else if (!gOriginalFrameUpdate) {
        printf("[VirtualMac] frame callback already traced without original\n");
        return NO;
    }
    Method cursorMethod = class_getInstanceMethod(
        framebufferViewClass, S("framebuffer:didUpdateCursor:"));
    if (cursorMethod) {
        IMP cursorImplementation = method_getImplementation(cursorMethod);
        if (cursorImplementation != (IMP)&traceCursorUpdate) {
            gOriginalCursorUpdate = method_setImplementation(
                cursorMethod, (IMP)&traceCursorUpdate);
        } else if (!gOriginalCursorUpdate) {
            printf("[VirtualMac] cursor callback already traced without original\n");
            return NO;
        }
        printf("[VirtualMac] cursor callback type=%s original=%p trace=%p\n",
               method_getTypeEncoding(cursorMethod), gOriginalCursorUpdate,
               (void *)&traceCursorUpdate);
    }
    printf("[VirtualMac] frame callback type=%s original=%p trace=%p\n",
           method_getTypeEncoding(method), gOriginalFrameUpdate,
           (void *)&traceFrameUpdate);
    return gOriginalFrameUpdate != NULL && gOriginalCursorUpdate != NULL;
}

static void logFramebufferState(id view, id framebuffer, const char *phase) {
    Ivar rateIvar = class_getInstanceVariable(
        object_getClass(framebuffer), "_currentFrameRate");
    Ivar observersIvar = class_getInstanceVariable(
        object_getClass(framebuffer), "_observers");
    Ivar lastFrameIvar = class_getInstanceVariable(
        object_getClass(framebuffer), "_lastFrameUpdate");
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)framebuffer;
    uint64_t rate = *(const uint64_t *)(bytes + ivar_getOffset(rateIvar));
    const void *const *observers =
        (const void *const *)(bytes + ivar_getOffset(observersIvar));
    const void *const *lastFrame =
        (const void *const *)(bytes + ivar_getOffset(lastFrameIvar));
    NSUInteger observerCount = observers[0] && observers[1]
        ? ((const uint8_t *)observers[1] - (const uint8_t *)observers[0]) / 16
        : 0;
    printf("[VirtualMac] framebuffer state %s window=%p rate=%llu "
           "observers=%lu [%p,%p) lastFrame=%p/%p\n",
           phase, m0(view, "window"), (unsigned long long)rate,
           (unsigned long)observerCount, observers[0], observers[1],
           lastFrame[0], lastFrame[1]);
}

// VZVirtualMachine owns a libc++ unordered_map of host RPC callbacks at
// ivar offset 0x98 in the extracted 22D68 framework. Keep this diagnostic
// alongside the port so a device run can prove that the stock
// process_frame_update callback survived construction and start.
static void dumpRPCHandlers(id virtualMachine, const char *phase) {
    const uint8_t *vm = (const uint8_t *)(__bridge const void *)virtualMachine;
    const uint8_t *table = *(const uint8_t *const *)(vm + 0x98);
    if (!table) {
        printf("[VirtualMac] RPC handlers %s table=NULL\n", phase);
        return;
    }

    const void *buckets = *(const void *const *)(table + 0x0);
    uint64_t bucketCount = *(const uint64_t *)(table + 0x8);
    const uint8_t *node = *(const uint8_t *const *)(table + 0x10);
    uint64_t declaredCount = *(const uint64_t *)(table + 0x18);
    printf("[VirtualMac] RPC handlers %s table=%p buckets=%p "
           "bucketCount=%llu declaredCount=%llu head=%p\n",
           phase, table, buckets,
           (unsigned long long)bucketCount,
           (unsigned long long)declaredCount, node);

    for (uint64_t i = 0; node && i < declaredCount && i < 64; i++) {
        int8_t discriminator = *(const int8_t *)(node + 0x27);
        const char *name;
        uint64_t length;
        if (discriminator < 0) {
            name = *(const char *const *)(node + 0x10);
            length = *(const uint64_t *)(node + 0x18);
        } else {
            name = (const char *)(node + 0x10);
            length = (uint8_t)discriminator;
        }
        printf("[VirtualMac] RPC handler[%llu] node=%p hash=0x%llx "
               "name=%.*s callback=%p\n",
               (unsigned long long)i, node,
               (unsigned long long)*(const uint64_t *)(node + 0x8),
               (int)length, name,
               *(const void *const *)(node + 0x40));
        node = *(const uint8_t *const *)node;
    }
}

static BOOL loadExtractedFrameworks(void) {
    NSString *hookPath =
        [NSBundle.mainBundle pathForResource:@"VZHostCompat"
                                      ofType:@"dylib"];
    void *hook = hookPath
        ? dlopen([hookPath fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL)
        : NULL;
    if (!hook) {
        printf("[VirtualMac] dlopen host hook FAILED: %s\n", dlerror());
        return NO;
    }
    printf("[VirtualMac] loaded host hook: %s\n",
           [hookPath fileSystemRepresentation]);

    const char *images[] = {
        "/var/root/VirtualMac/payload/Frameworks/vmnet.framework/vmnet",
        "/var/root/VirtualMac/payload/Frameworks/Hypervisor.framework/Hypervisor",
        "/var/root/VirtualMac/payload/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics",
        "/var/root/VirtualMac/payload/Frameworks/Virtualization.framework/Virtualization",
    };
    for (NSUInteger i = 0; i < sizeof(images) / sizeof(images[0]); i++) {
        if (!dlopen(images[i], RTLD_NOW | RTLD_GLOBAL)) {
            printf("[VirtualMac] dlopen %s FAILED: %s\n", images[i], dlerror());
            return NO;
        }
    }

    Method start = class_getInstanceMethod(
        objc_getClass("VZVirtualMachine"),
        sel_registerName("startWithCompletionHandler:"));
    Dl_info virtualizationInfo = {0};
    dladdr((const void *)method_getImplementation(start), &virtualizationInfo);
    printf("[VirtualMac] VZ image=%p (%s)\n",
           virtualizationInfo.dli_fbase,
           virtualizationInfo.dli_fname ?: "?");
    if (!virtualizationInfo.dli_fbase)
        return NO;
    int (*rebindVirtualization)(void *) =
        (int(*)(void *))dlsym(hook, "vz_rebind_virtualization");
    gHostVMStarted = (void(*)(void))dlsym(hook, "vz_host_vm_started");
    int rebindResult = rebindVirtualization
        ? rebindVirtualization(virtualizationInfo.dli_fbase)
        : -1;
    printf("[VirtualMac] authenticated VZ rebind=%p result=%d\n",
           rebindVirtualization, rebindResult);
    if (rebindResult != 0 || !gHostVMStarted)
        return NO;
    return installFramebufferTrace();
}

static void configureAudio(id configuration, NSDictionary *options) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"VZDisableAudio"]) {
        printf("[VirtualMac] audio disabled by VZDisableAudio\n");
        return;
    }

    // Ventura's native macOS VM configuration uses virtio-sound with host
    // stream attachments. Use the same path for playback and microphone input.
    BOOL outputEnabled = [options[@"AudioOutputEnabled"] boolValue];
    BOOL inputEnabled = [options[@"AudioInputEnabled"] boolValue];
    if (!outputEnabled && !inputEnabled) {
        printf("[VirtualMac] audio disabled by VM configuration\n");
        return;
    }
    id sink = outputEnabled ? NEW("VZHostAudioOutputStreamSink") : nil;
    id output = outputEnabled
        ? NEW("VZVirtioSoundDeviceOutputStreamConfiguration") : nil;
    id source = inputEnabled ? NEW("VZHostAudioInputStreamSource") : nil;
    id input = inputEnabled
        ? NEW("VZVirtioSoundDeviceInputStreamConfiguration") : nil;
    id sound = NEW("VZVirtioSoundDeviceConfiguration");
    if ((outputEnabled && (!sink || !output)) ||
        (inputEnabled && (!source || !input)) || !sound) {
        printf("[VirtualMac] virtio audio classes unavailable sink=%p output=%p "
               "source=%p input=%p device=%p\n",
               sink, output, source, input, sound);
        return;
    }
    NSMutableArray *streams = [NSMutableArray array];
    if (inputEnabled) {
        setObj(input, "setSource:", source);
        [streams addObject:input];
    }
    if (outputEnabled) {
        setObj(output, "setSink:", sink);
        [streams addObject:output];
    }
    setObj(sound, "setStreams:", streams);
    setObj(configuration, "setAudioDevices:", @[sound]);
    printf("[VirtualMac] configured virtio audio output=%d/%p input=%d/%p\n",
           outputEnabled, sink, inputEnabled, source);
}

static BOOL videoToolboxAcceleratorSupported(id self, SEL selector) {
    (void)self;
    (void)selector;
    return YES;
}

static void configureVideoToolbox(id configuration, NSDictionary *options) {
    if (![options[@"VideoToolboxEnabled"] boolValue]) {
        printf("[VirtualMac] VideoToolbox accelerator disabled by VM configuration\n");
        return;
    }
    Class deviceClass = CLS("_VZMacVideoToolboxDeviceConfiguration");
    SEL supportedSelector = S("_isSupported");
    BOOL nativePredicate = deviceClass &&
        [deviceClass respondsToSelector:supportedSelector] &&
        ((BOOL(*)(id, SEL))objc_msgSend)(deviceClass, supportedSelector);
    if (!deviceClass) {
        printf("[VirtualMac] VideoToolbox accelerator class unavailable\n");
        return;
    }
    // The extracted framework's predicate resolves its weak VideoToolbox
    // imports in this UIKit host process, where iPadOS's system VideoToolbox
    // lacks the three Mac host-session exports. The VMM has our matching
    // extracted implementation, so make the configuration predicate describe
    // the actual child runtime before both init and validation consult it.
    Method supportedMethod = class_getClassMethod(deviceClass,
                                                  supportedSelector);
    if (supportedMethod)
        method_setImplementation(supportedMethod,
                                 (IMP)videoToolboxAcceleratorSupported);
    id device = NEW("_VZMacVideoToolboxDeviceConfiguration");
    if (!device ||
        ![configuration respondsToSelector:S("_setAcceleratorDevices:")]) {
        printf("[VirtualMac] VideoToolbox accelerator construction failed device=%p\n",
               device);
        [device release];
        return;
    }
    setObj(configuration, "_setAcceleratorDevices:", @[device]);
    printf("[VirtualMac] configured native VideoToolbox accelerator=%p "
           "original-supported=%d\n", device, nativePredicate);
    [device release];
}

// The iOS 18 SDK removed AVAudioSessionCategoryOptionAllowBluetoothHFP from
// the public headers, but the option bit (0x80) remains valid on the iPadOS
// 14-16 targets this app runs on, where the audio session still accepts it.
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
#define VZAVSessionOptionAllowBluetoothHFP 0x80
#else
#define VZAVSessionOptionAllowBluetoothHFP \
    AVAudioSessionCategoryOptionAllowBluetoothHFP
#endif

static void requestMicrophoneAccess(dispatch_block_t continuation) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    AVAudioSessionRecordPermission permission = session.recordPermission;
    printf("[VirtualMac] microphone permission before request=%lu\n",
           (unsigned long)permission);
    NSError *sessionError = nil;
    AVAudioSessionCategoryOptions sessionOptions =
        AVAudioSessionCategoryOptionMixWithOthers |
        AVAudioSessionCategoryOptionDefaultToSpeaker |
        VZAVSessionOptionAllowBluetoothHFP;
    BOOL categoryOK = [session
        setCategory:AVAudioSessionCategoryPlayAndRecord
               mode:AVAudioSessionModeDefault
            options:sessionOptions error:&sessionError];
    BOOL activeOK = [session setActive:YES error:&sessionError];
    printf("[VirtualMac] audio session category=%d active=%d error=%s\n",
           categoryOK, activeOK,
           sessionError ? sessionError.localizedDescription.UTF8String
                        : "none");
    if (permission != AVAudioSessionRecordPermissionUndetermined) {
        continuation();
        return;
    }

    // The host audio source is created by Virtualization only after VM setup.
    // Ask under the visible application bundle first so TCC attributes capture
    // to Virtual Mac instead of silently giving its private VMM child zeros.
    __block BOOL continued = NO;
    void (^finish)(BOOL, const char *) = ^(BOOL granted, const char *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (continued)
                return;
            continued = YES;
            printf("[VirtualMac] microphone permission granted=%d via=%s\n",
                   granted, reason);
            continuation();
        });
    };
    [session requestRecordPermission:^(BOOL granted) {
        finish(granted, "TCC callback");
    }];
    // A platform-installed app on iPadOS can fail to receive a
    // TCC callback. Never make the VM library depend indefinitely on it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        finish(NO, "timeout");
    });
}

static void configureNetwork(id configuration, NSDictionary *options) {
    NSString *mode = options[@"NetworkMode"] ?: @"NAT";
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 &&
        [mode isEqualToString:@"Bridge"]) {
        // The iPadOS 14 Wi-Fi stack cannot register a second station MAC for
        // a guest. Treat legacy configurations as NAT; newer hosts retain the
        // existing bridged-network implementation unchanged.
        printf("[VirtualMac] bridged networking is unavailable on iPadOS 14; using NAT\n");
        mode = @"NAT";
    }
    if ([mode isEqualToString:@"Disabled"] ||
        [NSUserDefaults.standardUserDefaults boolForKey:@"VZDisableNetwork"]) {
        printf("[VirtualMac] network disabled\n");
        return;
    }

    id attachment = nil;
    if ([mode isEqualToString:@"Bridge"]) {
        NSString *identifier = options[@"BridgeInterface"] ?: @"en0";
        NSArray *interfaces = ((id(*)(id, SEL))objc_msgSend)(
            CLS("VZBridgedNetworkInterface"), S("networkInterfaces"));
        id selected = nil;
        for (id candidate in interfaces) {
            NSString *candidateIdentifier = [candidate valueForKey:@"identifier"];
            if ([candidateIdentifier isEqualToString:identifier]) {
                selected = candidate;
                break;
            }
        }
        if (selected) {
            attachment = ((id(*)(id, SEL, id))objc_msgSend)(
                m0(CLS("VZBridgedNetworkDeviceAttachment"), "alloc"),
                S("initWithInterface:"), selected);
        }
        printf("[VirtualMac] bridge request interface=%s available=%s selected=%p\n",
               identifier.UTF8String, interfaces.description.UTF8String,
               selected);
    } else {
        attachment = NEW("VZNATNetworkDeviceAttachment");
    }
    id network = NEW("VZVirtioNetworkDeviceConfiguration");
    if (!attachment || !network) {
        printf("[VirtualMac] virtio NAT classes unavailable attachment=%p "
               "device=%p\n", attachment, network);
        return;
    }
    // Keep the guest NIC identity stable across app launches. The framework's
    // default is valid but randomly generated for every new configuration.
    NSString *macString = options[@"MACAddress"];
    id macAddress = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMACAddress"), "alloc"), S("initWithString:"),
        macString);
    if (!macAddress) {
        macAddress = [m0(CLS("VZMACAddress"),
            "randomLocallyAdministeredAddress") retain];
        macString = [[macAddress valueForKey:@"string"] description];
    }
    setObj(network, "setMACAddress:", macAddress);
    setObj(network, "setAttachment:", attachment);
    setObj(configuration, "setNetworkDevices:", @[network]);
    printf("[VirtualMac] configured virtio %s network attachment=%p mac=%s\n",
           mode.UTF8String, attachment,
           [[[macAddress valueForKey:@"string"] description]
                            UTF8String]);
}

static void configureDirectorySharing(id configuration,
                                      NSDictionary *options) {
    NSArray *shares = options[@"SharedDirectories"];
    if (![shares isKindOfClass:NSArray.class] || shares.count == 0)
        return;
    NSMutableDictionary *directories = [NSMutableDictionary dictionary];
    for (NSDictionary *saved in shares) {
        NSString *path = saved[@"Path"];
        if (![path isKindOfClass:NSString.class] || !path.length)
            continue;
        id directory = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
            m0(CLS("VZSharedDirectory"), "alloc"),
            S("initWithURL:readOnly:"), fileURL(path),
            [saved[@"ReadOnly"] boolValue]);
        if (!directory)
            continue;
        NSString *baseName = path.lastPathComponent.length
            ? path.lastPathComponent : VZL(@"Shared Folder");
        NSString *name = baseName;
        for (NSUInteger suffix = 2; directories[name]; suffix++)
            name = [NSString stringWithFormat:@"%@ %lu", baseName,
                    (unsigned long)suffix];
        directories[name] = directory;
    }
    if (!directories.count)
        return;
    id share = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMultipleDirectoryShare"), "alloc"),
        S("initWithDirectories:"), directories);
    id fileSystemClass = CLS("VZVirtioFileSystemDeviceConfiguration");
    NSString *tag = m0(fileSystemClass, "macOSGuestAutomountTag");
    id device = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(fileSystemClass, "alloc"), S("initWithTag:"), tag);
    if (!share || !device)
        return;
    setObj(device, "setShare:", share);
    setObj(configuration, "setDirectorySharingDevices:", @[device]);
    printf("[VirtualMac] configured directory shares count=%lu tag=%s names=%s\n",
           (unsigned long)directories.count, tag.UTF8String,
           directories.allKeys.description.UTF8String);
}

static id makeConfiguration(NSString *bundlePath, NSDictionary *options,
                            NSError **error) {
    BOOL guestToolsEnabled =
        [options[VZVirtualMacGuestToolsEnabledKey] boolValue];
    BOOL runtimePolicyEnabled = guestToolsEnabled &&
        [options[VZOpenGLAccelerationEnabledKey] boolValue];
    BOOL guestToolsRemovalPending =
        [options[VZGuestToolsRemovalPendingKey] boolValue];
#if EXPERIMENT_GDB_DEBUG
    BOOL externalKernelDebug = [[NSFileManager defaultManager]
        fileExistsAtPath:@"/tmp/vz-external-kernel-debug"];
#endif
    id platform = NEW("VZMacPlatformConfiguration");
    id auxiliaryStorage = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMacAuxiliaryStorage"), "alloc"),
        S("initWithContentsOfURL:"),
        fileURL([bundlePath stringByAppendingPathComponent:@"AuxiliaryStorage"]));
    NSError *bootArgumentError = nil;
    if (!VZGuestToolsConfigureBootArguments(auxiliaryStorage,
        guestToolsEnabled || guestToolsRemovalPending,
        runtimePolicyEnabled,
        &bootArgumentError))
        fprintf(stderr, "[GuestTools] NVRAM update failed: %s\n",
                bootArgumentError.localizedDescription.UTF8String);
    setObj(platform, "setAuxiliaryStorage:", auxiliaryStorage);

    NSData *hardwareModelData = [NSData dataWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"HardwareModel"]];
    id hardwareModel = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMacHardwareModel"), "alloc"),
        S("initWithDataRepresentation:"), hardwareModelData);
    if (!hardwareModel ||
        !((BOOL(*)(id, SEL))objc_msgSend)(hardwareModel, S("isSupported"))) {
        printf("[VirtualMac] unsupported hardware model\n");
        return nil;
    }
    setObj(platform, "setHardwareModel:", hardwareModel);

    NSData *machineIdentifierData = [NSData dataWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"MachineIdentifier"]];
    id machineIdentifier = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZMacMachineIdentifier"), "alloc"),
        S("initWithDataRepresentation:"), machineIdentifierData);
    setObj(platform, "setMachineIdentifier:", machineIdentifier);

    id configuration = NEW("VZVirtualMachineConfiguration");
    setObj(configuration, "setPlatform:", platform);
    NSUInteger hostCPUCount = NSProcessInfo.processInfo.activeProcessorCount;
    NSUInteger cpuCount = [options[@"CPUCount"] unsignedIntegerValue];
    cpuCount = MAX((NSUInteger)2, MIN(cpuCount, hostCPUCount));
    uint64_t physicalMemory = NSProcessInfo.processInfo.physicalMemory;
    uint64_t memoryLimit = MAX((2ULL << 30),
        (physicalMemory >> 30) << 30);
    uint64_t memorySize = [options[@"MemorySize"] unsignedLongLongValue];
    memorySize = MAX((2ULL << 30), MIN(memorySize, memoryLimit));
    ((void(*)(id, SEL, NSUInteger))objc_msgSend)(
        configuration, S("setCPUCount:"), cpuCount);
    ((void(*)(id, SEL, unsigned long long))objc_msgSend)(
        configuration, S("setMemorySize:"), memorySize);
    printf("[VirtualMac] configured guest cpus=%lu host-active-cpus=%lu "
           "memory=%lluMiB\n",
           (unsigned long)cpuCount, (unsigned long)hostCPUCount,
           memorySize >> 20);
    setObj(configuration, "setBootLoader:", NEW("VZMacOSBootLoader"));

    NSString *displayMode = options[@"DisplayMode"];
    BOOL storedDisplay = [displayMode isEqualToString:@"Custom"] ||
        [displayMode isEqualToString:@"Fixed"];
    BOOL landscapeDisplay = [displayMode isEqualToString:
        @"LandscapeNativeRetina"];
    BOOL portraitDisplay = [displayMode isEqualToString:
        @"PortraitNativeRetina"];
    BOOL externalDisplay = [displayMode isEqualToString:
        @"ExternalDisplay"];
    BOOL startupWindowDisplay = [displayMode isEqualToString:
        @"WindowSizeAtStartup"];
    NSString *widthKey = startupWindowDisplay
        ? @"_HostWindowPixelWidth"
        : externalDisplay ? @"_ExternalScreenPixelWidth"
        : landscapeDisplay ? @"_BuiltInLandscapePixelWidth"
        : portraitDisplay ? @"_BuiltInPortraitPixelWidth"
                          : @"_ActiveScreenPixelWidth";
    NSString *heightKey = startupWindowDisplay
        ? @"_HostWindowPixelHeight"
        : externalDisplay ? @"_ExternalScreenPixelHeight"
        : landscapeDisplay ? @"_BuiltInLandscapePixelHeight"
        : portraitDisplay ? @"_BuiltInPortraitPixelHeight"
                          : @"_ActiveScreenPixelHeight";
    NSInteger displayWidth = storedDisplay
        ? [options[@"DisplayWidth"] integerValue]
        : [options[widthKey] integerValue];
    NSInteger displayHeight = storedDisplay
        ? [options[@"DisplayHeight"] integerValue]
        : [options[heightKey] integerValue];
    NSString *ppiKey = startupWindowDisplay
        ? @"_HostWindowPixelsPerInch"
        : externalDisplay ? @"_ExternalScreenPixelsPerInch"
        : landscapeDisplay || portraitDisplay
            ? @"_BuiltInScreenPixelsPerInch"
            : @"_ActiveScreenPixelsPerInch";
    NSInteger pixelsPerInch = storedDisplay
        ? [options[@"DisplayPixelsPerInch"] integerValue]
        : [options[ppiKey] integerValue];
    // A narrow Slide Over window can be smaller than the editor's 800-pixel
    // custom minimum. Preserve its exact startup size; the other modes retain
    // the established guard against malformed configuration files.
    NSInteger minimumDimension = startupWindowDisplay ? 1 : 800;
    displayWidth = MAX(minimumDimension, MIN(7680, displayWidth));
    displayHeight = MAX(minimumDimension, MIN(7680, displayHeight));
    pixelsPerInch = MAX(72, MIN(600, pixelsPerInch));
    gDisplayPixelSize = CGSizeMake(displayWidth, displayHeight);
    printf("[VirtualMac] configured guest display %ldx%ld at %ld ppi "
           "mode=%s active-screen=%s startup-window=%sx%s\n",
           (long)displayWidth, (long)displayHeight,
           (long)pixelsPerInch, displayMode.UTF8String,
           [options[@"_ActiveScreenDescription"] UTF8String],
           [options[@"_HostWindowPixelWidth"] stringValue].UTF8String,
           [options[@"_HostWindowPixelHeight"] stringValue].UTF8String);
    id graphics = NEW("VZMacGraphicsDeviceConfiguration");
    id display = ((id(*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(
        m0(CLS("VZMacGraphicsDisplayConfiguration"), "alloc"),
        S("initWithWidthInPixels:heightInPixels:pixelsPerInch:"),
        displayWidth, displayHeight, pixelsPerInch);
    setObj(graphics, "setDisplays:", @[display]);
    setObj(configuration, "setGraphicsDevices:", @[graphics]);

    id attachment = ((id(*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
        m0(CLS("VZDiskImageStorageDeviceAttachment"), "alloc"),
        S("initWithURL:readOnly:error:"),
        fileURL([bundlePath stringByAppendingPathComponent:@"Disk.img"]),
        NO, error);
    if (!attachment)
        return nil;
    id blockDevice = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZVirtioBlockDeviceConfiguration"), "alloc"),
        S("initWithAttachment:"), attachment);
    setObj(configuration, "setStorageDevices:", @[blockDevice]);

    // Monterey requires the older USB keyboard and absolute USB mouse guest devices.
    NSString *keyboardChoice = options[@"KeyboardDevice"];
    BOOL useUSBKeyboard = [keyboardChoice isEqualToString:@"USBKeyboard"];
    id keyboard = useUSBKeyboard
        ? NEW("VZUSBKeyboardConfiguration")
        : NEW("_VZMacKeyboardConfiguration");
    NSString *pointingChoice = options[@"PointingDevice"];
    BOOL useUSBMouse = [pointingChoice isEqualToString:@"USBMouse"];
    id pointing = useUSBMouse
        ? NEW("VZUSBScreenCoordinatePointingDeviceConfiguration")
        : NEW("VZMacTrackpadConfiguration");
    if (keyboard)
        setObj(configuration, "setKeyboards:", @[keyboard]);
    if (pointing)
        setObj(configuration, "setPointingDevices:", @[pointing]);
    printf("[VirtualMac] configured keyboard device=%s class=%s\n",
           useUSBKeyboard ? "USB Keyboard" : "Mac Keyboard",
           keyboard ? object_getClassName(keyboard) : "(unavailable)");
    printf("[VirtualMac] configured pointing device=%s class=%s\n",
           useUSBMouse ? "USB Mouse" : "Mac Trackpad",
           pointing ? object_getClassName(pointing) : "(unavailable)");
    configureAudio(configuration, options);
    configureVideoToolbox(configuration, options);
    configureNetwork(configuration, options);
    configureDirectorySharing(configuration, options);

#if EXPERIMENT_GDB_DEBUG
    if (!VZGuestRuntimePolicyConfigureDebugStub(configuration,
            externalKernelDebug)) {
        if (error) *error = [NSError errorWithDomain:@"VirtualMac" code:7
            userInfo:@{NSLocalizedDescriptionKey:
                VZL(@"The Virtual Mac configuration could not be created.")}];
        return nil;
    }
#endif

    // Keep the stock VM device set when tools are disabled. Add the console
    // only while tools are active or for the single cleanup boot requested by
    // an explicit transition from on to off.
    if (guestToolsEnabled || guestToolsRemovalPending)
        VZGuestToolsConfigureDevice(configuration);

    BOOL pencilVsock = [options[VZApplePencilPressureTiltEnabledKey] boolValue];
    BOOL gamepadRelayEnabled = [VZAppSettings.sharedSettings boolForKey:
        VZGamepadRelayEnabledKey];
    NSString *gamepadTransport = [VZAppSettings.sharedSettings stringForKey:
        VZGamepadTransportKey];
    BOOL gamepadVsock = gamepadRelayEnabled &&
        ![gamepadTransport isEqualToString:VZGamepadTransportUDP];
    if (pencilVsock || gamepadVsock) {
        // Guest Tools, Pencil and gamepad relay share one Virtio socket device
        // and distinguish services by port. Never publish duplicate devices.
        NSArray *socketDevices = [configuration respondsToSelector:
            S("socketDevices")] ? m0(configuration, "socketDevices") : nil;
        id socketDevice = socketDevices.count ? nil
            : NEW("VZVirtioSocketDeviceConfiguration");
        if (socketDevice) {
            setObj(configuration, "setSocketDevices:", @[socketDevice]);
            printf("[VirtualMac] configured shared vsock device pencil=%d gamepad=%d\n",
                   pencilVsock, gamepadVsock);
        }
    }

    return configuration;
}

static BOOL prepareFramebuffer(UIView *container) {
    NSArray *graphicsDevices = m0(gVirtualMachine, "_graphicsDevices");
    id graphicsDevice = [graphicsDevices firstObject];
    NSArray *framebuffers = graphicsDevice ? m0(graphicsDevice, "framebuffers") : nil;
    id framebuffer = [framebuffers firstObject];
    printf("[VirtualMac] graphicsDevices=%s framebuffers=%s\n",
           [[graphicsDevices description] UTF8String],
           [[framebuffers description] UTF8String]);
    if (!framebuffer) {
        setStatus(VZL(@"Virtual Mac has no published framebuffer"));
        return NO;
    }

    Class framebufferViewClass = objc_getClass("_VZFramebufferView");
    if (!framebufferViewClass) {
        setStatus(VZL(@"The Virtual Mac display view is unavailable"));
        return NO;
    }
    VZSetNSViewFrameRequestsSuppressed(NO);
    gDisplayContainer = container;
    container.clipsToBounds = YES;
    CGRect viewport = displayViewportRect(gDisplayPixelSize, container.bounds);
    id view = ((id(*)(id, SEL, CGRect))objc_msgSend)(
        [framebufferViewClass alloc], S("initWithFrame:"), viewport);
    gFramebufferView = view;
    gFramebuffer = framebuffer;
    gFramebufferView.backgroundColor = [UIColor blackColor];
    gFramebufferView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Do not insert the AppKit-ABI subclass into UIKit's UIView tree: UIKit's
    // private hierarchy traversal and AppKit's compiled NSView layout are not
    // ABI-compatible. Its custom display layer is portable, so host that layer
    // inside an ordinary UIView while NSViewShim supplies the key window.
    CALayer *displayLayer =
        ((CALayer *(*)(id, SEL))objc_msgSend)(view, S("layer"));
    gDisplayLayer = displayLayer;
    displayLayer.frame = viewport;
    [container.layer insertSublayer:displayLayer atIndex:0];
    ((void(*)(id, SEL, BOOL))objc_msgSend)(
        view, S("setShowsCursor:"), NO);
    setObj(view, "setFramebuffer:", framebuffer);
    if ([view respondsToSelector:S("layout")])
        ((void(*)(id, SEL))objc_msgSend)(view, S("layout"));
    updateDisplayGeometry();
    logFramebufferState(view, framebuffer, "pre-registered");
    return YES;
}

typedef struct {
    UIView *container;
    BOOL result;
} VZPrepareFramebufferContext;

static void prepareFramebufferOnMain(void *opaque) {
    VZPrepareFramebufferContext *context = opaque;
    context->result = prepareFramebuffer(context->container);
}

static BOOL prepareFramebufferThreadSafe(UIView *container) {
    if (pthread_main_np())
        return prepareFramebuffer(container);
    VZPrepareFramebufferContext context = { container, NO };
    dispatch_sync_f(dispatch_get_main_queue(), &context,
                    prepareFramebufferOnMain);
    return context.result;
}

typedef struct {
    id delegate;
    NSError *error;
} VZFinishContext;

static void finishVMOnMain(void *opaque) {
    VZFinishContext *context = opaque;
    [context->delegate finishVMAndShowLibraryWithError:context->error];
    [context->delegate release];
    [context->error release];
    free(context);
}

static void finishVMThreadSafe(id delegate, NSError *error) {
    if (pthread_main_np()) {
        [delegate finishVMAndShowLibraryWithError:error];
        return;
    }
    VZFinishContext *context = calloc(1, sizeof(*context));
    context->delegate = [delegate retain];
    context->error = [error retain];
    dispatch_async_f(dispatch_get_main_queue(), context, finishVMOnMain);
}

static void activateFramebuffer(void) {
    id view = gFramebufferView;
    id framebuffer = gFramebuffer;
    if (!view || !framebuffer)
        return;
    VZSetNSViewFrameRequestsSuppressed(NO);
    if ([view respondsToSelector:S("viewDidMoveToWindow")])
        ((void(*)(id, SEL))objc_msgSend)(view, S("viewDidMoveToWindow"));
    if ([view respondsToSelector:S("layout")])
        ((void(*)(id, SEL))objc_msgSend)(view, S("layout"));
    BOOL inputFocused = GCKeyboard.coalescedKeyboard
        ? [gInputView becomeFirstResponder] : gInputView.isFirstResponder;
    printf("[VirtualMac] input focus after-start requested=%d active=%d window=%p\n",
           inputFocused, [gInputView isFirstResponder], gInputView.window);
    scheduleInputSelfTest();
    pollInputCommand();
    logFramebufferState(view, framebuffer, "activated");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        logFramebufferState(view, framebuffer, "after-2s");
    });
    setStatus(VZL(@"Virtual Mac running — native PVG framebuffer attached"));
    if (externalDisplayEnabled())
        connectExternalDisplay();
}

typedef struct {
    id virtualMachine;
    id startOptions;
    void (^completion)(NSError *);
} VZInvokeStartContext;

static void invokeVirtualMachineStartOnMain(void *opaque) {
    VZInvokeStartContext *context = opaque;
    if (context->startOptions) {
        ((void(*)(id, SEL, id, id))objc_msgSend)(
            context->virtualMachine,
            S("startWithOptions:completionHandler:"),
            context->startOptions, context->completion);
    } else {
        ((void(*)(id, SEL, id))objc_msgSend)(
            context->virtualMachine, S("startWithCompletionHandler:"),
            context->completion);
    }
    [context->virtualMachine release];
    [context->startOptions release];
    [context->completion release];
    free(context);
}

static void startVirtualMachineWorker(UIView *container, id delegate,
                                      NSString *bundlePath,
                                      NSDictionary *options) {
    setVMJetsamProtection(YES);
    gShiftPressedMask = 0;
    [gGamepadBridge detachFromVirtualMachine];
    pencilVsockReset();
    VZGuestToolsReset();
    __atomic_store_n(&gPencilRelayEnabled,
        [options[VZApplePencilPressureTiltEnabledKey] boolValue],
        __ATOMIC_RELEASE);
    unlink("/tmp/vzxpchook.log");
    unlink("/tmp/vmmhook.log");
    unlink("/tmp/vmm.stderr.log");
    setenv("VZ_VMM_BIN",
           "/var/root/VirtualMac/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
           1);
    setenv("VZ_AVP_BOOTER",
           "/var/root/VirtualMac/payload/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin",
           1);
    // Consume the one-shot mode at the actual boot boundary. The current boot
    // keeps the captured value while Settings immediately returns to Off.
    gDebugLogging = VZConsumeDebugLoggingForBoot();
    resetScrollDiagnostics();
    setenv("VZ_DEBUG_LOGGING", gDebugLogging ? "1" : "0", 1);
    setenv("VMMHOOK_TRACE_VCPU_LIMIT", gDebugLogging ? "256" : "8", 1);
    setenv("VMMHOOK_TRACE_XPC_LIMIT", gDebugLogging ? "200" : "8", 1);
    setenv("VMM_FACTORY_SETTLE_USEC", "100000", 1);
    // Timestamp correlation places PGIOSurfaceHostDevice finalization just
    // before serialized factory boundary 6. Pause only that boundary long
    // enough for its asynchronous Metal/IOSurface capability exchange.
    setenv("VMM_FACTORY_LONG_STOP", "6", 1);
    setenv("VMM_FACTORY_LONG_SETTLE_USEC", "5000000", 1);
    setenv("PVG_TRACE", "1", 1);
    // Functional PVG task compatibility remains installed in every build;
    // this flag enables only the additional diagnostic method wrappers.
    if (gDebugLogging)
        setenv("PVG_TRACE_METHODS", "1", 1);
    else
        unsetenv("PVG_TRACE_METHODS");
    // Ordinary clients start with a compact reservation and grow lazily below.
    // Keep the first three long-lived system clients contiguous, however.
    // WindowServer's Launchpad task crosses 256 MiB in one burst and older
    // guests can stop submitting frames after that task is split across host
    // reservations even though every individual map succeeds. Two GiB matches
    // the proven 1.1.2 policy and still uses only a small fraction of iPadOS's
    // roughly 63 GiB extended address space.
    setenv("PVG_TASK_RESERVATION_MB", "256", 1);
    // Once an ordinary client crosses its primary reservation, the PVG host
    // adds a separate 2 GiB sparse reservation and translates PGTask's address
    // helpers. Final Cut exceeded the old fixed 512 MiB reservation, while a
    // launch-all stress test showed that only two of 74 ordinary clients did.
    setenv("PVG_TASK_OVERFLOW_MB", "2048", 1);
    setenv("PVG_LARGE_TASK_RESERVATION_MB", "2048", 1);
    setenv("PVG_LARGE_TASK_COUNT", "3", 1);
    setenv("PVG_MIN_TASK_RESERVATION_MB", "64", 1);
    setenv("PVG_METALLIB_FALLBACK", "1", 1);
    BOOL metalBCSupport =
        [options[VZMetalBCSupportEnabledKey] boolValue];
    setenv("VZ_METAL_BC_SUPPORT", metalBCSupport ? "1" : "0", 1);

    setStatus(VZL(@"Loading extracted Apple virtualization frameworks…"));
    BOOL guestToolsEnabled =
        [options[VZVirtualMacGuestToolsEnabledKey] boolValue];
    BOOL openGLAcceleration = guestToolsEnabled &&
        [options[VZOpenGLAccelerationEnabledKey] boolValue];
    setenv("VZ_GUEST_RUNTIME_POLICY", openGLAcceleration ? "1" : "0", 1);
    fprintf(stderr, "[GuestTools] VM option enabled=%d OpenGL=%d BC=%d pencil=%d\n",
            guestToolsEnabled,
            openGLAcceleration, metalBCSupport,
            [options[VZApplePencilPressureTiltEnabledKey] boolValue]);
    if (!loadExtractedFrameworks()) {
        setStatus(VZL(@"Failed to load extracted frameworks"));
        NSError *loadError = [NSError errorWithDomain:@"VirtualMac" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                VZL(@"Failed to load the extracted Apple virtualization frameworks.")}];
        finishVMThreadSafe(delegate, loadError);
        return;
    }

    printf("[VirtualMac] starting selected VM path=%s\n", bundlePath.UTF8String);
    NSError *error = nil;
    id configuration = makeConfiguration(bundlePath, options, &error);
    if (!configuration) {
        setStatus([NSString stringWithFormat:VZL(@"Configuration failed: %@"),
                                            error.localizedDescription]);
        if (!error)
            error = [NSError errorWithDomain:@"VirtualMac" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    VZL(@"The Virtual Mac configuration could not be created.")}];
        finishVMThreadSafe(delegate, error);
        return;
    }
    printf("[VirtualMac] validating VM configuration\n");
    BOOL valid = ((BOOL(*)(id, SEL, NSError **))objc_msgSend)(
        configuration, S("validateWithError:"), &error);
    printf("[VirtualMac] VM configuration validation result=%d error=%s\n",
           valid, error ? error.description.UTF8String : "(none)");
    if (!valid) {
        setStatus([NSString stringWithFormat:VZL(@"Validation failed: %@"),
                                            error.localizedDescription]);
        finishVMThreadSafe(delegate, error);
        return;
    }

    printf("[VirtualMac] constructing VM runtime\n");
    gVirtualMachine = ((id(*)(id, SEL, id))objc_msgSend)(
        m0(CLS("VZVirtualMachine"), "alloc"),
        S("initWithConfiguration:"), configuration);
    printf("[VirtualMac] VM runtime constructed=%p\n", gVirtualMachine);
    if (guestToolsEnabled ||
        [options[VZGuestToolsRemovalPendingKey] boolValue])
        VZGuestToolsAttachToVirtualMachine(gVirtualMachine);
    gVirtualMachineDelegate = delegate;
    if ([gVirtualMachine respondsToSelector:S("setDelegate:")])
        setObj(gVirtualMachine, "setDelegate:", delegate);
    id keyboards = [gVirtualMachine respondsToSelector:S("_keyboards")]
        ? m0(gVirtualMachine, "_keyboards") : nil;
    id pointingDevices =
        [gVirtualMachine respondsToSelector:S("_pointingDevices")]
        ? m0(gVirtualMachine, "_pointingDevices") : nil;
    printf("[VirtualMac] runtime input keyboards=%s pointingDevices=%s\n",
           [[keyboards description] UTF8String],
           [[pointingDevices description] UTF8String]);
    gKeyboard = [keyboards firstObject];
    gPointingDevice = [pointingDevices firstObject];
    dumpRPCHandlers(gVirtualMachine, "after-init");
    // setFramebuffer: installs the process_frame_update handler needed by the
    // VMM. The host hook holds its set_frame_rate message until start succeeds.
    if (!prepareFramebufferThreadSafe(container)) {
        NSError *framebufferError = [NSError errorWithDomain:@"VirtualMac"
            code:3 userInfo:@{NSLocalizedDescriptionKey:
                VZL(@"The Virtual Mac did not publish a display framebuffer.")}];
        finishVMThreadSafe(delegate, framebufferError);
        return;
    }
    setStatus(VZL(@"Starting Virtual Mac…"));
    BOOL runtimePolicyEnabled = openGLAcceleration;
#if EXPERIMENT_GDB_DEBUG
    BOOL externalKernelDebug = [[NSFileManager defaultManager]
        fileExistsAtPath:@"/tmp/vz-external-kernel-debug"];
#endif
    void (^finishStartedVM)(void) = ^{
        dumpRPCHandlers(gVirtualMachine, "after-start");
        setStatus(VZL(@"Virtual Mac running — preparing native PVG display"));
        pencilVsockSetup();
        [gGamepadBridge attachToVirtualMachine:gVirtualMachine];
        VZGuestToolsStartProvisioning(bundlePath, guestToolsEnabled,
                                      openGLAcceleration,
            [options[VZApplePencilPressureTiltEnabledKey] boolValue],
            [options[VZGuestToolsRemovalPendingKey] boolValue]);
        gHostVMStarted();
    };
    void (^completion)(NSError *) = ^(NSError *startError) {
        if (startError) {
            setStatus([NSString stringWithFormat:VZL(@"Virtual Mac start failed: %@"),
                                                startError.localizedDescription]);
            finishVMThreadSafe(delegate, startError);
            return;
        }
        printf("[VirtualMac] VM STARTED state=%ld\n",
               (long)((NSInteger(*)(id, SEL))objc_msgSend)(
                   gVirtualMachine, S("state")));
        // Publish the display as soon as VZ accepts the start, rather than
        // hiding iBoot and the Apple progress UI behind the policy scan.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                activateFramebuffer();
            });
        fprintf(stderr, "[GuestPolicy] start completion enabled=%d\n",
                runtimePolicyEnabled);
        finishStartedVM();
    };
    id startOptions = nil;
    if ([options[@"BootRecovery"] boolValue] &&
        [gVirtualMachine respondsToSelector:
            S("startWithOptions:completionHandler:")]) {
        startOptions = NEW("VZMacOSVirtualMachineStartOptions");
        ((void(*)(id, SEL, BOOL))objc_msgSend)(
            startOptions, S("setStartUpFromMacOSRecovery:"), YES);
        printf("[VirtualMac] configured recovery start\n");
    }
#if EXPERIMENT_GDB_DEBUG
    if (externalKernelDebug &&
        [gVirtualMachine respondsToSelector:
            S("startWithOptions:completionHandler:")]) {
        if (!startOptions)
            startOptions = NEW("VZMacOSVirtualMachineStartOptions");
        VZGuestRuntimePolicyConfigureStartOptions(startOptions);
        printf("[GuestPolicy] configured development debug stop\n");
    }
#endif
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 &&
        !pthread_main_np()) {
        VZInvokeStartContext *context = calloc(1, sizeof(*context));
        context->virtualMachine = [gVirtualMachine retain];
        context->startOptions = [startOptions retain];
        context->completion = [completion copy];
        dispatch_async_f(dispatch_get_main_queue(), context,
                         invokeVirtualMachineStartOnMain);
    } else if (startOptions) {
        ((void(*)(id, SEL, id, id))objc_msgSend)(
            gVirtualMachine, S("startWithOptions:completionHandler:"),
            startOptions, completion);
    } else {
        ((void(*)(id, SEL, id))objc_msgSend)(
            gVirtualMachine, S("startWithCompletionHandler:"), completion);
    }
    [startOptions release];
}

typedef struct {
    UIView *container;
    id delegate;
    NSString *bundlePath;
    NSDictionary *options;
} VZStartContext;

static void startVirtualMachineOnBackgroundQueue(void *opaque) {
    VZStartContext *context = opaque;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    startVirtualMachineWorker(context->container, context->delegate,
                              context->bundlePath, context->options);
    [context->container release];
    [context->delegate release];
    [context->bundlePath release];
    [context->options release];
    free(context);
    [pool drain];
}

static CGSize orientPixelSizeForBounds(CGSize pixels, CGSize bounds)
{
    BOOL landscape = bounds.width >= bounds.height;
    CGFloat shortSide = MIN(pixels.width, pixels.height);
    CGFloat longSide = MAX(pixels.width, pixels.height);
    return landscape ? CGSizeMake(longSide, shortSide)
                     : CGSizeMake(shortSide, longSide);
}

static NSInteger pixelsPerInchForScreen(UIScreen *screen)
{
    // Every supported built-in iPad display is 264 PPI. UIKit does not expose
    // an external panel's physical dimensions, so use its logical display
    // scale to preserve the density selected by iPadOS for that screen.
    if (!screen || screen == UIScreen.mainScreen)
        return 264;
    CGFloat scale = screen.nativeScale > 0
        ? screen.nativeScale : MAX(screen.scale, 1.0);
    return MAX(72, MIN(600, (NSInteger)llround(72.0 * scale)));
}

static NSDictionary *runtimeDisplayOptions(NSDictionary *options,
                                            UIView *container)
{
    NSMutableDictionary *runtime =
        [NSMutableDictionary dictionaryWithDictionary:options ?: @{}];
    UIWindow *window = container.window;
    UIScreen *activeScreen = window.screen ?: UIScreen.mainScreen;
    CGRect windowBounds = window ? window.bounds : container.bounds;
    CGFloat activeScale = activeScreen.nativeScale > 0
        ? activeScreen.nativeScale : MAX(activeScreen.scale, 1.0);
    CGSize activePixels = activeScreen.nativeBounds.size;
    if (activePixels.width <= 0 || activePixels.height <= 0)
        activePixels = CGSizeMake(activeScreen.bounds.size.width * activeScale,
                                  activeScreen.bounds.size.height * activeScale);
    activePixels = orientPixelSizeForBounds(activePixels, windowBounds.size);

    UIScreen *builtInScreen = UIScreen.mainScreen;
    CGSize builtInPixels = builtInScreen.nativeBounds.size;
    if (builtInPixels.width <= 0 || builtInPixels.height <= 0) {
        CGFloat scale = builtInScreen.nativeScale > 0
            ? builtInScreen.nativeScale : MAX(builtInScreen.scale, 1.0);
        builtInPixels = CGSizeMake(builtInScreen.bounds.size.width * scale,
                                   builtInScreen.bounds.size.height * scale);
    }

    runtime[@"_ActiveScreenPixelWidth"] =
        @((NSInteger)llround(activePixels.width));
    runtime[@"_ActiveScreenPixelHeight"] =
        @((NSInteger)llround(activePixels.height));
    runtime[@"_ActiveScreenPixelsPerInch"] =
        @(pixelsPerInchForScreen(activeScreen));
    runtime[@"_BuiltInLandscapePixelWidth"] =
        @((NSInteger)llround(MAX(builtInPixels.width, builtInPixels.height)));
    runtime[@"_BuiltInLandscapePixelHeight"] =
        @((NSInteger)llround(MIN(builtInPixels.width, builtInPixels.height)));
    runtime[@"_BuiltInPortraitPixelWidth"] =
        @((NSInteger)llround(MIN(builtInPixels.width, builtInPixels.height)));
    runtime[@"_BuiltInPortraitPixelHeight"] =
        @((NSInteger)llround(MAX(builtInPixels.width, builtInPixels.height)));
    runtime[@"_BuiltInScreenPixelsPerInch"] =
        @(pixelsPerInchForScreen(builtInScreen));

    // Prefer the screen hosting the app when that is external; otherwise use
    // the first connected external screen. If none is available, retain the
    // active-screen dimensions so a saved configuration always remains
    // bootable when the display is disconnected.
    UIScreen *externalScreen = activeScreen != builtInScreen
        ? activeScreen : nil;
    if (!externalScreen) {
        for (UIScreen *candidate in UIScreen.screens) {
            if (candidate != builtInScreen) {
                externalScreen = candidate;
                break;
            }
        }
    }
    CGSize externalPixels = activePixels;
    if (externalScreen) {
        CGFloat externalScale = externalScreen.nativeScale > 0
            ? externalScreen.nativeScale : MAX(externalScreen.scale, 1.0);
        externalPixels = externalScreen.nativeBounds.size;
        if (externalPixels.width <= 0 || externalPixels.height <= 0)
            externalPixels = CGSizeMake(
                externalScreen.bounds.size.width * externalScale,
                externalScreen.bounds.size.height * externalScale);
        externalPixels = orientPixelSizeForBounds(
            externalPixels, externalScreen.bounds.size);
    }
    runtime[@"_ExternalScreenPixelWidth"] =
        @((NSInteger)llround(externalPixels.width));
    runtime[@"_ExternalScreenPixelHeight"] =
        @((NSInteger)llround(externalPixels.height));
    runtime[@"_ExternalScreenPixelsPerInch"] =
        @(pixelsPerInchForScreen(externalScreen ?: activeScreen));
    runtime[@"_ExternalScreenDescription"] =
        externalScreen.description ?: @"(not connected; using active screen)";
    runtime[@"_HostWindowPixelWidth"] =
        @((NSInteger)llround(windowBounds.size.width * activeScale));
    runtime[@"_HostWindowPixelHeight"] =
        @((NSInteger)llround(windowBounds.size.height * activeScale));
    runtime[@"_HostWindowPixelsPerInch"] =
        @(pixelsPerInchForScreen(activeScreen));
    runtime[@"_ActiveScreenDescription"] = activeScreen.description ?: @"";
    return runtime;
}

static void startVirtualMachine(UIView *container, id delegate,
                                NSString *bundlePath,
                                NSDictionary *options) {
    NSDictionary *runtimeOptions = runtimeDisplayOptions(options, container);
    // Ventura's VZ startup performs synchronous XPC and device construction.
    // On iPadOS 14, doing that from a tap blocks UIKit long enough to trip the
    // 10-second scene-update watchdog. Keep iPadOS 15/16 on their proven path.
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 &&
        pthread_main_np()) {
        VZStartContext *context = calloc(1, sizeof(*context));
        context->container = [container retain];
        context->delegate = [delegate retain];
        context->bundlePath = [bundlePath copy];
        context->options = [runtimeOptions copy];
        dispatch_async_f(
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), context,
            startVirtualMachineOnBackgroundQueue);
        return;
    }
    startVirtualMachineWorker(container, delegate, bundlePath, runtimeOptions);
}

// ─── External Display (Keynote-style) ────────────────────────────────────────
// Keynote and other presentation apps use UIWindow.screen = externalScreen
// to take over an external display without system-level borders. UIScene's
// UIWindowSceneSessionRoleExternalDisplay can add display-specific insets
// that appear as black bars.

static BOOL externalDisplayEnabled(void) {
    return [VZAppSettings.sharedSettings boolForKey:VZExternalDisplayEnabledKey]
        && gFramebuffer != nil;
}

static void connectExternalDisplayWithScreen(UIScreen *extScreen) {
    if (gExternalWindow)
        return;
    if (![VZAppSettings.sharedSettings boolForKey:VZExternalDisplayEnabledKey])
        return;
    if (!extScreen) {
        for (UIScreen *s in UIScreen.screens) {
            if (s != UIScreen.mainScreen) {
                extScreen = s;
                break;
            }
        }
    }
    if (!extScreen)
        return;

    // Disable overscan compensation so the system doesn't scale/inset
    // the display output. Without this, nativeBounds may differ from
    // bounds, introducing system-level black borders.
    extScreen.overscanCompensation = 2;  // UIScreenOverscanCompensationNone

    printf("[VirtualMac] external display connecting screen=%s "
           "bounds=%.0fx%.0f native=%.0fx%.0f scale=%.3f "
           "overscanCompensation=%ld\n",
           extScreen.description.UTF8String,
           extScreen.bounds.size.width, extScreen.bounds.size.height,
           extScreen.nativeBounds.size.width, extScreen.nativeBounds.size.height,
           extScreen.scale,
           (long)extScreen.overscanCompensation);
    for (UIScreenMode *mode in extScreen.availableModes) {
        printf("[VirtualMac] ext screen mode size=%.0fx%.0f "
               "pixelAspectRatio=%.3f\n",
               mode.size.width, mode.size.height,
               mode.pixelAspectRatio);
    }

    gExternalWindow = [[UIWindow alloc] initWithFrame:extScreen.bounds];
    gExternalWindow.screen = extScreen;
    gExternalWindow.backgroundColor = [UIColor blackColor];

    UIView *mirrorView = [[UIView alloc] initWithFrame:gExternalWindow.bounds];
    mirrorView.backgroundColor = [UIColor blackColor];
    mirrorView.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                | UIViewAutoresizingFlexibleHeight;
    mirrorView.layer.contentsGravity = kCAGravityResizeAspect;
    [gExternalWindow addSubview:mirrorView];
    gExternalMirrorView = mirrorView;
    mirrorView.layer.contentsScale = extScreen.scale;
    [mirrorView release];

    gExternalCursorView = [[UIImageView alloc] initWithFrame:CGRectZero];
    gExternalCursorView.backgroundColor = [UIColor clearColor];
    gExternalCursorView.contentMode = UIViewContentModeScaleToFill;
    [gExternalWindow addSubview:gExternalCursorView];
    updateExternalCursorForNormalizedLocation(gLastPointerLocation);

    [gExternalWindow makeKeyAndVisible];
    updateDisplayGeometry();
    updateExternalCursorForNormalizedLocation(gLastPointerLocation);
    printf("[VirtualMac] external window created frame=%s\n",
           NSStringFromCGRect(gExternalWindow.frame).UTF8String);
}

static void connectExternalDisplay(void) {
    connectExternalDisplayWithScreen(nil);
}

static void disconnectExternalDisplay(void) {
    if (!gExternalWindow)
        return;
    printf("[VirtualMac] external display disconnecting\n");
    gExternalMirrorView = nil;
    [gExternalCursorView removeFromSuperview];
    [gExternalCursorView release];
    gExternalCursorView = nil;
    gExternalWindow.hidden = YES;
    [gExternalWindow release];
    gExternalWindow = nil;
    updateDisplayGeometry();
}

@interface VirtualMacAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, retain) UIWindow *window;
@end

@implementation VirtualMacAppDelegate
@synthesize window = _window;

- (VZVMLibraryViewController *)libraryController
{
    VZViewController *root = (id)self.window.rootViewController;
    [root presentVMLibrary];
    return (id)root.libraryNavigationController.viewControllers.firstObject;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    UIApplicationShortcutItem *shortcut = launchOptions[
        UIApplicationLaunchOptionsShortcutItemKey];
    BOOL bypassAutoBoot = [shortcut.type isEqualToString:@"com.mac.virtual.show-library"];
    freopen("/tmp/VirtualMac.log", "a", stdout);
    freopen("/tmp/VirtualMac.log", "a", stderr);
    setvbuf(stdout, NULL, _IONBF, 0);
#if 0
    VZEnableKeyboardRenderingFixAfterCrash();
#endif
    installKeyboardRenderingFix();
    installShellShortcutRelay();
    installVideoMemoryWarningRelay();
    VZTrackpadScrollBridgeConfigure(emitTrackpadScroll, NULL);
    VZSurfaceMouseScrollBridgeConfigure(emitSurfaceMouseScroll, NULL);
    VZTouchScrollBridgeConfigure(emitTouchScroll, NULL);
    gFixExternalDisplayScrollDirection = [VZAppSettings.sharedSettings
        boolForKey:VZExternalDisplayScrollFixKey];
    gScrollingSpeed = MAX(0.1, MIN(1.0,
        [[VZAppSettings.sharedSettings stringForKey:VZScrollingSpeedKey]
            doubleValue]));
    self.window = [[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]
        autorelease];
    VZViewController *controller =
        [[[VZViewController alloc] init] autorelease];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = controller;

    {
        gStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        gStatusLabel.hidden = !shouldShowStatusLabel();
        gStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        gStatusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        gStatusLabel.textColor = [UIColor whiteColor];
        gStatusLabel.font =
            [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        gStatusLabel.textAlignment = NSTextAlignmentCenter;
        gStatusLabel.numberOfLines = 2;
        gStatusLabel.userInteractionEnabled = NO;
        gStatusLabel.layer.cornerRadius = 10;
        gStatusLabel.layer.cornerCurve = kCACornerCurveContinuous;
        gStatusLabel.clipsToBounds = YES;
        [controller.view addSubview:gStatusLabel];
        [NSLayoutConstraint activateConstraints:@[
            [gStatusLabel.centerXAnchor constraintEqualToAnchor:
                controller.view.centerXAnchor],
            [gStatusLabel.bottomAnchor constraintEqualToAnchor:
                controller.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
            [gStatusLabel.widthAnchor constraintEqualToConstant:560],
            [gStatusLabel.heightAnchor constraintEqualToConstant:48],
        ]];
    }

    VZInputView *inputView =
        [[[VZInputView alloc] initWithFrame:controller.view.bounds]
            autorelease];
    gInputView = inputView;
    inputView.backgroundColor = [UIColor clearColor];
    inputView.multipleTouchEnabled = YES;
    inputView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [inputView addGestureRecognizer:
        [[[UIHoverGestureRecognizer alloc]
            initWithTarget:inputView action:@selector(handleHover:)]
            autorelease]];
    [inputView addInteraction:
        [[[UIPointerInteraction alloc] initWithDelegate:inputView]
            autorelease]];
    VZRawScrollRecognizer *scrollRecognizer =
        [[[VZRawScrollRecognizer alloc]
            initWithTarget:inputView action:@selector(handleScroll:)]
            autorelease];
    scrollRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
    // Scroll-wheel input is not represented by UITouch. Rejecting all touch
    // types keeps direct touchscreen click-drag on the existing touch path.
    scrollRecognizer.allowedTouchTypes = @[];
    scrollRecognizer.cancelsTouchesInView = NO;
    [inputView addGestureRecognizer:scrollRecognizer];
    UIPanGestureRecognizer *touchScroll = [[[UIPanGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handleTouchScroll:)]
        autorelease];
    touchScroll.minimumNumberOfTouches = 2;
    touchScroll.maximumNumberOfTouches = 2;
    touchScroll.allowedTouchTypes = @[@(UITouchTypeDirect)];
    touchScroll.cancelsTouchesInView = YES;
    touchScroll.enabled = [VZAppSettings.sharedSettings
        boolForKey:VZTouchTwoFingerScrollingKey];
    [inputView addGestureRecognizer:touchScroll];
    gTouchScrollRecognizer = touchScroll;
    UIPinchGestureRecognizer *pinch = [[[UIPinchGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handlePinch:)] autorelease];
    pinch.cancelsTouchesInView = NO;
    [inputView addGestureRecognizer:pinch];
    gPinchRecognizer = pinch;
    UIRotationGestureRecognizer *rotation = [[[UIRotationGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handleRotation:)] autorelease];
    rotation.cancelsTouchesInView = NO;
    [inputView addGestureRecognizer:rotation];
    gRotationRecognizer = rotation;
    UITapGestureRecognizer *smartMagnify = [[[UITapGestureRecognizer alloc]
        initWithTarget:inputView action:@selector(handleSmartMagnify:)]
        autorelease];
    smartMagnify.numberOfTouchesRequired = 2;
    smartMagnify.numberOfTapsRequired = 2;
    smartMagnify.cancelsTouchesInView = NO;
    gSmartMagnifyRecognizer = smartMagnify;
    if ([VZAppSettings.sharedSettings
            boolForKey:VZTouchTwoFingerScrollingKey]) {
        // Direct two-finger motion otherwise begins UIKit's pinch/rotation
        // recognizers first and the pan never emits a scroll event. Those
        // recognizers remain available for a hardware trackpad.
        pinch.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        rotation.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        smartMagnify.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
    }
    [inputView addGestureRecognizer:smartMagnify];
    [controller.view addSubview:inputView];

    gCursorView = [[UIImageView alloc] initWithFrame:CGRectZero];
    gCursorView.backgroundColor = [UIColor clearColor];
    gCursorView.contentMode = UIViewContentModeScaleToFill;
    gCursorView.userInteractionEnabled = NO;
    gCursorView.hidden = YES;
    [controller.view addSubview:gCursorView];
    VZHUDView *hud = [[[VZHUDView alloc] initWithTarget:controller] autorelease];
    gHUDView = hud;
    hud.hidden = YES;
    [controller.view addSubview:hud];
    [controller updateHUDPosition];
    if (gStatusLabel)
        [controller.view bringSubviewToFront:gStatusLabel];

    [self.window makeKeyAndVisible];
    VZContinueAfterRootHideInformation(controller, nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VZPresentCompatibilityNotice(controller);
    });
    UIApplicationShortcutIcon *libraryIcon = [UIApplicationShortcutIcon
        iconWithSystemImageName:@"square.grid.2x2"];
    UIApplicationShortcutIcon *controlsIcon = [UIApplicationShortcutIcon
        iconWithSystemImageName:@"slider.horizontal.3"];
    application.shortcutItems = @[[[[UIApplicationShortcutItem alloc]
        initWithType:@"com.mac.virtual.show-library"
        localizedTitle:VZL(@"Show Library") localizedSubtitle:nil
        icon:libraryIcon userInfo:nil] autorelease],
        [[[UIApplicationShortcutItem alloc]
        initWithType:@"com.mac.virtual.show-controls"
        localizedTitle:VZL(@"Show Virtual Mac Controls") localizedSubtitle:nil
        icon:controlsIcon userInfo:nil] autorelease]];
    unlink("/tmp/virtual-mac-vm-active");
    gMouseLocation = CGPointMake(CGRectGetMidX(inputView.bounds),
                                 CGRectGetMidY(inputView.bounds));
    gShowCursorWhenUsingTouch = [VZAppSettings.sharedSettings
        boolForKey:VZShowCursorWhenUsingTouchKey];
    gLastInputWasDirectTouch = NO;
    gCursorSuppressedForDirectTouch = NO;
    installGCMouse();
    gGamepadBridge = [VZGamepadBridge sharedBridge];
    [gGamepadBridge start];
    startHealthMonitor();
    startControlMonitor();
    printf("[VirtualMac] VM picker ready inputWindow=%p\n", inputView.window);
    requestMicrophoneAccess(^{
        NSString *controlPath = @"/tmp/vz-autoboot-path";
        NSString *autoBootPath = [NSString
            stringWithContentsOfFile:controlPath
                           encoding:NSUTF8StringEncoding error:nil];
        autoBootPath = [autoBootPath
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *persistentAutoBoot = [VZAppSettings.sharedSettings
            stringForKey:VZAutoBootVMPathKey];
        if (persistentAutoBoot.length && !VZIsValidVMBundle(persistentAutoBoot)) {
            NSString *identifier = [VZAppSettings.sharedSettings
                stringForKey:VZAutoBootVMIdentifierKey];
            persistentAutoBoot = nil;
            for (NSDictionary *machine in VZDiscoverVirtualMachines()) {
                if (identifier.length && [VZVMStableIdentifier(machine[@"path"])
                        isEqualToString:identifier]) {
                    persistentAutoBoot = machine[@"path"];
                    [VZAppSettings.sharedSettings setString:persistentAutoBoot
                        forKey:VZAutoBootVMPathKey];
                    break;
                }
            }
            if (!persistentAutoBoot) {
                printf("[VirtualMac] clearing missing auto boot VM\n");
                [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMPathKey];
                [VZAppSettings.sharedSettings setString:nil forKey:VZAutoBootVMIdentifierKey];
            }
        }
        if (!autoBootPath.length && !bypassAutoBoot)
            autoBootPath = persistentAutoBoot;
        if (autoBootPath.length && VZIsValidVMBundle(autoBootPath)) {
            unlink(controlPath.fileSystemRepresentation);
            [NSUserDefaults.standardUserDefaults setObject:autoBootPath
                                                    forKey:@"VZSelectedVMPath"];
            printf("[VirtualMac] one-shot auto boot path=%s\n",
                   autoBootPath.UTF8String);
            controller.activeVMBundlePath = autoBootPath;
            [controller activateVMDisplay:YES];
            startVirtualMachine(controller.view, controller, autoBootPath,
                                VZVMOptionsForBundle(autoBootPath));
        } else {
            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:controlPath]) {
                printf("[VirtualMac] rejected one-shot auto boot path=%s\n",
                       autoBootPath.UTF8String ?: "(unreadable)");
                unlink(controlPath.fileSystemRepresentation);
            }
            [controller presentVMLibrary];
            // Reproducible on-device integration path: a root-side test script
            // can request one real UIKit installation after launching the app.
            // The normal library, visible progress alert, polling timer, and
            // completion handling are all used; this is not a headless helper.
            NSString *requestPath = [VZVMSupportPath()
                stringByAppendingPathComponent:@".visible-install-request"];
            NSString *request = [NSString
                stringWithContentsOfFile:requestPath
                               encoding:NSUTF8StringEncoding error:nil];
            NSArray *lines = [request componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            NSString *installName = lines.count > 0 ? lines[0] : @"";
            NSString *installPath = lines.count > 1 ? lines[1] : @"";
            BOOL validRequest = installName.length && installPath.length &&
                [installName rangeOfString:@"/"].location == NSNotFound &&
                [installPath hasPrefix:[VZRestoreImagesPath()
                    stringByAppendingString:@"/"]] &&
                [NSFileManager.defaultManager fileExistsAtPath:installPath];
            if (request.length) {
                unlink(requestPath.fileSystemRepresentation);
                if (validRequest) {
                    printf("[VirtualMac] visible installation request name=%s ipsw=%s\n",
                           installName.UTF8String, installPath.UTF8String);
                    NSMutableDictionary *options = [NSMutableDictionary
                        dictionaryWithDictionary:VZVMDefaultOptions()];
                    if (VZRestoreImageUsesMontereyProfile(installPath)) {
                        options[@"KeyboardDevice"] = @"USBKeyboard";
                        options[@"PointingDevice"] = @"USBMouse";
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(0.75 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            VZVMLibraryViewController *library = (id)
                                controller.libraryNavigationController
                                    .viewControllers.firstObject;
                            [controller vmLibrary:library
                                installRestoreImageAtURL:
                                    [NSURL fileURLWithPath:installPath]
                                name:installName options:options];
                        });
                } else {
                    printf("[VirtualMac] rejected visible installation request=%s\n",
                           request.UTF8String);
                }
            }
        }
    });
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    (void)application;
    resetPointerSession(YES);
    [gGamepadBridge setForegroundActive:NO];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    (void)application;
    resetPointerSession(YES);
    [gGamepadBridge setForegroundActive:YES];
    if (gInputView) {
        for (id interaction in gInputView.interactions)
            if ([interaction respondsToSelector:@selector(invalidate)])
                [interaction invalidate];
        VZViewController *controller = (id)self.window.rootViewController;
        if (controller.isVMDisplayActive && GCKeyboard.coalescedKeyboard)
            [gInputView becomeFirstResponder];
    }
}

- (void)application:(UIApplication *)application
    performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem
    completionHandler:(void (^)(BOOL succeeded))completionHandler
{
    (void)application;
    VZViewController *controller = (id)self.window.rootViewController;
    BOOL handled = [shortcutItem.type isEqualToString:@"com.mac.virtual.show-library"] ||
        [shortcutItem.type isEqualToString:@"com.mac.virtual.show-controls"];
    if ([shortcutItem.type isEqualToString:@"com.mac.virtual.show-library"]) {
        [controller presentVMLibrary];
    } else if ([shortcutItem.type isEqualToString:@"com.mac.virtual.show-controls"]) {
        [VZAppSettings.sharedSettings setString:@"always"
            forKey:VZHUDVisibilityKey];
        [controller updateHUDVisibility];
    }
    if (completionHandler) completionHandler(handled);
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
             options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    (void)application; (void)options;
    if (![url.scheme isEqualToString:@"virtualmac"]) return NO;
    NSString *action = url.host.lowercaseString;
    // Developer-only visible UI checks for the touch keyboard. Keep these
    // outside libraryController so exercising them does not hide the running
    // virtual Mac first.
    if ([action isEqualToString:@"keyboard-show"]) {
        gSoftwareKeyboardRequested = YES;
        return gInputView && [gInputView becomeFirstResponder];
    }
    if ([action isEqualToString:@"keyboard-hide"]) {
        gSoftwareKeyboardRequested = NO;
        return gInputView && [gInputView resignFirstResponder];
    }
    VZVMLibraryViewController *library = [self libraryController];
    if ([action isEqualToString:@"new"])
        [library presentNewVMFlow];
    else if ([action isEqualToString:@"settings"])
        [library presentSettings];
    else if ([action isEqualToString:@"library"])
        ;
    else
        return NO;
    return YES;
}

- (void)dealloc
{
    [_window release];
    [super dealloc];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv,
                                 NSStringFromClass([VirtualMacApplication class]),
                                 NSStringFromClass([VirtualMacAppDelegate class]));
    }
}
