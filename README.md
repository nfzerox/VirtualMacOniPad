# Virtual Mac on iPad

People have dreamed of running macOS on iPad for [more](https://www.macstories.net/stories/macpad-how-i-created-the-hybrid-mac-ipad-laptop-and-tablet-that-apple-wont-make/) [than](https://github.com/nfzerox/VirtualMacOniPad) [for decades](https://github.com/nfzerox/VirtualMacOniPad). Virtual Mac takes that idea further by turning a supported iPhone or iPad into a portable macOS VM host.

![Screenshot of Virtual Mac on iPad](VirtualMac/screenshots/VirtualMac.png)

As seen on: [iGeneration](https://www.igen.fr/ipad/2026/08/virtual-mac-fait-tourner-macos-sur-certains-ipad-jailbreakes-157355), [ifun.de](https://www.ifun.de/open-source-projekt-bringt-macos-auf-die-ipad-teil-2/), and other jailbreak-focused coverage.

## Installation

1. Jailbreak a compatible iPhone or iPad running iOS/iPadOS 14 or newer. Enable JIT in StickDebug before launching the app.
2. Add the [https://nfzerox.github.io/cydia/](https://nfzerox.github.io/cydia/) repository in Sileo, then search and install Virtual Mac.
3. If you are building from source, run `bash VirtualMac/scripts/build-ipad-app.sh` to produce the app bundle, then `bash VirtualMac/scripts/build-ipa.sh` to package an IPA.

Ran into a problem? [Check the troubleshooting section](https://github.com/nfzerox/VirtualMacOniPad#what-if-i-encounter-crashes-bugs-or-other-issues).

## Frequently Asked Questions

### Which device and iOS versions does this require?

Virtual Mac supports iPhone and iPad hardware running iOS 14 and newer. Use a supported jailbreak environment and enable JIT in StickDebug before launch. The app is no longer limited to iPadOS 14.5-16.3.1 only.

### Does Virtual Mac on iPad work on iPhone?

Yes. The app is built to support iPhone and iPad targets, provided the device is compatible with the jailbreak/run-time environment and JIT is enabled in StickDebug.

### Do I need to enable JIT?

Yes. StickDebug JIT support is required before Virtual Mac can run on-device. If JIT is disabled, the app should warn the user and fail gracefully instead of silently continuing.

### How do I build an IPA?

From a macOS machine with the Xcode toolchain installed:

```bash
bash VirtualMac/scripts/build-ipad-app.sh
bash VirtualMac/scripts/build-ipa.sh
```

This will create an `.app` bundle and then package it into an `.ipa` archive under `build/ipa/`.

## Technical Overview

Creating Virtual Mac on iPad begins with extracting Hypervisor, Virtualization, ParavirtualizedGraphics, and supporting frameworks from macOS. Because dyld shared cache creation is a one way optimization pipeline, the project reconstructs the runtime so it can be loaded on supported iOS/iPadOS devices.

To fix this, [`uncache.py`](VirtualMac/vz/uncache.py) makes these extracted arm64e libraries loadable. It walks the cache's slide information, separates in image rebases from cross image binds, repairs references, and rebuilds metadata.

The project then packages the host app, guest tools, and runtime components as a jailbreak-compatible app bundle. For local distribution, `build-ipa.sh` wraps the built bundle into an `.ipa` archive for testing or sideloading.

## Credits

This project would not be possible without years of prior research by talented developers. The culmination of the following community projects, combined with recent advances in agentic coding, made this work possible.
