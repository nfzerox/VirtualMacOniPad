#import "VZAppSettings.h"

NSString * const VZSettingsDidChangeNotification = @"VZSettingsDidChange";
NSString * const VZLibraryLayoutKey = @"LibraryLayout";
NSString * const VZAutoBootVMPathKey = @"AutoBootVMPath";
NSString * const VZAutoBootVMIdentifierKey = @"AutoBootVMIdentifier";
NSString * const VZKeyboardShortcutCaptureKey = @"KeyboardShortcutCapture";
NSString * const VZSystemGestureSuppressionKey = @"SystemGestureSuppression";
NSString * const VZMultitaskingGestureSuppressionKey = @"MultitaskingGestureSuppression";
NSString * const VZHomeIndicatorSuppressionKey = @"HomeIndicatorSuppression";
NSString * const VZShowStatusLabelKey = @"ShowDebugStatusOverlay";
NSString * const VZAutoDeleteRestoreImageKey = @"AutoDeleteRestoreImage";
NSString * const VZHUDVisibilityKey = @"HUDVisibility";
NSString * const VZHUDCornerKey = @"HUDCorner";
NSString * const VZExternalDisplayEnabledKey = @"ExternalDisplayEnabled";
NSString * const VZDisplayScalingKey = @"DisplayScaling";
NSString * const VZTouchDoubleTapAccommodationKey = @"TouchDoubleTapAccommodation";
NSString * const VZTouchTwoFingerScrollingKey = @"TouchTwoFingerScrolling";
NSString * const VZTouchTwoFingerRightClickKey = @"TouchTwoFingerRightClick";
NSString * const VZTouchLongPressRightClickKey = @"TouchLongPressRightClick";
NSString * const VZShowCursorWhenUsingTouchKey = @"ShowCursorWhenUsingTouch";
NSString * const VZKeyboardCrashWorkaroundKey = @"KeyboardCrashWorkaround";
NSString * const VZExternalDisplayScrollFixKey = @"ExternalDisplayScrollFix";
NSString * const VZScrollingSpeedKey = @"ScrollingSpeed";
NSString * const VZHUDOpacityKey = @"HUDOpacity";
NSString * const VZDebugLoggingKey = @"DebugLogging";
NSString * const VZGamepadRelayEnabledKey = @"GamepadRelayEnabled";
NSString * const VZGamepadDestinationKey = @"GamepadDestination";
NSString * const VZGamepadTransportKey = @"GamepadTransport";
NSString * const VZGamepadTransportVirtioSocket = @"vsock";
NSString * const VZGamepadTransportUDP = @"udp";
NSString * const VZDebugLoggingModeOff = @"off";
NSString * const VZDebugLoggingModeNextBoot = @"next";
NSString * const VZDebugLoggingModeAlways = @"always";

static NSString * const VZSettingsPath = @"/var/mobile/Media/VirtualMac/Settings.plist";
static CFStringRef const VZSettingsDarwinNotification =
    CFSTR("com.mac.virtual.settings-changed");

NSString *VZRootHideJailbreakRootPath(void)
{
    NSString *path = NSBundle.mainBundle.bundlePath;
    NSRange marker = [path rangeOfString:@"/.jbroot-"];
    if (marker.location == NSNotFound)
        return nil;
    NSUInteger componentStart = marker.location + 1;
    NSRange remainder = NSMakeRange(componentStart,
        path.length - componentStart);
    NSRange separator = [path rangeOfString:@"/" options:0 range:remainder];
    NSUInteger end = separator.location == NSNotFound
        ? path.length : separator.location;
    NSString *root = [path substringToIndex:end];
    return root.length ? root : nil;
}

BOOL VZIsRootHideEnvironment(void)
{
    return VZRootHideJailbreakRootPath() != nil;
}

@interface VZAppSettings ()
@property(nonatomic, retain) NSMutableDictionary *values;
@end

@implementation VZAppSettings

+ (instancetype)sharedSettings
{
    static VZAppSettings *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settings = [[self alloc] init]; });
    return settings;
}

- (instancetype)init
{
    if ((self = [super init])) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:VZSettingsPath];
        _values = [[NSMutableDictionary alloc] initWithDictionary:
            [saved isKindOfClass:NSDictionary.class] ? saved : @{}];
        // Migrate the former switch without changing what an existing user
        // selected. New writes use an explicit three-state value.
        id debug = _values[VZDebugLoggingKey];
        if ([debug isKindOfClass:NSNumber.class])
            _values[VZDebugLoggingKey] = [debug boolValue]
                ? VZDebugLoggingModeAlways : VZDebugLoggingModeOff;
    }
    return self;
}

- (NSDictionary *)defaults
{
    return @{
        VZLibraryLayoutKey: @"grid",
        VZKeyboardShortcutCaptureKey: @YES,
        VZSystemGestureSuppressionKey: @NO,
        VZMultitaskingGestureSuppressionKey: @NO,
        VZHomeIndicatorSuppressionKey: @YES,
        VZShowStatusLabelKey: @NO,
        VZAutoDeleteRestoreImageKey: @YES,
        VZHUDVisibilityKey: @"always",
        VZHUDCornerKey: @"bottom-right",
        VZExternalDisplayEnabledKey: @NO,
        VZDisplayScalingKey: @"fit",
        VZTouchDoubleTapAccommodationKey: @YES,
        VZTouchTwoFingerScrollingKey: @YES,
        VZTouchTwoFingerRightClickKey: @YES,
        VZTouchLongPressRightClickKey: @NO,
        VZShowCursorWhenUsingTouchKey: @YES,
        VZKeyboardCrashWorkaroundKey: @YES,
        VZExternalDisplayScrollFixKey: @YES,
        VZScrollingSpeedKey: @"0.25",
        VZHUDOpacityKey: @"0.55",
        VZDebugLoggingKey: VZDebugLoggingModeOff,
        VZGamepadRelayEnabledKey: @NO,
        VZGamepadDestinationKey: @"",
        VZGamepadTransportKey: VZGamepadTransportVirtioSocket,
    };
}

- (BOOL)boolForKey:(NSString *)key
{
    id value = self.values[key];
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class])
        value = [self defaults][key];
    return [value respondsToSelector:@selector(boolValue)] ?
        [value boolValue] : NO;
}

- (NSString *)stringForKey:(NSString *)key
{
    id value = self.values[key];
    if (![value isKindOfClass:NSString.class])
        value = [self defaults][key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)save
{
    NSString *directory = VZSettingsPath.stringByDeletingLastPathComponent;
    NSError *error = nil;
    BOOL directoryReady = [NSFileManager.defaultManager
        createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:nil error:&error];
    BOOL written = directoryReady && [self.values writeToURL:
        [NSURL fileURLWithPath:VZSettingsPath] error:&error];
    printf("[VirtualMac] settings save success=%d keys=%lu error=%s\n",
           written, (unsigned long)self.values.count,
           error ? error.description.UTF8String : "(none)");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        VZSettingsDarwinNotification, NULL, NULL, YES);
    [NSNotificationCenter.defaultCenter postNotificationName:
        VZSettingsDidChangeNotification object:self];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key
{
    self.values[key] = @(value);
    [self save];
}

- (void)setString:(NSString *)value forKey:(NSString *)key
{
    if ([value isKindOfClass:NSString.class] && value.length)
        self.values[key] = value;
    else
        [self.values removeObjectForKey:key];
    [self save];
}

- (void)resetToDefaults
{
    [self.values removeAllObjects];
    [self save];
}

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    [result addEntriesFromDictionary:self.values];
    return result;
}

- (void)dealloc
{
    [_values release];
    [super dealloc];
}

@end

BOOL VZConsumeDebugLoggingForBoot(void)
{
    __block BOOL enabled = NO;
    void (^consume)(void) = ^{
        VZAppSettings *settings = VZAppSettings.sharedSettings;
        NSString *mode = [settings stringForKey:VZDebugLoggingKey];
        enabled = [mode isEqualToString:VZDebugLoggingModeAlways] ||
            [mode isEqualToString:VZDebugLoggingModeNextBoot];
        if ([mode isEqualToString:VZDebugLoggingModeNextBoot])
            [settings setString:VZDebugLoggingModeOff
                         forKey:VZDebugLoggingKey];
    };
    // VM construction runs on a worker queue. Consuming the one-shot setting
    // posts VZSettingsDidChangeNotification, whose observers update UIKit and
    // FrontBoard scene state. iPadOS 14 aborts if that notification is sent
    // from the worker. Keep settings mutation and notification delivery on
    // the main thread; later VMM construction remains off-main.
    if (NSThread.isMainThread)
        consume();
    else
        dispatch_sync(dispatch_get_main_queue(), consume);
    return enabled;
}

void VZEnableDebugLoggingForNextBoot(void)
{
    VZAppSettings *settings = VZAppSettings.sharedSettings;
    if (![[settings stringForKey:VZDebugLoggingKey]
          isEqualToString:VZDebugLoggingModeAlways])
        [settings setString:VZDebugLoggingModeNextBoot
                     forKey:VZDebugLoggingKey];
}
