# RootHide process probe

This small native package checks the prerequisites for VirtualMac on Dopamine RootHide without installing or replacing VirtualMac. It needs no restore image or extracted Apple frameworks.

Build on macOS with Xcode, Procursus ldid, and dpkg-deb:

```sh
VirtualMac/scripts/development/build-roothide-probe.sh
```

The build downloads the official 2.6 KiB SDK archive, checks its SHA-256, and links against the device's libroothide. Set `VZ_ROOTHIDE_SDK` to use an existing SDK directory containing `roothide.h` and `roothide/libroothide.tbd`. Build output is under `VirtualMac/build/roothide-probe` or the configured `VZ_BUILD_ROOT`.

Install the resulting deb from the device's RootHide shell using `dpkg -i`. The package is named `com.mac.virtual.roothide-probe`, and all its Mach-O files live under `/usr/libexec/VirtualMacProbe` in the bootstrap. Its postinst passes physical file paths to RootHide's native `jbctl trustcache add`; it does not submit build-time hashes.

From a root SSH session, run both process architectures as mobile:

```sh
/usr/libexec/VirtualMacProbe/virtualmac-roothide-probe --as-mobile
/usr/libexec/VirtualMacProbe/virtualmac-roothide-probe.arm64e --as-mobile
```

The probe reports the caller's identity, code-signing flags, jailbreak root, and host/bootstrap storage mappings. It checks loading a native dylib, passing a temporary host file to a bootstrap shell, spawning a child, acquiring that child's task port, copying its Mach send right, delivering a message, and invoking a root-owned setuid helper. Temporary files are removed. The helper only reports its identity and exits; it does not run commands supplied by the caller.

`RESULT` must show `PASS` for all four checks. Running without `--as-mobile` is useful for comparison, but a successful root run does not establish that the app's mobile process will work. These probes do not test UIKit launch, Hypervisor, GPU, or macOS installation.

Remove it from the device with:

```sh
dpkg -r com.mac.virtual.roothide-probe
```

References: [official path APIs](https://github.com/roothide/Developer/blob/main/interface.md), [file and entitlement rules](https://github.com/roothide/Developer/blob/main/entitlements.md), and [SDK release](https://github.com/roothide/libroothide/releases/tag/0.0.1).
