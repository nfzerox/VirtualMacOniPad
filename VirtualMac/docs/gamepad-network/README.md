# Network Gamepad Relay

This relay forwards one USB or Bluetooth controller connected to the iPad into
the macOS guest as a generic IOHID gamepad. Virtio Socket is the default
transport and does not require guest IP networking. UDP is available as an
optional compatibility mode.

The iPad sender samples at up to 120 Hz, preserves digital input edges, and
sends a neutral state when the controller disconnects or the app backgrounds.
The guest also neutralizes the device after a 750 ms timeout to prevent stuck
inputs.

The packaged receiver and continuous Virtio Socket relay were tested
successfully with arm64 macOS Sonoma 14.3.1 and macOS 15 Sequoia guests. The
native macOS Steam client detected and mapped the raw IOHID device normally.
Steam Big Picture mode crashed in the tested guest for an unknown reason.

The GUI's one-shot **Send Test State** action has no observable effect or ACK
over Virtio Socket in the tested package. Use continuous forwarding when
checking the vsock path.

## User guides

- [English user guide](USER_GUIDE.md)
- [中文使用指南](用户指南.md)
