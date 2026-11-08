# Experimental macOS27 native touch and graphics

Both features are per-VM opt-ins, disabled by default. Native Touch uses the existing Virtualization multitouch transport and publishes one per-VM UUID to the initial touchscreen HID properties and the PVG display shared state. The guest then binds direct touch to that display. No guest driver is installed.

The graphics opt-in negotiates APV237 and adapts the required descriptors, resource/child-FIFO paths, information queries450/459 and compute216 imageblock setup. ImageBlocks is advertised through DeviceInfo key24; TileShaders/key23 remains unchanged. The adapter does not lower AIR, emulate a GPU or patch the guest.

## Tested scope

M1 iPad13,11 on iPadOS16.1 with the fixed Ventura13.2 transplanted runtime and macOS27.2/26B123. The integrated private test package reached a2732x2048 desktop; the user confirmed native one/two-finger input and normal Glass/Dock/shadows. The existing guest tools also installed and acknowledged the host. Its private packaging and deployment paths are excluded from this contribution.

A captured CoreAnimation downsample_4_compute AIR2.2/MSL2.2 kernel ran through the real guest/PVG path with an8x8 imageblock. Its256 output pixels matched the Mac native reference byte-for-byte (SHA25697e50e4cdb4334e016a25562135b10b5be78bc7bb194e833e958edc68e308899). This is a specific validation, not a guarantee of all macOS27 rendering.

## Build and validate

Use the repository's normal extracted-runtime build prerequisites. No Apple frameworks, IPSW, VM disks, shader binaries or raw captures are included. The hooks retain exact image/text/ABI guards and fail explicitly on an unsupported enabled profile.

```sh
bash VirtualMac/scripts/tests/test-native-touch.sh
bash VirtualMac/scripts/tests/test-gpu-compatibility.sh
bash VirtualMac/scripts/tests/test-scroll-bridge.sh
python3 VirtualMac/scripts/validate-localizations.py
bash VirtualMac/scripts/build-ipad-app.sh
# Use the normal build-ipad-vm.sh pipeline for a freshly assembled backend.
```

Cold boot with Native Touch and macOS27 Graphics Compatibility enabled. Confirm correct single-finger point/drag, two-finger contacts in a direct-touch-aware AppKit app, and normal Glass/shadows. Disable both for the original path. Do not reuse the same display UUID across VMs.

Only the pinned runtime/27.2 combination has physical validation. This upstream contribution's standard public package has not yet been physically deployed; the device observations above apply to the private integration package. Native Touch currently pins whole-file runtime hashes, including signing/load-command differences. Check the assembled Virtualization/VMM/PVG against that profile before enabling it; a freshly rebuilt standard runtime may be rejected. Do not loosen the guards merely to pass. Multi-display, save/restore, other OS/hardware and long-duration behavior remain unverified. OpenGL, dynamic resolution and new TileShaders support are outside this change. Known outer opcode12 remains diagnostic; the profile is not a complete APV implementation.

## Research references

See [protocol sources, consulted revision and attribution scope](macos27-research-references.md).
