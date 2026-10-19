#import "VZGamepadBridge.h"
#import "VZAppSettings.h"
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/ip.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <string.h>
#include <unistd.h>

enum {
    VZGamepadPacketLength = 32,
    VZGamepadReportLength = 16,
    VZGamepadAckLength = 16,
    // Sample frequently enough for low input latency, but only keep the most
    // recent state.  An unchanged full-state keepalive repairs a lost release
    // without continuously generating HID events in the guest.
    VZGamepadSampleRate = 120,
    VZGamepadUDPKeepaliveRate = 10,
    VZGamepadVsockKeepaliveRate = 2,
    VZGamepadReconnectPollRate = 4,
    VZGamepadVsockPort = 25863,
    VZGamepadVsockMaximumQueuedFrames = 16,
    VZGamepadTransitionRepeats = 2,
    // Keep an ultra-short press alive for two 120 Hz samples. This adds at
    // most 16.7 ms to a sub-tick release, while giving a lost press packet a
    // second and third opportunity to cross the guest boundary.
    VZGamepadTransitionHoldTicks = 2,
    // Buttons 0-10, triggers 11-12, and D-pad 13 each keep an independent
    // short-press deadline so unrelated combination inputs cannot hold one
    // another indefinitely.
    VZGamepadDigitalControlCount = 14,
};

NSString * const VZGamepadBridgeStateDidChangeNotification =
    @"VZGamepadBridgeStateDidChange";

@interface VZGamepadBridge () {
    int _udpSocketFD;
    int _vsockFD;
    struct sockaddr_in _destination;
    BOOL _configured;
    BOOL _enabled;
    BOOL _foregroundActive;
    BOOL _started;
    uint32_t _sequence;
    uint32_t _sessionIdentifier;
    uint64_t _packetsSent;
    uint64_t _acksReceived;
    uint32_t _lastAckSequence;
    CFTimeInterval _lastAckTime;
    CFTimeInterval _lastStateNotificationTime;
    NSString *_destinationText;
    NSString *_transport;
    NSString *_lastError;
    GCController *_controller;
    GCController *_pendingController;
    dispatch_queue_t _networkQueue;
    dispatch_source_t _heartbeat;
    uint64_t _heartbeatIntervalNanoseconds;
    uint8_t _latestReport[VZGamepadReportLength];
    uint8_t _lastSentReport[VZGamepadReportLength];
    BOOL _haveLastSentReport;
    unsigned _repeatsRemaining;
    CFTimeInterval _lastTransmitTime;
    CFTimeInterval _lastRepeatTime;
    CFTimeInterval _digitalHoldUntil[VZGamepadDigitalControlCount];
    uint64_t _digitalEventTokens[VZGamepadDigitalControlCount];
    CFTimeInterval _lastSendErrorLogTime;
    CFTimeInterval _lastSendFailureTime;
    int _lastSendError;
    uint64_t _configurationGeneration;
    uint64_t _controllerGeneration;
    uint64_t _nextControllerGeneration;
    // Retained Virtualization runtime objects. They are obtained, messaged and
    // released only on the main thread. The network queue owns only the copied
    // descriptor and plain transport state below.
    id _mainVirtualMachine;
    id _mainVsockDevice;
    id _mainVsockConnection;
    BOOL _vsockDeviceAvailable;
    BOOL _vsockConnecting;
    BOOL _vsockTestPending;
    CFTimeInterval _nextVsockConnectTime;
    CFTimeInterval _vsockRetryDelay;
    uint64_t _vsockGeneration;
    uint64_t _vsockMachineGeneration;
    NSMutableData *_vsockWriteBuffer;
    NSMutableData *_vsockReadBuffer;
    BOOL _havePendingAnalogReport;
    uint8_t _pendingAnalogReport[VZGamepadReportLength];
    uint32_t _sentSequenceRing[256];
    CFTimeInterval _sentTimeRing[256];
    double _rttSamples[256];
    NSUInteger _rttSampleIndex;
    NSUInteger _rttSampleCount;
    double _lastRTTMilliseconds;
}
- (void)handleVsockCompletionOnMainConnection:(id)connection
    error:(NSError *)error generation:(uint64_t)generation;
@end

static void VZWriteBE16(uint8_t *output, uint16_t value)
{
    output[0] = (uint8_t)(value >> 8);
    output[1] = (uint8_t)value;
}

static void VZWriteBE32(uint8_t *output, uint32_t value)
{
    output[0] = (uint8_t)(value >> 24);
    output[1] = (uint8_t)(value >> 16);
    output[2] = (uint8_t)(value >> 8);
    output[3] = (uint8_t)value;
}

static int VZCompareDouble(const void *left, const void *right)
{
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static int16_t VZAxis(float value)
{
    value = fminf(1.0f, fmaxf(-1.0f, value));
    if (fabsf(value) < 0.02f)
        return 0;
    // A few least-significant bits are below useful controller resolution but
    // otherwise make center noise look like 120 distinct changes per second.
    int32_t quantized = (int32_t)lrintf(value * 32767.0f / 64.0f) * 64;
    if (quantized > INT16_MAX) quantized = INT16_MAX;
    if (quantized < INT16_MIN) quantized = INT16_MIN;
    return (int16_t)quantized;
}

static uint16_t VZTrigger(float value)
{
    value = fminf(1.0f, fmaxf(0.0f, value));
    if (value < 0.005f)
        return 0;
    uint32_t quantized = (uint32_t)lrintf(value * 65535.0f / 64.0f) * 64;
    return (uint16_t)(quantized > UINT16_MAX ? UINT16_MAX : quantized);
}

static BOOL VZPressed(GCControllerButtonInput *button)
{
    return button && button.isPressed;
}

static BOOL VZReportTriggerPressed(
    const uint8_t report[VZGamepadReportLength], size_t offset)
{
    uint16_t value = 0;
    memcpy(&value, &report[offset], sizeof(value));
    return value >= UINT16_C(32768);
}

static BOOL VZReportsHaveSameDigitalState(
    const uint8_t left[VZGamepadReportLength],
    const uint8_t right[VZGamepadReportLength])
{
    return left[1] == right[1] && left[2] == right[2] &&
        left[15] == right[15] &&
        VZReportTriggerPressed(left, 11) == VZReportTriggerPressed(right, 11) &&
        VZReportTriggerPressed(left, 13) == VZReportTriggerPressed(right, 13);
}

static void VZCopyDigitalControlState(
    uint8_t destination[VZGamepadReportLength],
    const uint8_t source[VZGamepadReportLength], unsigned index)
{
    if (index <= 10) {
        size_t byte = 1 + index / 8;
        uint8_t mask = (uint8_t)(1u << (index % 8));
        destination[byte] = (destination[byte] & (uint8_t)~mask) |
            (source[byte] & mask);
    } else if (index <= 12) {
        size_t offset = index == 11 ? 11 : 13;
        memcpy(&destination[offset], &source[offset], sizeof(uint16_t));
    } else {
        destination[15] = source[15];
    }
}

static void *VZGamepadNetworkQueueKey = &VZGamepadNetworkQueueKey;

typedef struct {
    id virtualMachine;
} VZGamepadAttachContext;

typedef struct {
    uint64_t generation;
    NSString *errorDescription;
    int descriptor;
} VZGamepadConnectResult;

typedef void (^VZPressedHandler)(float value, BOOL pressed);

static void VZSetPressedHandler(GCControllerButtonInput *button,
                                VZPressedHandler handler)
{
    if (!button)
        return;
    button.pressedChangedHandler =
        ^(GCControllerButtonInput *input, float value, BOOL pressed) {
            (void)input;
            (void)value;
            handler(value, pressed);
        };
}

static void VZClearDigitalHandlers(GCController *controller)
{
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad)
        return;
    pad.buttonA.pressedChangedHandler = nil;
    pad.buttonB.pressedChangedHandler = nil;
    pad.buttonX.pressedChangedHandler = nil;
    pad.buttonY.pressedChangedHandler = nil;
    pad.leftShoulder.pressedChangedHandler = nil;
    pad.rightShoulder.pressedChangedHandler = nil;
    pad.leftThumbstickButton.pressedChangedHandler = nil;
    pad.rightThumbstickButton.pressedChangedHandler = nil;
    pad.leftTrigger.pressedChangedHandler = nil;
    pad.rightTrigger.pressedChangedHandler = nil;
    pad.buttonMenu.pressedChangedHandler = nil;
    pad.buttonOptions.pressedChangedHandler = nil;
    pad.buttonHome.pressedChangedHandler = nil;
    pad.dpad.valueChangedHandler = nil;
}

@implementation VZGamepadBridge

+ (instancetype)sharedBridge
{
    static VZGamepadBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [[self alloc] init]; });
    return bridge;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _udpSocketFD = -1;
        _vsockFD = -1;
        _foregroundActive = YES;
        _latestReport[0] = 1;
        _latestReport[15] = 8;
        _sessionIdentifier = arc4random();
        if (_sessionIdentifier == 0)
            _sessionIdentifier = 1;
        _vsockRetryDelay = 0.25;
        _vsockWriteBuffer = [[NSMutableData alloc] init];
        _vsockReadBuffer = [[NSMutableData alloc] init];
    }
    return self;
}

- (void)start
{
    if (_started)
        return;
    _started = YES;
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    attributes = dispatch_queue_attr_make_with_autorelease_frequency(
        attributes, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    _networkQueue = dispatch_queue_create(
        "com.virtualmac.gamepad-network", attributes);
    dispatch_queue_set_specific(_networkQueue, VZGamepadNetworkQueueKey, self,
        NULL);
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(controllerDidConnect:)
        name:GCControllerDidConnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(controllerDidDisconnect:)
        name:GCControllerDidDisconnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(settingsDidChange:)
        name:VZSettingsDidChangeNotification object:nil];
    [self configureFromSettings];
    [self selectController];

    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        _networkQueue);
    _heartbeatIntervalNanoseconds = NSEC_PER_SEC / VZGamepadReconnectPollRate;
    dispatch_source_set_timer(_heartbeat, DISPATCH_TIME_NOW,
        _heartbeatIntervalNanoseconds, NSEC_PER_MSEC * 5);
    dispatch_source_set_event_handler(_heartbeat, ^{
        @autoreleasepool { [self transmitTick]; }
    });
    dispatch_resume(_heartbeat);
    dispatch_async(_networkQueue, ^{ [self updateHeartbeatInterval]; });
}

- (void)settingsDidChange:(NSNotification *)notification
{
    (void)notification;
    [self configureFromSettings];
}

- (void)configureFromSettings
{
    BOOL requestedEnabled = [VZAppSettings.sharedSettings boolForKey:
        VZGamepadRelayEnabledKey];
    NSString *requestedTransport = [VZAppSettings.sharedSettings stringForKey:
        VZGamepadTransportKey];
    if (![requestedTransport isEqualToString:VZGamepadTransportUDP])
        requestedTransport = VZGamepadTransportVirtioSocket;
    NSString *text = [VZAppSettings.sharedSettings stringForKey:
        VZGamepadDestinationKey] ?: @"";
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    struct in_addr address = {0};
    long port = parts.count == 2 ? [parts[1] integerValue] : 0;
    BOOL valid = parts.count == 2 && port > 0 && port <= UINT16_MAX &&
        inet_pton(AF_INET, parts[0].UTF8String, &address) == 1;
    BOOL routeChanged;
    BOOL enabledChanged;
    uint64_t generation;
    @synchronized (self) {
        routeChanged = ![_transport isEqualToString:requestedTransport] ||
            ([requestedTransport isEqualToString:VZGamepadTransportUDP] &&
             ![_destinationText isEqualToString:text]);
        enabledChanged = _enabled != requestedEnabled;
        [_destinationText release];
        NSString *displayDestination = [requestedTransport isEqualToString:
            VZGamepadTransportUDP] ? text : [NSString stringWithFormat:
            @"Virtio Socket:%u", VZGamepadVsockPort];
        _destinationText = [displayDestination copy];
        [_transport release];
        _transport = [requestedTransport copy];
        _enabled = requestedEnabled;
        if (routeChanged) {
            _configured = NO;
            _configurationGeneration++;
        }
        generation = _configurationGeneration;
    }
    if (!_networkQueue)
        return;
    if (routeChanged || (enabledChanged && !requestedEnabled))
        [self advanceVsockGeneration];
    if (!routeChanged) {
        if (enabledChanged) {
            dispatch_async(_networkQueue, ^{
                if (requestedEnabled) {
                    if ([self usingVsockTransport])
                        [self connectVsockIfNeeded];
                    else
                        [self transmitCurrentStateAllowDisabled:YES];
                }
                else {
                    [self sendNeutralReportOnNetworkQueue];
                    [self resetVsockConnectionSchedulingReconnect:NO];
                }
                [self updateHeartbeatInterval];
            });
        }
        return;
    }
    NSString *destinationText = [text copy];
    NSString *transport = [requestedTransport copy];
    dispatch_async(_networkQueue, ^{
        [self sendNeutralReportOnNetworkQueue];
        if (self->_udpSocketFD >= 0) {
            [self sendNeutralOverUDPBeforeClosing];
            close(self->_udpSocketFD);
            self->_udpSocketFD = -1;
        }
        [self resetVsockConnectionSchedulingReconnect:NO];
        if ([transport isEqualToString:VZGamepadTransportUDP]) {
            [self configureSocketForAddress:address port:(uint16_t)port
                valid:valid generation:generation destination:destinationText];
        } else {
            @synchronized (self) {
                if (generation == self->_configurationGeneration)
                    self->_configured = self->_vsockDeviceAvailable;
            }
            [self setLastError:nil];
            [self connectVsockIfNeeded];
            [self updateHeartbeatInterval];
            [self publishState:YES];
        }
        [destinationText release];
        [transport release];
    });
}

- (BOOL)usingVsockTransport
{
    @synchronized (self) {
        return [_transport isEqualToString:VZGamepadTransportVirtioSocket];
    }
}

- (uint64_t)currentVsockGeneration
{
    return __atomic_load_n(&_vsockGeneration, __ATOMIC_ACQUIRE);
}

- (uint64_t)advanceVsockGeneration
{
    return __atomic_add_fetch(&_vsockGeneration, 1, __ATOMIC_ACQ_REL);
}

- (uint64_t)currentVsockMachineGeneration
{
    return __atomic_load_n(&_vsockMachineGeneration, __ATOMIC_ACQUIRE);
}

- (uint64_t)advanceVsockMachineGeneration
{
    return __atomic_add_fetch(&_vsockMachineGeneration, 1,
        __ATOMIC_ACQ_REL);
}

- (void)clearMainVirtualMachineForGeneration:(uint64_t)generation
{
    NSCAssert(pthread_main_np(), @"Virtualization objects are main-thread-only");
    if (generation != [self currentVsockMachineGeneration])
        return;
    [_mainVsockConnection release];
    _mainVsockConnection = nil;
    [_mainVsockDevice release];
    _mainVsockDevice = nil;
    [_mainVirtualMachine release];
    _mainVirtualMachine = nil;
}

- (void)clearMainConnectionForGeneration:(uint64_t)generation
{
    NSCAssert(pthread_main_np(), @"Virtualization objects are main-thread-only");
    if (generation != [self currentVsockGeneration])
        return;
    [_mainVsockConnection release];
    _mainVsockConnection = nil;
}

- (void)attachToVirtualMachine:(id)virtualMachine
{
    if (!_networkQueue || !virtualMachine)
        return;
    VZGamepadAttachContext *context = calloc(1, sizeof(*context));
    if (!context)
        return;
    [self advanceVsockGeneration];
    uint64_t generation = [self advanceVsockMachineGeneration];
    context->virtualMachine = [virtualMachine retain];

    dispatch_async(_networkQueue, ^{
        [self resetVsockConnectionSchedulingReconnect:NO];
        @synchronized (self) {
            if ([self->_transport isEqualToString:
                    VZGamepadTransportVirtioSocket])
                self->_configured = NO;
        }
        [self updateHeartbeatInterval];
        [self publishState:YES];
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != [self currentVsockMachineGeneration]) {
            [context->virtualMachine release];
            free(context);
            return;
        }
        id machine = context->virtualMachine;
        NSArray *devices = [machine respondsToSelector:
            sel_registerName("socketDevices")]
            ? ((id(*)(id, SEL))objc_msgSend)(machine,
                sel_registerName("socketDevices")) : nil;
        id socketDevice = [devices.firstObject retain];

        [self clearMainVirtualMachineForGeneration:generation];
        self->_mainVirtualMachine = machine;
        context->virtualMachine = nil;
        self->_mainVsockDevice = socketDevice;
        BOOL socketDeviceAvailable = socketDevice != nil;
        dispatch_async(self->_networkQueue, ^{
            if (generation != [self currentVsockMachineGeneration])
                return;
            self->_vsockDeviceAvailable = socketDeviceAvailable;
            @synchronized (self) {
                if ([self->_transport isEqualToString:
                        VZGamepadTransportVirtioSocket])
                    self->_configured = socketDeviceAvailable;
            }
            if (!socketDeviceAvailable)
                [self setLastError:
                    @"The running VM has no Virtio Socket device"];
            else
                [self setLastError:nil];
            [self connectVsockIfNeeded];
            [self updateHeartbeatInterval];
            [self publishState:YES];
        });
        [context->virtualMachine release];
        free(context);
    });
}

- (void)detachFromVirtualMachine
{
    if (!_networkQueue)
        return;
    [self advanceVsockGeneration];
    uint64_t generation = [self advanceVsockMachineGeneration];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self clearMainVirtualMachineForGeneration:generation];
    });
    void (^detach)(void) = ^{
        [self sendNeutralReportOnNetworkQueue];
        [self resetVsockConnectionSchedulingReconnect:NO];
        self->_vsockDeviceAvailable = NO;
        @synchronized (self) {
            if ([self->_transport isEqualToString:
                    VZGamepadTransportVirtioSocket])
                self->_configured = NO;
        }
        [self updateHeartbeatInterval];
        [self publishState:YES];
    };
    if (dispatch_get_specific(VZGamepadNetworkQueueKey) == self)
        detach();
    else
        dispatch_sync(_networkQueue, detach);
}

- (void)resetVsockConnectionSchedulingReconnect:(BOOL)schedule
{
    _vsockFD = -1;
    _vsockConnecting = NO;
    uint64_t generation = [self currentVsockGeneration];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self clearMainConnectionForGeneration:generation];
    });
    [_vsockWriteBuffer setLength:0];
    [_vsockReadBuffer setLength:0];
    _havePendingAnalogReport = NO;
    _haveLastSentReport = NO;
    if (schedule && _vsockDeviceAvailable) {
        CFTimeInterval now = CACurrentMediaTime();
        _nextVsockConnectTime = now + _vsockRetryDelay;
        _vsockRetryDelay = fmin(2.0, fmax(0.25, _vsockRetryDelay * 2.0));
    } else {
        _nextVsockConnectTime = 0;
        _vsockRetryDelay = 0.25;
        _vsockTestPending = NO;
    }
}

- (void)sendNeutralOverUDPBeforeClosing
{
    if (_udpSocketFD < 0)
        return;
    uint8_t neutral[VZGamepadReportLength] = {0};
    neutral[0] = 1;
    neutral[15] = 8;
    for (unsigned copy = 0; copy <= VZGamepadTransitionRepeats; copy++) {
        uint8_t packet[VZGamepadPacketLength] = {0};
        VZWriteBE32(&packet[0], 0x564D4750);
        packet[4] = 1;
        packet[5] = 1;
        VZWriteBE16(&packet[6], VZGamepadReportLength);
        VZWriteBE32(&packet[8], ++_sequence);
        VZWriteBE32(&packet[12], _sessionIdentifier);
        memcpy(&packet[16], neutral, sizeof(neutral));
        if (send(_udpSocketFD, packet, sizeof(packet), 0) == sizeof(packet)) {
            @synchronized (self) { _packetsSent++; }
        }
    }
}

- (void)connectVsockIfNeeded
{
    if (![self usingVsockTransport] || !_vsockDeviceAvailable || _vsockFD >= 0 ||
        _vsockConnecting)
        return;
    BOOL active;
    @synchronized (self) {
        active = (_enabled || _vsockTestPending) && _foregroundActive &&
            _configured;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (!active || now < _nextVsockConnectTime)
        return;
    _vsockConnecting = YES;
    uint64_t generation = [self currentVsockGeneration];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != [self currentVsockGeneration])
            return;
        BOOL stillActive;
        @synchronized (self) {
            stillActive = [self->_transport isEqualToString:
                VZGamepadTransportVirtioSocket] &&
                (self->_enabled || self->_vsockTestPending) &&
                self->_foregroundActive && self->_configured;
        }
        id device = self->_mainVsockDevice;
        if (!stillActive || !device) {
            dispatch_async(self->_networkQueue, ^{
                if (generation == [self currentVsockGeneration]) {
                    self->_vsockConnecting = NO;
                    [self updateHeartbeatInterval];
                    [self publishState:YES];
                }
            });
            return;
        }
        void (^handler)(id, NSError *) = ^(id connection, NSError *error) {
            if (pthread_main_np()) {
                [self handleVsockCompletionOnMainConnection:connection
                    error:error generation:generation];
            } else {
                // Retain callback arguments until their only permitted access
                // point on main. The normal iPadOS 16 path already calls back
                // on main, but do not rely on that undocumented behavior.
                id retainedConnection = [connection retain];
                NSError *retainedError = [error retain];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self handleVsockCompletionOnMainConnection:
                        retainedConnection error:retainedError
                        generation:generation];
                    [retainedConnection release];
                    [retainedError release];
                });
            }
        };
        ((void(*)(id, SEL, uint32_t, id))objc_msgSend)(device,
            sel_registerName("connectToPort:completionHandler:"),
            VZGamepadVsockPort, handler);
    });
}

- (void)handleVsockCompletionOnMainConnection:(id)connection
    error:(NSError *)error generation:(uint64_t)generation
{
    NSCAssert(pthread_main_np(), @"Virtio Socket completion must run on main");
    if (generation != [self currentVsockGeneration])
        return;
    VZGamepadConnectResult *result = calloc(1, sizeof(*result));
    if (!result) {
        dispatch_async(_networkQueue, ^{
            if (generation == [self currentVsockGeneration]) {
                self->_vsockConnecting = NO;
                [self setLastError:
                    @"Could not allocate Virtio Socket connection state"];
                [self resetVsockConnectionSchedulingReconnect:YES];
                [self updateHeartbeatInterval];
                [self publishState:YES];
            }
        });
        return;
    }
    result->generation = generation;
    result->descriptor = -1;
    if (connection && !error) {
        result->descriptor = (int)((NSInteger(*)(id, SEL))objc_msgSend)(
            connection, sel_registerName("fileDescriptor"));
        [_mainVsockConnection release];
        _mainVsockConnection = [connection retain];
    } else {
        result->errorDescription = [[error localizedDescription] copy];
    }
    dispatch_async(_networkQueue, ^{
        if (result->generation != [self currentVsockGeneration] ||
            ![self usingVsockTransport]) {
            [result->errorDescription release];
            free(result);
            return;
        }
        self->_vsockConnecting = NO;
        if (result->descriptor < 0) {
            [self setLastError:[NSString stringWithFormat:
                @"Virtio Socket connect failed: %@",
                result->errorDescription ?: @"no connection"]];
            [self resetVsockConnectionSchedulingReconnect:YES];
            [self updateHeartbeatInterval];
            [self publishState:YES];
            [result->errorDescription release];
            free(result);
            return;
        }
        int descriptor = result->descriptor;
        int flags = fcntl(descriptor, F_GETFL, 0);
        if (flags < 0 ||
            fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
            [self setLastError:@"Could not make Virtio Socket nonblocking"];
            [self resetVsockConnectionSchedulingReconnect:YES];
            [self updateHeartbeatInterval];
            [self publishState:YES];
            [result->errorDescription release];
            free(result);
            return;
        }
        int noSignal = 1;
        (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignal, sizeof(noSignal));
        self->_vsockFD = descriptor;
        self->_vsockRetryDelay = 0.25;
        self->_nextVsockConnectTime = 0;
        [self->_vsockWriteBuffer setLength:0];
        [self->_vsockReadBuffer setLength:0];
        self->_havePendingAnalogReport = NO;
        self->_haveLastSentReport = NO;
        [self setLastError:nil];
        printf("[VirtualMac] gamepad Virtio Socket connected port=%u fd=%d\n",
               VZGamepadVsockPort, descriptor);
        [self sendNeutralReportOnNetworkQueue];
        BOOL testPending = self->_vsockTestPending;
        self->_vsockTestPending = NO;
        [self transmitCurrentStateAllowDisabled:testPending];
        [self updateHeartbeatInterval];
        [self publishState:YES];
        [result->errorDescription release];
        free(result);
    });
}

- (void)configureSocketForAddress:(struct in_addr)address
    port:(uint16_t)port valid:(BOOL)valid generation:(uint64_t)generation
    destination:(NSString *)destinationText
{
    @synchronized (self) {
        if (generation != _configurationGeneration)
            return;
    }
    if (_udpSocketFD >= 0)
        [self sendNeutralReportOnNetworkQueue];
    if (_udpSocketFD >= 0) {
        close(_udpSocketFD);
        _udpSocketFD = -1;
    }
    if (!valid) {
        BOOL enabled;
        @synchronized (self) { enabled = _enabled; }
        if (enabled)
            printf("[VirtualMac] gamepad relay needs IPv4 destination host:port\n");
        [self setLastError:destinationText.length
            ? @"Invalid destination address" : nil];
        [self publishState:YES];
        [self updateHeartbeatInterval];
        return;
    }
    _udpSocketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (_udpSocketFD < 0) {
        perror("[VirtualMac] gamepad UDP socket");
        @synchronized (self) {
            if (generation == _configurationGeneration)
                _configured = NO;
        }
        [self setLastError:@"Could not create the UDP socket"];
        [self publishState:YES];
        [self updateHeartbeatInterval];
        return;
    }
    int flags = fcntl(_udpSocketFD, F_GETFL, 0);
    if (flags >= 0)
        (void)fcntl(_udpSocketFD, F_SETFL, flags | O_NONBLOCK);
    int trafficClass = IPTOS_LOWDELAY;
    (void)setsockopt(_udpSocketFD, IPPROTO_IP, IP_TOS,
        &trafficClass, sizeof(trafficClass));
#if defined(SO_NET_SERVICE_TYPE) && defined(NET_SERVICE_TYPE_VO)
    int serviceType = NET_SERVICE_TYPE_VO;
    (void)setsockopt(_udpSocketFD, SOL_SOCKET, SO_NET_SERVICE_TYPE,
        &serviceType, sizeof(serviceType));
#endif
    memset(&_destination, 0, sizeof(_destination));
    _destination.sin_family = AF_INET;
    _destination.sin_port = htons((uint16_t)port);
    _destination.sin_addr = address;
    if (connect(_udpSocketFD, (const struct sockaddr *)&_destination,
                sizeof(_destination)) != 0) {
        [self setLastError:[NSString stringWithFormat:@"UDP connect failed: %s",
            strerror(errno)]];
        close(_udpSocketFD);
        _udpSocketFD = -1;
        @synchronized (self) {
            if (generation == _configurationGeneration)
                _configured = NO;
        }
        [self publishState:YES];
        [self updateHeartbeatInterval];
        return;
    }
    [self setLastError:nil];
    _haveLastSentReport = NO;
    _repeatsRemaining = 0;
    _lastTransmitTime = 0;
    _lastSendFailureTime = 0;
    memset(_digitalHoldUntil, 0, sizeof(_digitalHoldUntil));
    BOOL enabled = NO;
    BOOL staleConfiguration;
    @synchronized (self) {
        staleConfiguration = generation != _configurationGeneration;
        if (!staleConfiguration) {
            _configured = YES;
            enabled = _enabled;
        }
    }
    if (staleConfiguration) {
        close(_udpSocketFD);
        _udpSocketFD = -1;
        [self updateHeartbeatInterval];
        return;
    }
    printf("[VirtualMac] gamepad relay destination=%s\n",
        destinationText.UTF8String);
    if (enabled)
        [self sendNeutralReportOnNetworkQueue];
    [self updateHeartbeatInterval];
    [self publishState:YES];
}

- (void)controllerDidConnect:(NSNotification *)notification
{
    GCController *controller = notification.object;
    printf("[VirtualMac] gamepad connected vendor=%s profile=%p\n",
        controller.vendorName.UTF8String ?: "(unknown)",
        controller.extendedGamepad);
    [self selectController];
    [self publishState:YES];
}

- (void)controllerDidDisconnect:(NSNotification *)notification
{
    GCController *controller = notification.object;
    printf("[VirtualMac] gamepad disconnected vendor=%s\n",
        controller.vendorName.UTF8String ?: "(unknown)");
    GCController *disconnected = [controller retain];
    dispatch_async(_networkQueue, ^{
        BOOL selectedController = NO;
        @synchronized (self) {
            if (disconnected == _pendingController) {
                [_pendingController release];
                _pendingController = nil;
            }
            if (disconnected == _controller) {
                selectedController = YES;
                VZClearDigitalHandlers(_controller);
                _controller.handlerQueue = dispatch_get_main_queue();
                [_controller release];
                _controller = nil;
                // Invalidate callbacks that GameController had already queued
                // before its handlers were cleared.
                _controllerGeneration++;
            }
        }
        if (selectedController)
            [self sendNeutralReportOnNetworkQueue];
        [disconnected release];
        [self updateHeartbeatInterval];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self publishState:YES];
            [self selectController];
        });
    });
}

- (void)selectController
{
    GCController *selected = nil;
    for (GCController *candidate in GCController.controllers) {
        if (candidate.extendedGamepad) {
            selected = candidate;
            break;
        }
    }
    @synchronized (self) {
        if (selected == _controller) {
            [_pendingController release];
            _pendingController = nil;
            return;
        }
        if (selected == _pendingController)
            return;
        [_pendingController release];
        _pendingController = [selected retain];
    }
    GCController *controller = [selected retain];
    dispatch_async(_networkQueue, ^{
        [self installSelectedController:controller];
        [controller release];
    });
}

- (void)installSelectedController:(GCController *)controller
{
    uint64_t controllerGeneration;
    @synchronized (self) {
        if (controller != _pendingController)
            return;
        // Allocate, rather than derive, a callback token. A failed install may
        // already have enqueued handler work, so no later controller may reuse
        // that attempt's identity.
        controllerGeneration = ++_nextControllerGeneration;
        if (controllerGeneration == 0)
            controllerGeneration = ++_nextControllerGeneration;
    }
    if (controller && ![GCController.controllers containsObject:controller]) {
        @synchronized (self) {
            if (controller == _pendingController) {
                [_pendingController release];
                _pendingController = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self selectController]; });
        return;
    }
    if (controller) {
        controller.handlerQueue = _networkQueue;
        controller.extendedGamepad.valueChangedHandler = nil;
        __unsafe_unretained VZGamepadBridge *bridge = self;
        GCExtendedGamepad *pad = controller.extendedGamepad;
        VZSetPressedHandler(pad.buttonA,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:0 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.buttonB,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:1 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.buttonX,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:2 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.buttonY,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:3 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.leftShoulder,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:4 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.rightShoulder,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:5 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.leftThumbstickButton,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:6 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.rightThumbstickButton,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:7 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.leftTrigger,
            ^(float value, BOOL pressed) {
                [bridge transmitTriggerAtOffset:11 value:value pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.rightTrigger,
            ^(float value, BOOL pressed) {
                [bridge transmitTriggerAtOffset:13 value:value pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.buttonMenu,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:8 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.buttonOptions,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:9 pressed:pressed
                    generation:controllerGeneration];
            });
        VZSetPressedHandler(pad.buttonHome,
            ^(float value, BOOL pressed) {
                (void)value;
                [bridge transmitButtonBit:10 pressed:pressed
                    generation:controllerGeneration];
            });
        pad.dpad.valueChangedHandler =
            ^(GCControllerDirectionPad *dpad, float x, float y) {
                (void)dpad;
                [bridge transmitDpadX:x y:y
                    generation:controllerGeneration];
            };
    }
    BOOL stillPending;
    @synchronized (self) {
        stillPending = controller == _pendingController;
        if (stillPending) {
            if (_controller.handlerQueue == _networkQueue) {
                VZClearDigitalHandlers(_controller);
                _controller.handlerQueue = dispatch_get_main_queue();
            }
            [_controller release];
            _controller = [controller retain];
            _controllerGeneration = controllerGeneration;
            [_pendingController release];
            _pendingController = nil;
        }
    }
    if (!stillPending) {
        VZClearDigitalHandlers(controller);
        if (controller.handlerQueue == _networkQueue)
            controller.handlerQueue = dispatch_get_main_queue();
        return;
    }
    if (!controller)
    {
        [self publishState:YES];
        return;
    }
    printf("[VirtualMac] gamepad selected vendor=%s\n",
        controller.vendorName.UTF8String ?: "(unknown)");
    // Poll the profile from the bounded 120 Hz timer. Registering a per-element
    // analog callback here makes trigger/stick noise enqueue work faster than
    // it can be consumed. Digital edge callbacks above execute on this same
    // serial queue and only add work for real button/D-pad changes.
    controller.extendedGamepad.valueChangedHandler = nil;
    [self transmitTick];
    [self publishState:YES];
}

- (void)fillReport:(uint8_t[VZGamepadReportLength])report
    controller:(GCController *)controller
{
    memset(report, 0, VZGamepadReportLength);
    report[0] = 1;
    report[15] = 8;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad)
        return;
    uint16_t buttons = 0;
    buttons |= VZPressed(pad.buttonA) << 0;
    buttons |= VZPressed(pad.buttonB) << 1;
    buttons |= VZPressed(pad.buttonX) << 2;
    buttons |= VZPressed(pad.buttonY) << 3;
    buttons |= VZPressed(pad.leftShoulder) << 4;
    buttons |= VZPressed(pad.rightShoulder) << 5;
    buttons |= VZPressed(pad.leftThumbstickButton) << 6;
    buttons |= VZPressed(pad.rightThumbstickButton) << 7;
    buttons |= VZPressed(pad.buttonMenu) << 8;
    buttons |= VZPressed(pad.buttonOptions) << 9;
    buttons |= VZPressed(pad.buttonHome) << 10;
    report[1] = (uint8_t)buttons;
    report[2] = (uint8_t)(buttons >> 8);
    int16_t x = VZAxis(pad.leftThumbstick.xAxis.value);
    // Preserve GameController's native macOS coordinate convention: right and
    // up are positive. Consumers that draw in a top-left-origin view normalize
    // Y at their presentation or mapping layer; pre-inverting it here made
    // both sticks appear upside down after selecting the correct X/Y pairs.
    int16_t y = VZAxis(pad.leftThumbstick.yAxis.value);
    int16_t rx = VZAxis(pad.rightThumbstick.xAxis.value);
    int16_t ry = VZAxis(pad.rightThumbstick.yAxis.value);
    uint16_t z = VZTrigger(pad.leftTrigger.value);
    uint16_t rz = VZTrigger(pad.rightTrigger.value);
    memcpy(&report[3], &x, sizeof(x));
    memcpy(&report[5], &y, sizeof(y));
    memcpy(&report[7], &rx, sizeof(rx));
    memcpy(&report[9], &ry, sizeof(ry));
    memcpy(&report[11], &z, sizeof(z));
    memcpy(&report[13], &rz, sizeof(rz));
    float dpadX = pad.dpad.xAxis.value;
    float dpadY = pad.dpad.yAxis.value;
    BOOL up = dpadY > 0.5f, down = dpadY < -0.5f;
    BOOL right = dpadX > 0.5f, left = dpadX < -0.5f;
    if (up && right) report[15] = 1;
    else if (right && down) report[15] = 3;
    else if (down && left) report[15] = 5;
    else if (left && up) report[15] = 7;
    else if (up) report[15] = 0;
    else if (right) report[15] = 2;
    else if (down) report[15] = 4;
    else if (left) report[15] = 6;
}

- (void)sendCurrentState
{
    if (!_networkQueue)
        return;
    if (dispatch_get_specific(VZGamepadNetworkQueueKey) == self)
        [self transmitTick];
    else
        dispatch_async(_networkQueue, ^{ [self transmitTick]; });
}

- (void)transmitTick
{
    if ([self usingVsockTransport]) {
        [self connectVsockIfNeeded];
        [self flushVsockWrites];
        [self receiveVsockAcks];
    } else if (_udpSocketFD >= 0) {
        [self receiveAcksFromSocket:_udpSocketFD];
    }
    [self transmitCurrentStateAllowDisabled:NO];
    if ([self usingVsockTransport]) {
        [self flushVsockWrites];
        [self receiveVsockAcks];
    }
    [self updateHeartbeatInterval];
}

- (void)updateHeartbeatInterval
{
    BOOL active, enabled, foreground, configured, testPending;
    BOOL vsock = [self usingVsockTransport];
    @synchronized (self) {
        enabled = _enabled;
        testPending = _vsockTestPending;
        foreground = _foregroundActive;
        configured = _configured;
        active = (enabled || testPending) && foreground &&
            _controller != nil && configured &&
            (vsock ? _vsockFD >= 0 : _udpSocketFD >= 0);
    }
    unsigned rate = active ? VZGamepadSampleRate :
        (vsock && (enabled || testPending) && foreground && configured &&
            _vsockFD < 0
            ? VZGamepadReconnectPollRate
            : (vsock ? VZGamepadVsockKeepaliveRate
                     : VZGamepadUDPKeepaliveRate));
    uint64_t interval = NSEC_PER_SEC / rate;
    if (!_heartbeat || interval == _heartbeatIntervalNanoseconds)
        return;
    _heartbeatIntervalNanoseconds = interval;
    dispatch_source_set_timer(_heartbeat,
        dispatch_time(DISPATCH_TIME_NOW, interval), interval,
        active ? NSEC_PER_MSEC : NSEC_PER_MSEC * 5);
}

- (void)transmitEventReport:(uint8_t[VZGamepadReportLength])report
{
    @synchronized (self) {
        memcpy(_latestReport, report, sizeof(_latestReport));
    }
    BOOL shouldSend;
    @synchronized (self) {
        shouldSend = _enabled && _foregroundActive && _configured;
    }
    int socketFD = [self usingVsockTransport] ? _vsockFD : _udpSocketFD;
    if (!shouldSend || socketFD < 0)
        return;
    if (![self sendReport:report urgent:YES])
        return;
    CFTimeInterval now = CACurrentMediaTime();
    memcpy(_lastSentReport, report, sizeof(_lastSentReport));
    _haveLastSentReport = YES;
    _repeatsRemaining = [self usingVsockTransport]
        ? 0 : VZGamepadTransitionRepeats;
    _lastRepeatTime = now;
    _lastTransmitTime = now;
}

- (void)transmitButtonBit:(unsigned)bit pressed:(BOOL)pressed
    generation:(uint64_t)generation
{
    uint8_t report[VZGamepadReportLength];
    BOOL wasPressed;
    uint64_t eventToken;
    @synchronized (self) {
        if (generation != _controllerGeneration || !_controller)
            return;
        memcpy(report, _latestReport, sizeof(report));
    }
    eventToken = ++_digitalEventTokens[bit];
    size_t byte = 1 + bit / 8;
    uint8_t mask = (uint8_t)(1u << (bit % 8));
    wasPressed = (report[byte] & mask) != 0;
    CFTimeInterval remaining =
        _digitalHoldUntil[bit] - CACurrentMediaTime();
    if (![self usingVsockTransport] && !pressed && wasPressed && remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(remaining * NSEC_PER_SEC)), _networkQueue, ^{
            if (eventToken != self->_digitalEventTokens[bit])
                return;
            [self transmitButtonBit:bit pressed:NO generation:generation];
        });
        return;
    }
    if (pressed)
        report[byte] |= mask;
    else
        report[byte] &= (uint8_t)~mask;
    if (![self usingVsockTransport] && pressed && !wasPressed)
        _digitalHoldUntil[bit] = CACurrentMediaTime() +
            (double)VZGamepadTransitionHoldTicks / VZGamepadSampleRate;
    [self transmitEventReport:report];
}

- (void)transmitTriggerAtOffset:(size_t)offset value:(float)triggerValue
    pressed:(BOOL)pressed
    generation:(uint64_t)generation
{
    uint8_t report[VZGamepadReportLength];
    uint64_t eventToken;
    @synchronized (self) {
        if (generation != _controllerGeneration || !_controller)
            return;
        memcpy(report, _latestReport, sizeof(report));
    }
    size_t digitalIndex = offset == 11 ? 11 : 12;
    eventToken = ++_digitalEventTokens[digitalIndex];
    uint16_t value = pressed ? VZTrigger(triggerValue) : 0;
    BOOL wasPressed = VZReportTriggerPressed(report, offset);
    CFTimeInterval remaining =
        _digitalHoldUntil[digitalIndex] - CACurrentMediaTime();
    if (![self usingVsockTransport] && !pressed && wasPressed && remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(remaining * NSEC_PER_SEC)), _networkQueue, ^{
            if (eventToken != self->_digitalEventTokens[digitalIndex])
                return;
            [self transmitTriggerAtOffset:offset value:0 pressed:NO
                generation:generation];
        });
        return;
    }
    if (![self usingVsockTransport] && pressed && !wasPressed)
        _digitalHoldUntil[digitalIndex] = CACurrentMediaTime() +
            (double)VZGamepadTransitionHoldTicks / VZGamepadSampleRate;
    if (pressed && value < UINT16_C(32768))
        value = UINT16_C(32768);
    memcpy(&report[offset], &value, sizeof(value));
    [self transmitEventReport:report];
}

- (void)transmitDpadX:(float)x y:(float)y
    generation:(uint64_t)generation
{
    uint8_t report[VZGamepadReportLength];
    uint64_t eventToken;
    @synchronized (self) {
        if (generation != _controllerGeneration || !_controller)
            return;
        memcpy(report, _latestReport, sizeof(report));
    }
    eventToken = ++_digitalEventTokens[13];
    BOOL up = y > 0.5f, down = y < -0.5f;
    BOOL right = x > 0.5f, left = x < -0.5f;
    report[15] = 8;
    if (up && right) report[15] = 1;
    else if (right && down) report[15] = 3;
    else if (down && left) report[15] = 5;
    else if (left && up) report[15] = 7;
    else if (up) report[15] = 0;
    else if (right) report[15] = 2;
    else if (down) report[15] = 4;
    else if (left) report[15] = 6;
    uint8_t previousHat;
    @synchronized (self) { previousHat = _latestReport[15]; }
    CFTimeInterval remaining =
        _digitalHoldUntil[13] - CACurrentMediaTime();
    if (![self usingVsockTransport] && report[15] == 8 &&
        previousHat != 8 && remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(remaining * NSEC_PER_SEC)), _networkQueue, ^{
            if (eventToken != self->_digitalEventTokens[13])
                return;
            [self transmitDpadX:0 y:0 generation:generation];
        });
        return;
    }
    if (![self usingVsockTransport] && report[15] != 8 &&
        report[15] != previousHat)
        _digitalHoldUntil[13] = CACurrentMediaTime() +
            (double)VZGamepadTransitionHoldTicks / VZGamepadSampleRate;
    [self transmitEventReport:report];
}

- (void)transmitCurrentStateAllowDisabled:(BOOL)allowDisabled
{
    BOOL shouldSend;
    GCController *controller;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL holdDigitalState[VZGamepadDigitalControlCount] = {0};
    BOOL holdAnyDigitalState = NO;
    uint8_t heldReport[VZGamepadReportLength];
    @synchronized (self) {
        shouldSend = (allowDisabled || _enabled) && _foregroundActive &&
            _configured;
        controller = [_controller retain];
        memcpy(heldReport, _latestReport, sizeof(heldReport));
        for (unsigned index = 0; index < VZGamepadDigitalControlCount;
             index++) {
            holdDigitalState[index] = now < _digitalHoldUntil[index];
            holdAnyDigitalState |= holdDigitalState[index];
        }
    }
    uint8_t report[VZGamepadReportLength];
    [self fillReport:report controller:controller];
    BOOL vsock = [self usingVsockTransport];
    for (unsigned index = 0; index < VZGamepadDigitalControlCount; index++) {
        if (!vsock && holdDigitalState[index])
            VZCopyDigitalControlState(report, heldReport, index);
    }
    [controller release];
    @synchronized (self) {
        memcpy(_latestReport, report, sizeof(_latestReport));
    }
    // Keep the local live-input view current even when forwarding is off.
    int socketFD = vsock ? _vsockFD : _udpSocketFD;
    if (!shouldSend || socketFD < 0)
        return;
    // A disconnected route can make connected UDP fail every tick. Retry at
    // keepalive rate while failed so a missing receiver cannot consume the
    // high-priority queue at 120 Hz; any success immediately removes backoff.
    if (_lastSendFailureTime > 0 &&
        now - _lastSendFailureTime < 1.0 / VZGamepadUDPKeepaliveRate &&
        !holdAnyDigitalState)
        return;
    BOOL changed = !_haveLastSentReport ||
        memcmp(report, _lastSentReport, sizeof(_lastSentReport)) != 0;
    BOOL digitalChanged = !_haveLastSentReport ||
        !VZReportsHaveSameDigitalState(report, _lastSentReport);
    if (!vsock && !changed && _repeatsRemaining > 0 && _lastRepeatTime > 0 &&
        now - _lastRepeatTime < 1.0 / VZGamepadSampleRate)
        return;
    unsigned keepaliveRate = vsock ? VZGamepadVsockKeepaliveRate
                                   : VZGamepadUDPKeepaliveRate;
    if (!changed && _repeatsRemaining == 0 && _lastTransmitTime > 0 &&
        now - _lastTransmitTime < 1.0 / keepaliveRate)
        return;
    BOOL sent = [self sendReport:report urgent:digitalChanged];
    if (sent) {
        if (vsock)
            _repeatsRemaining = 0;
        else if (digitalChanged)
            // Repeat the latest full state on the next two 120 Hz ticks. This
            // spaces redundancy across independent network scheduling windows
            // without ever replaying an obsolete press over a newer release.
            _repeatsRemaining = VZGamepadTransitionRepeats;
        else if (changed)
            _repeatsRemaining = VZGamepadTransitionRepeats;
        else if (_repeatsRemaining > 0)
            _repeatsRemaining--;
        _lastRepeatTime = now;
        memcpy(_lastSentReport, report, sizeof(_lastSentReport));
        _haveLastSentReport = YES;
        _lastTransmitTime = now;
    }
}

- (void)sendNeutralReport
{
    if (!_networkQueue)
        return;
    dispatch_async(_networkQueue, ^{ [self sendNeutralReportOnNetworkQueue]; });
}

- (void)sendNeutralReportOnNetworkQueue
{
    uint8_t neutral[VZGamepadReportLength] = {0};
    neutral[0] = 1;
    neutral[15] = 8;
    @synchronized (self) {
        memcpy(_latestReport, neutral, sizeof(_latestReport));
    }
    memset(_digitalHoldUntil, 0, sizeof(_digitalHoldUntil));
    for (unsigned index = 0; index < VZGamepadDigitalControlCount; index++)
        _digitalEventTokens[index]++;
    BOOL vsock = [self usingVsockTransport];
    int socketFD = vsock ? _vsockFD : _udpSocketFD;
    if (socketFD < 0)
        return;
    // Lifecycle suspension and controller removal can stop future timers.
    // Send the release state redundantly now instead of relying on a later
    // keepalive or the guest's relatively slow timeout.
    BOOL sent = NO;
    unsigned copies = vsock ? 1 : VZGamepadTransitionRepeats + 1;
    for (unsigned copy = 0; copy < copies; copy++)
        sent |= [self sendReport:neutral urgent:YES];
    memcpy(_lastSentReport, neutral, sizeof(_lastSentReport));
    _haveLastSentReport = sent;
    _repeatsRemaining = 0;
    if (sent)
        _lastTransmitTime = CACurrentMediaTime();
}

- (BOOL)sendReport:(const uint8_t[VZGamepadReportLength])report
    urgent:(BOOL)urgent
{
    BOOL vsock = [self usingVsockTransport];
    if (vsock && !urgent && _vsockWriteBuffer.length > 0) {
        memcpy(_pendingAnalogReport, report, sizeof(_pendingAnalogReport));
        _havePendingAnalogReport = YES;
        return YES;
    }
    if (vsock && urgent)
        // Every digital packet is a full state, so it supersedes an analog-only
        // state that has not entered the FIFO yet. This prevents an old report
        // from replaying over a newer press/release after the queue drains.
        _havePendingAnalogReport = NO;
    uint8_t packet[VZGamepadPacketLength] = {0};
    VZWriteBE32(&packet[0], 0x564D4750); // VMGP
    packet[4] = 1;
    packet[5] = 1;
    CFTimeInterval now = CACurrentMediaTime();
    VZWriteBE16(&packet[6], VZGamepadReportLength);
    uint32_t sequence = ++_sequence;
    VZWriteBE32(&packet[8], sequence);
    VZWriteBE32(&packet[12], _sessionIdentifier);
    memcpy(&packet[16], report, VZGamepadReportLength);
    if (vsock) {
        if (_vsockFD < 0)
            return NO;
        if (_vsockWriteBuffer.length + sizeof(packet) >
            VZGamepadVsockMaximumQueuedFrames * VZGamepadPacketLength) {
            [self setLastError:@"Virtio Socket send queue overflow; reconnecting"];
            [self resetVsockConnectionSchedulingReconnect:YES];
            [self publishState:YES];
            return NO;
        }
        [_vsockWriteBuffer appendBytes:packet length:sizeof(packet)];
        @synchronized (self) {
            _packetsSent++;
            NSUInteger index = sequence % 256;
            _sentSequenceRing[index] = sequence;
            _sentTimeRing[index] = now;
        }
        [self flushVsockWrites];
        return _vsockFD >= 0;
    }
    ssize_t sent = send(_udpSocketFD, packet, sizeof(packet), 0);
    if (sent != sizeof(packet)) {
        int error = errno;
        now = CACurrentMediaTime();
        BOOL errorChanged = error != _lastSendError;
        if (errorChanged ||
            now - _lastSendErrorLogTime >= 1.0) {
            fprintf(stderr, "[VirtualMac] gamepad UDP send: %s\n",
                strerror(error));
            _lastSendError = error;
            _lastSendErrorLogTime = now;
        }
        if (errorChanged) {
            [self setLastError:[NSString stringWithFormat:
                @"UDP send failed: %s", strerror(error)]];
        }
        _lastSendFailureTime = now;
        // The settings page polls its snapshot. Do not enqueue a main-thread
        // notification for every failed 120 Hz sample while a route is down.
        return NO;
    } else {
        _lastSendError = 0;
        _lastSendFailureTime = 0;
        [self setLastError:nil];
        @synchronized (self) {
            _packetsSent++;
            NSUInteger index = sequence % 256;
            _sentSequenceRing[index] = sequence;
            _sentTimeRing[index] = now;
        }
        return YES;
    }
}

- (void)flushVsockWrites
{
    if (_vsockFD < 0)
        return;
    while (_vsockWriteBuffer.length > 0) {
        ssize_t sent = send(_vsockFD, _vsockWriteBuffer.bytes,
            _vsockWriteBuffer.length, 0);
        if (sent > 0) {
            [_vsockWriteBuffer replaceBytesInRange:
                NSMakeRange(0, (NSUInteger)sent) withBytes:NULL length:0];
            continue;
        }
        if (sent < 0 && errno == EINTR)
            continue;
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return;
        int error = sent == 0 ? ECONNRESET : errno;
        [self setLastError:[NSString stringWithFormat:
            @"Virtio Socket write failed: %s", strerror(error)]];
        [self resetVsockConnectionSchedulingReconnect:YES];
        [self publishState:YES];
        return;
    }
    if (_havePendingAnalogReport) {
        uint8_t pending[VZGamepadReportLength];
        memcpy(pending, _pendingAnalogReport, sizeof(pending));
        _havePendingAnalogReport = NO;
        (void)[self sendReport:pending urgent:NO];
    }
}

- (BOOL)handleAckBytes:(const uint8_t[VZGamepadAckLength])ack
{
    uint32_t magic = ((uint32_t)ack[0] << 24) |
        ((uint32_t)ack[1] << 16) | ((uint32_t)ack[2] << 8) | ack[3];
    uint32_t sequence = ((uint32_t)ack[8] << 24) |
        ((uint32_t)ack[9] << 16) | ((uint32_t)ack[10] << 8) | ack[11];
    uint32_t session = ((uint32_t)ack[12] << 24) |
        ((uint32_t)ack[13] << 16) | ((uint32_t)ack[14] << 8) | ack[15];
    if (magic != 0x564D4741 || ack[4] != 1 || ack[5] != 2 ||
        session != _sessionIdentifier)
        return NO;
    @synchronized (self) {
        _acksReceived++;
        _lastAckSequence = sequence;
        _lastAckTime = CACurrentMediaTime();
        NSUInteger sentIndex = sequence % 256;
        if (_sentSequenceRing[sentIndex] == sequence &&
            _sentTimeRing[sentIndex] > 0) {
            _lastRTTMilliseconds = (_lastAckTime -
                _sentTimeRing[sentIndex]) * 1000.0;
            _rttSamples[_rttSampleIndex++ % 256] = _lastRTTMilliseconds;
            if (_rttSampleCount < 256)
                _rttSampleCount++;
        }
    }
    if (_lastSendFailureTime == 0)
        [self setLastError:nil];
    return YES;
}

- (void)receiveVsockAcks
{
    if (_vsockFD < 0)
        return;
    for (;;) {
        uint8_t incoming[256];
        ssize_t received = recv(_vsockFD, incoming, sizeof(incoming), 0);
        if (received > 0) {
            [_vsockReadBuffer appendBytes:incoming length:(NSUInteger)received];
            continue;
        }
        if (received < 0 && errno == EINTR)
            continue;
        if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        int error = received == 0 ? ECONNRESET : errno;
        [self setLastError:[NSString stringWithFormat:
            @"Virtio Socket disconnected: %s", strerror(error)]];
        [self resetVsockConnectionSchedulingReconnect:YES];
        [self publishState:YES];
        return;
    }
    while (_vsockReadBuffer.length >= VZGamepadAckLength) {
        uint8_t ack[VZGamepadAckLength];
        memcpy(ack, _vsockReadBuffer.bytes, sizeof(ack));
        [_vsockReadBuffer replaceBytesInRange:
            NSMakeRange(0, sizeof(ack)) withBytes:NULL length:0];
        if (![self handleAckBytes:ack]) {
            [self setLastError:@"Invalid Virtio Socket ACK; reconnecting"];
            [self resetVsockConnectionSchedulingReconnect:YES];
            [self publishState:YES];
            return;
        }
    }
}

- (void)receiveAcksFromSocket:(int)socketFD
{
    if (socketFD < 0)
        return;
    for (unsigned batch = 0; batch < 32; batch++) {
        uint8_t ack[VZGamepadAckLength];
        ssize_t received = recv(socketFD, ack, sizeof(ack), 0);
        if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        if (received < 0) {
            // Transient UDP receive errors must not affect the input path.
            if (errno == EINTR)
                continue;
            break;
        }
        if (received != sizeof(ack))
            break;
        (void)[self handleAckBytes:ack];
    }
}

- (void)setLastError:(NSString * _Nullable)error
{
    @synchronized (self) {
        if (_lastError == error || (error && [_lastError isEqualToString:error]))
            return;
        [_lastError release];
        _lastError = [error copy];
    }
}

- (NSDictionary *)stateSnapshot
{
    uint8_t report[VZGamepadReportLength];
    BOOL enabled, configured, foreground, controllerConnected;
    BOOL transportConnected, connecting;
    NSString *controllerName, *destination, *lastError, *transport;
    uint64_t packetsSent, acksReceived;
    uint32_t lastAckSequence;
    CFTimeInterval lastAckTime;
    double lastRTTMilliseconds;
    double rttSamples[256];
    NSUInteger rttSampleCount;
    @synchronized (self) {
        memcpy(report, _latestReport, sizeof(report));
        enabled = _enabled;
        configured = _configured;
        foreground = _foregroundActive;
        controllerConnected = _controller != nil;
        controllerName = [(_controller.vendorName ?: @"") retain];
        destination = [(_destinationText ?: @"") retain];
        transport = [(_transport ?: VZGamepadTransportVirtioSocket) retain];
        lastError = [(_lastError ?: @"") retain];
        BOOL vsock = [transport isEqualToString:
            VZGamepadTransportVirtioSocket];
        transportConnected = vsock ? _vsockFD >= 0 : _udpSocketFD >= 0;
        connecting = vsock && _vsockConnecting;
        packetsSent = _packetsSent;
        acksReceived = _acksReceived;
        lastAckSequence = _lastAckSequence;
        lastAckTime = _lastAckTime;
        lastRTTMilliseconds = _lastRTTMilliseconds;
        rttSampleCount = _rttSampleCount;
        memcpy(rttSamples, _rttSamples,
               rttSampleCount * sizeof(rttSamples[0]));
    }
    int16_t x, y, rx, ry;
    uint16_t z, rz;
    memcpy(&x, &report[3], sizeof(x));
    memcpy(&y, &report[5], sizeof(y));
    memcpy(&rx, &report[7], sizeof(rx));
    memcpy(&ry, &report[9], sizeof(ry));
    memcpy(&z, &report[11], sizeof(z));
    memcpy(&rz, &report[13], sizeof(rz));
    uint16_t buttons = (uint16_t)report[1] | (uint16_t)report[2] << 8;
    CFTimeInterval ackAge = lastAckTime > 0
        ? CACurrentMediaTime() - lastAckTime : -1;
    qsort(rttSamples, rttSampleCount, sizeof(rttSamples[0]), VZCompareDouble);
    double rttP95Milliseconds = rttSampleCount
        ? rttSamples[(NSUInteger)floor((rttSampleCount - 1) * 0.95)] : -1;
    NSDictionary *snapshot = @{
        @"enabled": @(enabled),
        @"configured": @(configured),
        @"foreground": @(foreground),
        @"controllerConnected": @(controllerConnected),
        @"controllerName": controllerName,
        @"destination": destination,
        @"transport": transport,
        @"transportConnected": @(transportConnected),
        @"connecting": @(connecting),
        @"packetsSent": @(packetsSent),
        @"acksReceived": @(acksReceived),
        @"lastAckSequence": @(lastAckSequence),
        @"lastAckAge": @(ackAge),
        @"lastRTTMilliseconds": @(lastRTTMilliseconds),
        @"rttP95Milliseconds": @(rttP95Milliseconds),
        @"lastError": lastError,
        @"buttons": @(buttons),
        @"leftX": @((float)x / 32767.0f),
        @"leftY": @((float)y / 32767.0f),
        @"rightX": @((float)rx / 32767.0f),
        @"rightY": @((float)ry / 32767.0f),
        @"leftTrigger": @((float)z / 65535.0f),
        @"rightTrigger": @((float)rz / 65535.0f),
        @"hat": @(report[15]),
    };
    [controllerName release];
    [destination release];
    [transport release];
    [lastError release];
    return snapshot;
}

- (void)publishState:(BOOL)immediate
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self publishState:immediate]; });
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (!immediate && now - _lastStateNotificationTime < 0.10)
        return;
    _lastStateNotificationTime = now;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:VZGamepadBridgeStateDidChangeNotification
        object:self userInfo:[self stateSnapshot]];
}

- (void)sendTestState
{
    BOOL configured, vsock;
    @synchronized (self) {
        configured = _configured;
        vsock = [_transport isEqualToString:VZGamepadTransportVirtioSocket];
    }
    if (!configured) {
        [self setLastError:vsock
            ? @"Start the VM before connecting the Virtio Socket receiver"
            : @"Enter a valid guest IPv4 address and port first"];
        [self publishState:YES];
        return;
    }
    dispatch_async(_networkQueue, ^{
        if (vsock && self->_vsockFD < 0) {
            [self setLastError:@"Waiting for the guest Virtio Socket receiver"];
            self->_vsockTestPending = YES;
            [self connectVsockIfNeeded];
            [self publishState:YES];
            return;
        }
        [self transmitCurrentStateAllowDisabled:YES];
    });
}

- (void)setForegroundActive:(BOOL)active
{
    @synchronized (self) {
        if (_foregroundActive == active)
            return;
        _foregroundActive = active;
    }
    if (!active) {
        if (!_networkQueue)
            return;
        // Invalidate already-enqueued main-thread connects and completions
        // before waiting for the network queue to neutralize the device.
        [self advanceVsockGeneration];
        // applicationWillResignActive has only a short execution window. Put
        // neutralization at the front of the serial queue synchronously so it
        // cannot be lost behind pending timer/ACK work before suspension.
        if (dispatch_get_specific(VZGamepadNetworkQueueKey) == self) {
            [self sendNeutralReportOnNetworkQueue];
            [self resetVsockConnectionSchedulingReconnect:NO];
            [self updateHeartbeatInterval];
        } else {
            dispatch_sync(_networkQueue,
                ^{
                    [self sendNeutralReportOnNetworkQueue];
                    [self resetVsockConnectionSchedulingReconnect:NO];
                    [self updateHeartbeatInterval];
                });
        }
    } else {
        dispatch_async(_networkQueue, ^{
            [self connectVsockIfNeeded];
            [self transmitTick];
        });
    }
}

- (void)neutralize
{
    [self sendNeutralReport];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // The bridge is a process-lifetime singleton, but keep teardown ordered so
    // a future non-singleton use cannot enqueue work after self is released.
    if (_networkQueue && (_udpSocketFD >= 0 || _vsockFD >= 0)) {
        if (dispatch_get_specific(VZGamepadNetworkQueueKey) == self)
            [self sendNeutralReportOnNetworkQueue];
        else
            dispatch_sync(_networkQueue,
                ^{ [self sendNeutralReportOnNetworkQueue]; });
    }
    if (_heartbeat) {
        dispatch_source_cancel(_heartbeat);
        dispatch_release(_heartbeat);
        _heartbeat = NULL;
    }
    if (_udpSocketFD >= 0) {
        close(_udpSocketFD);
        _udpSocketFD = -1;
    }
    _vsockFD = -1;
    if (_controller.handlerQueue == _networkQueue) {
        VZClearDigitalHandlers(_controller);
        _controller.handlerQueue = dispatch_get_main_queue();
    }
    if (_networkQueue)
        dispatch_release(_networkQueue);
    [_controller release];
    [_pendingController release];
    [_destinationText release];
    [_transport release];
    [_lastError release];
    // The shared bridge is process-lifetime and is created on main. Keep a
    // defensive assertion so a future non-singleton owner cannot release
    // Virtualization runtime objects from an arbitrary queue.
    NSCAssert(pthread_main_np(), @"VZGamepadBridge must deallocate on main");
    [_mainVsockConnection release];
    [_mainVsockDevice release];
    [_mainVirtualMachine release];
    [_vsockWriteBuffer release];
    [_vsockReadBuffer release];
    [super dealloc];
}
@end
