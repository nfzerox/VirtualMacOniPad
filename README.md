# Virtual Mac on iPad

People have dreamed of running macOS on iPad for [more](https://www.macstories.net/stories/macpad-how-i-created-the-hybrid-mac-ipad-laptop-and-tablet-that-apple-wont-make/) [than](https://github.com/khanhduytran0/MacWSBootingGuide) [a](https://khronokernel.com/apple/silicon/2021/01/17/QEMU-AS.html) [decade](https://worthdoingbadly.com/macappsios/). Today, that dream comes true. With Virtual Mac, iPad finally breaks free from iPadOS, enabling pro apps like Xcode, Terminal, Final Cut Pro, Logic Pro, and Pixelmator Pro to run directly on device. Requires iPad Pro (M1, M2) or iPad Air (M1) running iPadOS 14 up to 16.3.1.

![Screenshot of Virtual Mac on iPad](VirtualMac/screenshots/VirtualMac.png)

As seen on: [iGeneration](https://www.igen.fr/ipad/2026/08/virtual-mac-fait-tourner-macos-sur-certains-ipad-jailbreakes-157355), [ifun.de](https://www.ifun.de/open-source-projekt-bringt-macos-auf-das-ipad-285132/), [La Manzana Mordida](https://lamanzanamordida.net/noticias/instalar-macos-ipad-virtualmac/), [すまほん!!](https://smhn.info/202608-apple-ipad-virtual-mac-macos-jailbreak-hypervisor), [鵺間飛行 (video)](https://www.bilibili.com/video/BV1Nfue6PExJ/), [IT Home](https://www.ithome.com/0/985/545.htm), [ezone](https://ezone.hk/article/20104816/ipad%E7%B5%82%E6%96%BC%E5%8F%AF%E4%BB%A5%E8%B7%91macos-%E6%B0%91%E9%96%93%E7%A5%9E%E4%BA%BA%E9%87%8B%E5%87%BA%E9%96%8B%E6%BA%90%E5%B7%A5%E5%85%B7-%E6%94%AF%E6%8F%B4gpu%E5%8A%A0%E9%80%9F-%E5%AF%ABcode-%E5%8D%B3%E7%9D%87%E6%94%AF%E6%8F%B4%E6%A9%9F%E5%9E%8B%E8%88%87%E7%B3%BB%E7%B5%B1), [KOCPC](https://www.kocpc.com.tw/archives/664343), and [Bilibili (video)](https://www.bilibili.com/video/BV1PfuR69EoC/). Virtual Mac on iPad is a community project and is not affiliated with Dopamine, UTM, VirtualBuddy, or Apple. Contributions are welcome!

## Installation

1. Jailbreak a compatible iPad Pro (M1, M2) or iPad Air (M1). [View instructions for iPadOS 15 up to 16.3.1](https://ios.cfw.guide/installing-dopamine-trollstore/), or [instructions for iPadOS 14 up to 14.8.1](https://ios.cfw.guide/installing-taurine/). If jailbreak fails, switch to a different exploit in Dopamine or Taurine settings.
2. Add the [https://nfzerox.github.io/cydia/](https://nfzerox.github.io/cydia/) repository in Sileo, then search and install Virtual Mac.

Ran into a problem? [Check the troubleshooting section](https://github.com/nfzerox/VirtualMacOniPad#what-if-i-encounter-crashes-bugs-or-other-issues).

## Frequently Asked Questions

### Which iPad and iPadOS versions does this require?

Virtual Mac on iPad requires an iPad Pro (M1, M2) or iPad Air (M1) running iPadOS 14 up to 16.3.1. iPad Pro models with 1 TB or 2 TB of storage have 16 GB of RAM and provide the best performance and experience.

### Which versions of macOS does this support?

Virtual Mac on iPad supports macOS 12 Monterey up to macOS 26 Tahoe, with experimental support for macOS 27 Golden Gate. macOS 15 Sequoia is the recommended version to install. [You can download the latest compatible version of Xcode, Final Cut Pro Trial, Logic Pro Trial, and Pixelmator Pro Trial](https://nfzerox.github.io/virtual-mac/app/).

Metal acceleration is available in all supported macOS versions. Final Cut Pro and OpenGL/OpenCL acceleration require macOS 14 Sonoma or later. Because signing into iCloud or Apple Account is not supported, choose Set Up Later when asked.

### Do I need a Magic Keyboard?

Magic Keyboard is not required because you can also use the touchscreen and virtual keyboard:
- Tap to click, secondary click by tapping with two fingers, and scroll with two fingers.
- To access the virtual keyboard, tap the keyboard icon. If the virtual keyboard gets in the way, press and hold the bottom-right icon to switch to Floating mode.
- If the HUD gets in the way, move it to a different corner or hide it from the More menu. To show it again, press and hold the Virtual Mac icon on the iPad Home Screen, then tap Show Virtual Mac Controls.
- To automatically start up your virtual Mac, enable System Settings > Users & Groups > Automatically log in, and set System Settings > Lock Screen to Never. Then in Virtual Mac's in-app Settings, change Start on Launch from Show Library to the name of your virtual Mac. To show library again, press and hold the Virtual Mac icon on the iPad Home Screen, then tap Show Library.
- If your Magic Keyboard doesn't have a hardware Escape key, press Command + Period (⌘ + .) instead. You can also map another key to Escape in Settings > General > Keyboard > Hardware Keyboard > Modifier Keys.
- However, I recommend using a Magic Keyboard for the full experience, but don’t fret, you can still use MacOS even without a Magic Keyboard.

### Does Virtual Mac support Apple Pencil?
- Yes, Virtual Mac can support an Apple Pencil.

### Is it possible to support newer versions of iPadOS?

Supporting iPadOS 16.4 or later presents additional challenges because [Hypervisor support was removed from the iPadOS XNU kernel](https://x.com/UTMapp/status/1708907045314035986). Contributions are welcome!

### Does Virtual Mac on iPad work on iPhone?

Even though iPad is the primary supported platform, Virtual Mac on iPad also works on iPhone 14 Pro and iPhone 14 Pro Max running iOS 16 up to iOS 16.3.1.

### What kind of performance does Virtual Mac on iPad offer?

Virtual Mac on iPad uses hardware CPU virtualization and supports paravirtualized graphics acceleration, providing excellent performance for everyday tasks. Because it uses an extracted and modified version of Apple's macOS virtualization stack, it provides roughly the same class of CPU and Metal performance as VirtualBuddy or UTM virtualizing macOS on an M1 or M2 Mac.

With the latest update, Virtual Mac on iPad also goes beyond what VirtualBuddy and UTM offers, being first to ever support Final Cut Pro and OpenGL/OpenCL acceleration [through modified GLDRendererMetal](VirtualMac/vz/guest/OpenGLPVGCompat.m) in virtualized environments.

### What if I encounter crashes, bugs, or other issues?

First, open Sileo and update to the latest version of Virtual Mac. If the issue remains, try these fixes for common issues:
- Virtual Mac does not support the Dopamine-roothide environment. To use Virtual Mac, remove the roothide jailbreak from Dopamine-roothide > Settings > Remove Jailbreak, then [switch to the official version of Dopamine](https://ios.cfw.guide/installing-dopamine-trollstore/).
- If you see "[install-launcher failed: Permission denied](https://github.com/nfzerox/VirtualMacOniPad/issues/10)", update to the latest version of Virtual Mac. If the issue remains, open Filza and [follow this screenshot](VirtualMac/screenshots/troubleshooting/troubleshooting-permission.png), changing access permissions of `/var/root` to "Read, Execute" for "Others".
- If you see "[Unexpected device state 'DFU' expected 'RestoreOS' (Probably forced into DFU mode externally)](https://github.com/nfzerox/VirtualMacOniPad/issues/11)", update to the latest version of Virtual Mac. If the issue remains, open Sileo > Packages, search for usbmuxd and [temporarily uninstall it](VirtualMac/screenshots/troubleshooting/troubleshooting-usbmuxd.png).
- If you see "launcher cannot become root: Operation not permitted" or "Internal Virtualization error. The virtual machine failed to start", and have Choicy installed, open Settings > Choicy > Applications > Virtual Mac, and turn off "Disable Tweak Injection". You can also uninstall Choicy.
- Virtual Mac may conflict with certain other tweaks. If problems remain, remove other tweaks one at a time to narrow down the conflict.
- Virtual Mac may have overwhelmed your iPad’s RAM, to fix this, choose a lower version of macOS, I recommend Seqouia.

[Open a GitHub issue](https://github.com/nfzerox/VirtualMacOniPad/issues?q=is%3Aissue) when you encounter a crash, bug, or other problem. Include clear reproduction steps, a screenshot or screen recording, and diagnostics file from Virtual Mac's in app Settings > Export Diagnostics.

If you have access to Codex or Claude Code, install `openssh` and `lldb` in Sileo, then connect your iPad to a computer. Point the coding agent to this repository, then ask it to diagnose live and fix the issue. Because many issues can be setup-specific, this is usually the easiest way to fix issues. If you find a solution, please update the issue or open a pull request. Contributions are welcome!

As a last resort, open Dopamine > Settings > Remove Jailbreak, then jailbreak again and reinstall Virtual Mac on iPad. If this still doesn't work, back up all data, open Dopamine > Settings > Remove Jailbreak, and erase your iPad in Settings > General > Transfer or Reset iPad > Erase All Content and Settings to start fresh.

## Screenshots

<p align="center">
  <img src="VirtualMac/screenshots/VirtualMac_Library.png" alt="Virtual Mac grid library" width="49%">
  <img src="VirtualMac/screenshots/VirtualMac_LibraryList.png" alt="Virtual Mac list library" width="49%">
</p>
<p align="center">
  <img src="VirtualMac/screenshots/VirtualMac_Create.png" alt="Create a Virtual Mac" width="49%">
  <img src="VirtualMac/screenshots/VirtualMac_Download.png" alt="Downloading macOS" width="49%">
</p>
<p align="center">
  <img src="VirtualMac/screenshots/VirtualMac_Configuration.png" alt="Virtual Mac configuration" width="49%">
  <img src="VirtualMac/screenshots/VirtualMac_macOS.png" alt="macOS running on iPad" width="49%">
</p>

## Technical Overview

Creating Virtual Mac on iPad begins with extracting Hypervisor, Virtualization, ParavirtualizedGraphics, and supporting frameworks from macOS. Because dyld shared cache creation is a one way optimization process, extractions are lossy and can't be loaded directly.

To fix this, [`uncache.py`](VirtualMac/vz/uncache.py) makes these extracted arm64e libraries loadable. It walks the cache's slide information, separates in image rebases from cross image binds, resolves their symbols and source images, lays out the Mach-O segments again, and emits new chained pointer fixups while preserving pointer authentication metadata.

The pipeline then rebuilds GOT and authenticated GOT slots, rewrites cross segment PC relative references, repairs Objective-C selectors, protocols, relative method lists, and exports, adds a new chained fixups load command, [restamps the platform to iOS](VirtualMac/vz/stamp_ios.py), and [shims](VirtualMac/vz/host/NSViewShim.m) [many](VirtualMac/vz/host/metalshim.m) [missing](VirtualMac/vz/host/vmmhook.m) [API](VirtualMac/vz/host/vzxpchook.m) expected by these frameworks.

To install macOS into the virtual machine, macOS normally connects to the virtual machine's DFU device through the AppleUSBUserHCI kernel service, which is absent from iPadOS. To bridge this gap, [`installation_usb_shim.m`](VirtualMac/vz/host/installation_usb_shim.m) reconstructs its controller path in userspace and forwards virtual USB endpoint traffic to the matching MobileDevice and usbmuxd components.

## Credits

This project would not be possible without years of prior research by talented developers. The culmination of the following community projects, combined with recent advances in agentic coding, made Virtual Mac on iPad possible:

[dsce](https://github.com/moraea/dsce) proved that loadable x86_64 framework libraries could be extracted from the dyld shared cache. [DyldExtractor](https://github.com/arandomdev/dyldextractor) formed the basis of our [first ever loadable arm64e framework extractor](VirtualMac/vz/uncache.py). [MacWSBootingGuide](https://github.com/khanhduytran0/MacWSBootingGuide) and [iOS-run-macOS-executables-tools](https://worthdoingbadly.com/macappsios/) proved that macOS system frameworks could be restamped and patched to work on iPadOS.

[HvDecompile](https://worthdoingbadly.com/hv/) and [UTM](https://github.com/utmapp/UTM) laid the groundwork for running Windows and Linux VMs with full Hypervisor performance on iPad, while [reims-vgpu](https://github.com/steelbrain/reims-vgpu) proved that accelerated macOS guests on a foreign host were possible with paravirtualized graphics acceleration. [ipsw](https://github.com/blacktop/ipsw) provides essential firmware and dyld shared cache analysis tools, and [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) provides an invaluable reference for Apple's macOS virtualization and restore APIs.
