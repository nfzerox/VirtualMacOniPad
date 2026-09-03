#import "VZGamepadSettingsViewController.h"
#import "VZAppSettings.h"
#import "VZGamepadBridge.h"
#include <arpa/inet.h>

static NSString *VZGPText(const char *text)
{
    return [NSString stringWithUTF8String:text];
}

@interface VZGamepadSettingsViewController () <UITextFieldDelegate>
@property(nonatomic, retain) UISwitch *enabledSwitch;
@property(nonatomic, retain) UISwitch *udpCompatibilitySwitch;
@property(nonatomic, retain) UITextField *addressField;
@property(nonatomic, retain) UITextField *portField;
@property(nonatomic, retain) UIStackView *destinationRow;
@property(nonatomic, retain) UIButton *saveButton;
@property(nonatomic, retain) UILabel *hintLabel;
@property(nonatomic, retain) UILabel *controllerLabel;
@property(nonatomic, retain) UILabel *networkLabel;
@property(nonatomic, retain) UILabel *inputLabel;
@property(nonatomic, retain) UIButton *testButton;
@property(nonatomic, retain) NSTimer *refreshTimer;
@property(nonatomic, retain) NSString *transientMessage;
@end

@implementation VZGamepadSettingsViewController

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color
{
    UILabel *label = [[[UILabel alloc] init] autorelease];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIStackView *)cardWithTitle:(NSString *)title views:(NSArray *)views
{
    UILabel *heading = [self labelWithFont:
        [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]
        color:UIColor.labelColor];
    heading.text = title;
    NSMutableArray *all = [NSMutableArray arrayWithObject:heading];
    [all addObjectsFromArray:views];
    UIStackView *card = [[[UIStackView alloc] initWithArrangedSubviews:all]
        autorelease];
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 12;
    card.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    card.layoutMarginsRelativeArrangement = YES;
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    return card;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = VZGPText("Gamepad Relay");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scroll = [[[UIScrollView alloc] init] autorelease];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *content = [[[UIStackView alloc] init] autorelease];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    self.enabledSwitch = [[[UISwitch alloc] init] autorelease];
    UILabel *enabledText = [self labelWithFont:[UIFont preferredFontForTextStyle:
        UIFontTextStyleBody] color:UIColor.labelColor];
    enabledText.text = VZGPText("Low-latency adaptive controller relay (up to 120 Hz)");
    UIStackView *enabledRow = [[[UIStackView alloc]
        initWithArrangedSubviews:@[enabledText, self.enabledSwitch]] autorelease];
    enabledRow.axis = UILayoutConstraintAxisHorizontal;
    enabledRow.alignment = UIStackViewAlignmentCenter;
    enabledRow.spacing = 12;
    [enabledText setContentHuggingPriority:UILayoutPriorityDefaultLow
        forAxis:UILayoutConstraintAxisHorizontal];
    [self.enabledSwitch addTarget:self action:@selector(enabledChanged:)
        forControlEvents:UIControlEventValueChanged];

    self.udpCompatibilitySwitch = [[[UISwitch alloc] init] autorelease];
    UILabel *udpText = [self labelWithFont:[UIFont preferredFontForTextStyle:
        UIFontTextStyleBody] color:UIColor.labelColor];
    udpText.text = VZGPText("Enable UDP compatibility mode");
    UIStackView *udpRow = [[[UIStackView alloc]
        initWithArrangedSubviews:@[udpText, self.udpCompatibilitySwitch]]
        autorelease];
    udpRow.axis = UILayoutConstraintAxisHorizontal;
    udpRow.alignment = UIStackViewAlignmentCenter;
    udpRow.spacing = 12;
    [udpText setContentHuggingPriority:UILayoutPriorityDefaultLow
        forAxis:UILayoutConstraintAxisHorizontal];
    [self.udpCompatibilitySwitch addTarget:self
        action:@selector(udpCompatibilityChanged:)
        forControlEvents:UIControlEventValueChanged];

    self.addressField = [[[UITextField alloc] init] autorelease];
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.placeholder = VZGPText("Guest IPv4, for example 192.168.1.50");
    self.addressField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.delegate = self;
    self.portField = [[[UITextField alloc] init] autorelease];
    self.portField.borderStyle = UITextBorderStyleRoundedRect;
    self.portField.placeholder = VZGPText("Port");
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.portField.delegate = self;
    [self.portField.widthAnchor constraintEqualToConstant:105].active = YES;
    self.destinationRow = [[[UIStackView alloc]
        initWithArrangedSubviews:@[self.addressField, self.portField]] autorelease];
    self.destinationRow.axis = UILayoutConstraintAxisHorizontal;
    self.destinationRow.spacing = 10;

    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveButton setTitle:VZGPText("Save and Apply") forState:UIControlStateNormal];
    [self.saveButton addTarget:self action:@selector(saveDestination:)
        forControlEvents:UIControlEventTouchUpInside];
    self.testButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.testButton setTitle:VZGPText("Send Test State")
        forState:UIControlStateNormal];
    [self.testButton addTarget:self action:@selector(sendTest:)
        forControlEvents:UIControlEventTouchUpInside];
    if (@available(iOS 15.0, *)) {
        self.saveButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
        self.testButton.configuration =
            [UIButtonConfiguration borderedButtonConfiguration];
    }
    UIStackView *buttons = [[[UIStackView alloc]
        initWithArrangedSubviews:@[self.saveButton, self.testButton]] autorelease];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 12;
    self.hintLabel = [self labelWithFont:[UIFont preferredFontForTextStyle:
        UIFontTextStyleFootnote] color:UIColor.secondaryLabelColor];
    [content addArrangedSubview:[self cardWithTitle:VZGPText("Connection")
        views:@[enabledRow, udpRow, self.destinationRow,
                buttons, self.hintLabel]]];

    self.controllerLabel = [self labelWithFont:[UIFont monospacedSystemFontOfSize:15
        weight:UIFontWeightRegular] color:UIColor.labelColor];
    self.networkLabel = [self labelWithFont:[UIFont monospacedSystemFontOfSize:15
        weight:UIFontWeightRegular] color:UIColor.labelColor];
    self.inputLabel = [self labelWithFont:[UIFont monospacedSystemFontOfSize:14
        weight:UIFontWeightRegular] color:UIColor.labelColor];
    [content addArrangedSubview:[self cardWithTitle:VZGPText("Status")
        views:@[self.controllerLabel, self.networkLabel]]];
    [content addArrangedSubview:[self cardWithTitle:VZGPText("Live Input")
        views:@[self.inputLabel]]];

    NSString *configured = [VZAppSettings.sharedSettings stringForKey:
        VZGamepadDestinationKey];
    NSArray *parts = [configured componentsSeparatedByString:@":"];
    if (parts.count == 2) {
        self.addressField.text = parts[0];
        self.portField.text = parts[1];
    } else {
        self.portField.text = [NSString stringWithFormat:@"%u", 25863];
    }
    self.enabledSwitch.on = [VZAppSettings.sharedSettings boolForKey:
        VZGamepadRelayEnabledKey];
    NSString *transport = [VZAppSettings.sharedSettings stringForKey:
        VZGamepadTransportKey];
    self.udpCompatibilitySwitch.on =
        [transport isEqualToString:VZGamepadTransportUDP];
    [self updateTransportUI];
    [[VZGamepadBridge sharedBridge] start];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(bridgeChanged:)
        name:VZGamepadBridgeStateDidChangeNotification object:nil];
    [self refresh];
}

- (void)updateTransportUI
{
    BOOL udp = self.udpCompatibilitySwitch.on;
    self.destinationRow.hidden = !udp;
    self.saveButton.hidden = !udp;
    self.hintLabel.text = udp
        ? VZGPText("UDP compatibility is enabled manually. For Bridge, use the guest LAN IPv4; for NAT, use its private IPv4. Start the UDP receiver with sudo first.")
        : VZGPText("UDP compatibility is off. Virtio Socket is the default: no guest IP is needed, and Bridge, NAT or guest network state do not affect it.");
}

- (void)udpCompatibilityChanged:(UISwitch *)sender
{
    NSString *transport = sender.on
        ? VZGamepadTransportUDP : VZGamepadTransportVirtioSocket;
    [VZAppSettings.sharedSettings setString:transport
        forKey:VZGamepadTransportKey];
    self.transientMessage = sender.on
        ? VZGPText("UDP compatibility enabled manually")
        : VZGPText("UDP compatibility disabled; using Virtio Socket");
    [self updateTransportUI];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
        target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [super viewWillDisappear:animated];
}

- (void)enabledChanged:(UISwitch *)sender
{
    [VZAppSettings.sharedSettings setBool:sender.on
        forKey:VZGamepadRelayEnabledKey];
    self.transientMessage = sender.on ? VZGPText("Continuous relay enabled")
                                      : VZGPText("Continuous relay disabled");
    [self refresh];
}

- (BOOL)saveFields
{
    NSString *address = [self.addressField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger port = self.portField.text.integerValue;
    struct in_addr parsed;
    if (inet_pton(AF_INET, address.UTF8String, &parsed) != 1 ||
        port < 1 || port > 65535) {
        self.transientMessage = VZGPText("Enter a numeric IPv4 address and a port from 1 to 65535");
        [self refresh];
        return NO;
    }
    NSString *destination = [NSString stringWithFormat:@"%@:%ld",
        address, (long)port];
    [VZAppSettings.sharedSettings setString:destination
        forKey:VZGamepadDestinationKey];
    self.transientMessage = VZGPText("Destination saved and applied");
    [self.view endEditing:YES];
    [self refresh];
    return YES;
}

- (void)saveDestination:(id)sender
{
    (void)sender;
    [self saveFields];
}

- (void)sendTest:(id)sender
{
    (void)sender;
    BOOL udp = self.udpCompatibilitySwitch.on;
    if (udp && ![self saveFields])
        return;
    self.transientMessage = VZGPText("Test state sent; waiting for the guest ACK…");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 80),
        dispatch_get_main_queue(), ^{
            [[VZGamepadBridge sharedBridge] sendTestState];
            [self refresh];
        });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (textField == self.addressField)
        [self.portField becomeFirstResponder];
    else {
        [textField resignFirstResponder];
        [self saveFields];
    }
    return YES;
}

- (void)bridgeChanged:(NSNotification *)notification
{
    (void)notification;
    [self refresh];
}

- (void)refresh
{
    NSDictionary *state = [[VZGamepadBridge sharedBridge] stateSnapshot];
    BOOL connected = [state[@"controllerConnected"] boolValue];
    NSString *name = state[@"controllerName"];
    self.controllerLabel.text = connected
        ? [NSString stringWithFormat:VZGPText("Controller: connected\nDevice: %@"), name]
        : VZGPText("Controller: not connected\nPair in iPadOS Bluetooth settings or connect a USB controller");

    uint64_t sent = [state[@"packetsSent"] unsignedLongLongValue];
    uint64_t acked = [state[@"acksReceived"] unsignedLongLongValue];
    double ackAge = [state[@"lastAckAge"] doubleValue];
    NSString *ack = ackAge >= 0 && ackAge < 2.0
        ? [NSString stringWithFormat:VZGPText("Guest ACK: received %.1f seconds ago"), ackAge]
        : acked ? VZGPText("Guest ACK: timed out") : VZGPText("Guest ACK: not received");
    double lastRTT = [state[@"lastRTTMilliseconds"] doubleValue];
    double p95RTT = [state[@"rttP95Milliseconds"] doubleValue];
    NSString *latency = acked && p95RTT >= 0
        ? [NSString stringWithFormat:VZGPText("\nHID ACK RTT: %.2f ms (p95 %.2f ms)"),
            lastRTT, p95RTT] : @"";
    NSString *error = [state[@"lastError"] length]
        ? [NSString stringWithFormat:VZGPText("\nError: %@"), state[@"lastError"]] : @"";
    NSString *message = self.transientMessage.length
        ? [NSString stringWithFormat:@"\n%@", self.transientMessage] : @"";
    NSString *connection = [state[@"transportConnected"] boolValue]
        ? VZGPText("connected") : ([state[@"connecting"] boolValue]
            ? VZGPText("reconnecting") : VZGPText("waiting for guest receiver"));
    NSString *transport = [state[@"transport"] isEqualToString:VZGamepadTransportUDP]
        ? VZGPText("UDP compatibility") : VZGPText("Virtio Socket");
    self.networkLabel.text = [NSString stringWithFormat:
        VZGPText("Transport: %@ (%@)\nDestination: %@\nSent: %llu packets  ACKs: %llu\n%@%@%@%@"),
        transport, connection,
        [state[@"destination"] length] ? state[@"destination"] : VZGPText("Not set"),
        (unsigned long long)sent, (unsigned long long)acked, ack, latency,
        error, message];

    uint16_t buttons = [state[@"buttons"] unsignedShortValue];
    NSArray *buttonNames = @[@"A", @"B", @"X", @"Y", @"L1", @"R1",
        @"L3", @"R3", @"Menu", @"Options", @"Home"];
    NSMutableArray *pressed = [NSMutableArray array];
    for (NSUInteger index = 0; index < buttonNames.count; index++)
        if (buttons & (1u << index)) [pressed addObject:buttonNames[index]];
    NSInteger hat = [state[@"hat"] integerValue];
    NSArray *hats = @[@"↑", @"↗", @"→", @"↘", @"↓", @"↙", @"←", @"↖", @"Neutral"];
    self.inputLabel.text = [NSString stringWithFormat:
        VZGPText("Buttons: %@\nD-pad: %@\nLeft stick: %+.3f, %+.3f\nRight stick: %+.3f, %+.3f\nTriggers: L %.3f  R %.3f"),
        pressed.count ? [pressed componentsJoinedByString:@" "] : VZGPText("None"),
        hats[MIN(MAX(hat, 0), 8)],
        [state[@"leftX"] floatValue], [state[@"leftY"] floatValue],
        [state[@"rightX"] floatValue], [state[@"rightY"] floatValue],
        [state[@"leftTrigger"] floatValue], [state[@"rightTrigger"] floatValue]];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refreshTimer invalidate];
    [_enabledSwitch release];
    [_udpCompatibilitySwitch release];
    [_addressField release];
    [_portField release];
    [_destinationRow release];
    [_saveButton release];
    [_hintLabel release];
    [_controllerLabel release];
    [_networkLabel release];
    [_inputLabel release];
    [_testButton release];
    [_refreshTimer release];
    [_transientMessage release];
    [super dealloc];
}
@end
