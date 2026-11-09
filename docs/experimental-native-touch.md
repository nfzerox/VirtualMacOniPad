# Experimental native direct touch

Native Touch is a per-VM option under input settings, disabled by default. It
sends UIKit finger contacts in the VM viewport through Virtualization's existing
multitouch device. The selected pointing device remains available for pointer
input. No guest driver, guest security change or system-wide HID capture is added.

The guest needs the touchscreen and display to name the same display UUID. On
the supported runtime, the backend adds `displayUUID` to the initial touchscreen
HID property dictionary and writes that UUID into the PVG display shared state.
The guest display driver consumes the field and WindowServer binds direct touch
to that display. A UUID is generated once and saved in each VM configuration;
do not reuse the same UUID across different VMs.

This PR changes input and display identity only. It leaves the existing graphics
protocol, Metal capabilities, shader handling and tracing behavior in place.
It does not include the graphics adapter from PR #85.

## Validation and limits

On 2026-11-09, the separated native-touch implementation was physically tested
on an M1 iPad13,11 / iPadOS16.1, using the validated Ventura13.2 transplanted
runtime and a macOS27.2/26B123 guest. The tester confirmed a successful login
and normal single-finger and two-finger input. Backend logs showed the same
UUID published to the touchscreen HID properties and supplied to the display,
matching the VM configuration.

The isolated test app contained no graphics adapter. Its native-touch source
modules were byte-for-byte identical to the proposed code. App identity,
storage paths, IPC names and build metadata were adjusted so it could coexist
with the working installation; the backend used the standard direct linkage
without FrameProbe. All four Apple core runtime images were unchanged, and
all 217 deployed files passed SHA256 readback verification.

This validates the separated implementation in that isolated wrapper. A freshly
extracted IPSW runtime or installation under the upstream standard App identity
has not yet been physically validated. Earlier private integration tests also
observed direct AppKit contacts; they are supporting history, not a substitute
for the separated implementation's test above.

The implementation intentionally pins Virtualization, VMM and PVG whole-file
hashes, executable/image UUIDs and the relevant method/layout offsets. A changed
or newly signed runtime can be rejected even if much of its code is identical.
Newer/backported PVG stacks need their own verified binding profile. The guards
are not bypassed. Multi-display, save/restore, many simultaneous fingers, Pencil,
other OS/hardware versions, all-app gesture compatibility and long-duration
behavior are not claimed as tested.

```sh
bash VirtualMac/scripts/tests/test-native-touch.sh
bash VirtualMac/scripts/tests/test-scroll-bridge.sh
python3 VirtualMac/scripts/validate-localizations.py
bash VirtualMac/scripts/build-ipad-app.sh
bash VirtualMac/scripts/build-vmm-compat.sh
# Full backend assembly remains the normal build-ipad-vm.sh pipeline.
```

For physical validation, cold boot an isolated VM with Native Touch enabled,
check one- and two-finger contacts in a direct-touch-aware AppKit app, then test
the apps you use. Disable Native Touch and cold boot to use the existing input
path. Do not substitute results from the combined graphics PR for this split
package's own acceptance test.

## Research provenance

The UUID binding came from analysis of the target AppleParavirtDisplay guest
kernel driver and the target VMM/PVG runtime, followed by physical-input tests.
The implementation builds on VirtualMacOniPad's framework extraction and
virtualization groundwork; the upstream README credits
[HvDecompile](https://worthdoingbadly.com/hv/),
[ipsw](https://github.com/blacktop/ipsw) and
[VirtualBuddy](https://github.com/insidegui/VirtualBuddy), among others.
This extraction retains our previously published UIKit input path; it does not
copy the separate implementation in the
[netsflex fork](https://github.com/netsflex/VirtualMacOniPad/commit/5f11ce6c85394d8d57363b933b968c379edaf928).
