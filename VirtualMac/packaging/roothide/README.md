# Native roothide package

Build with `scripts/build-roothide-deb.sh`; use `scripts/development/build-roothide-dev.sh` for the additional guest diagnostics. `setup.sh` builds this package alongside the standard one by default — pass `--no-roothide` to build only the standard package, or `--install-roothide` to deploy the roothide deb to a USB-connected Dopamine-roothide device. The target supports the iPadOS 15 and 16 runtime variants and is separate from the ordinary Dopamine/Taurine package build. Hardware verification so far uses an M2 iPad Pro on iPadOS 16.2 with Dopamine-roothide 2.4.9.27.

The default build assembles from freshly built component products — it runs `build-ipad-vm.sh`, `build-ipad-network-helpers.sh`, `build-ipad-network-sharing.sh`, `build-ipad-installation.sh`, `build-ipad-app.sh`, and `build-springboard-tweak.sh` (unless `VZ_SKIP_REBUILD=1`) and reuses their Apple-extracted runtime, then recompiles the host, launcher, VMM, installation, graphics, and SpringBoard compatibility components against the Dopamine-roothide devkit so payload-internal fixes flow in without reissuing a release deb. Set `VZ_BASE_DEB` to a previously built standard deb to fall back to the deb-unpack flow for reproducible-from-snapshot builds; in that case component builds are skipped and the deb's extracted payload is reused. The package records the input source (`component-build` or `deb:<sha256>`) and source commit in `usr/libexec/VirtualMac/build-source.txt`. Xcode, Procursus ldid, dpkg-deb, Python 3, and the pinned Dopamine-roothide devkit are required; the devkit script downloads only its small SDK archive.

## Paths

Every path below is relative to the current Dopamine-roothide bootstrap unless marked as a host path:

| Purpose | Location |
| --- | --- |
| App and runtime code | `/Applications/VirtualMac.app`, `/usr/libexec/VirtualMac` |
| User settings, diagnostics and installation attempts | `/var/mobile/Library/VirtualMac/User` |
| New VM bundles and cached restore images | `/var/mobile/Library/VirtualMac/User/Library`, `/var/mobile/Library/VirtualMac/User/Restore Images` |
| Ordinary VM logs and control files | `/var/mobile/Library/VirtualMac/User/Run` |
| Root installation logs and temporary files | `/var/mobile/Library/VirtualMac/Root` |
| Restore pairing records | `/var/mobile/Library/VirtualMac/Root/Pairing` |
| Network configuration, leases and PID files | `/var/mobile/Library/VirtualMac/Network` |
| Restore UNIX sockets | `/var/run/vm` |
| Existing VM bundles and restore images | Host `/var/mobile/Media/VirtualMac` |
| Migrated legacy data (optional) | `/var/mobile/Library/VirtualMac/User/Legacy` |

The short socket directory leaves room for the randomized jailbreak prefix within Darwin's 104-byte `sun_path`. Native code calls `jbroot`; bootstrap commands receive paths converted with `rootfs`. No stable host symlink points to the randomized root.

The state parent belongs to root, user state belongs to mobile, and root/network state is readable by the mobile group. Ordinary VM logs are kept separate from root restore logs. Settings are copied once from the existing host file; subsequent saves use the private copy. Existing guest disks, restore images, and the old settings file are retained. Legacy VM discovery remains available. New data uses private storage.

### Migrating an existing public library

Close Virtual Mac and stop its VM/restore processes. The in-app action in Settings > Storage > Migrate Legacy Virtual Macs runs the same migration when the public library is still present; it spawns the setuid `legacy-storage --migrate` helper, waits for it, and reloads the library on success. From the Dopamine-roothide shell you can also run `sudo /usr/libexec/VirtualMac/install/legacy-storage --status`, then `sudo /usr/libexec/VirtualMac/install/legacy-storage --migrate`. This explicitly moves the entire original host directory into private `User/Legacy`; the public directory is removed by the move. An exclusive, same-volume rename preserves the existing sparse disks, files and metadata; no files are copied or deleted. A running app/VM, occupied destination, symlink source/destination, or cross-volume move causes refusal. Do not launch the app during migration. Package installation never migrates data automatically.

The Dopamine-roothide app discovers these legacy bundles and resolves their old auto-boot/shared-folder references against the private location. References into the migrated library are saved as original host paths; legacy VM configurations also keep ordinary host shared-folder paths untagged, so standard builds can read them after rollback. Bootstrap-only shares still require Dopamine-roothide and must be changed before switching jailbreaks. Original configuration files are not rewritten by migration. The archived restore images and installation records remain inside `Legacy`.

Before removing the Dopamine-roothide jailbreak or returning to standard Dopamine, close the app and run `sudo /usr/libexec/VirtualMac/install/legacy-storage --restore`. The command refuses to overwrite an existing public directory; resolve any such conflict first. This restores the migrated legacy library only. Export or separately preserve VMs created in the private `User/Library` before removing the jailbreak. Standard packages continue to use their existing public layout.

Persisted paths use the SDK's logical path conversion. A `jbroot:` tag distinguishes arbitrary bootstrap shared folders from old configurations that contain native host paths. The app resolves them against the current root when loading. App/tweak notifications derive a namespace from the current jailbreak identifier without exposing the identifier itself; standard packages retain their original notification names.

`VirtualMacPaths.dylib` is linked only into this package's extracted networking and MobileDevice helpers. It redirects selected file operations, temporary-directory queries, pairing records, leases, PID files, and restore sockets. InternetSharing's `com.apple.vmnet.plist` and `com.apple.dhcp6d.plist` writes now use the private Network directory, and its rtadvd spawn uses the package helper. Original shared host preferences are retained. Native process probes and file checks have verified the private configuration writes on the test device.

The installer publishes its private usbmuxd socket before MobileDevice initializes, while virtual-device notifications remain gated on the RestoreOS handshake. Its watcher cleans transport files on success, failure, and cancellation; a previous watcher preserves a newer restore's files. Upgrade/removal scripts stop package runtime processes before replacing files. `postinst` sets root ownership and setuid permission on-device and trusts final Mach-O paths through Dopamine-roothide's native `jbctl`.

## Verification

Run these checks from the `VirtualMac` directory:

```sh
bash scripts/tests/test-jailbreak-paths.sh
bash scripts/tests/test-standard-launcher.sh
bash scripts/tests/test-runtime-processes.sh
bash scripts/tests/test-roothide-legacy-storage.sh
bash scripts/tests/test-roothide-storage.sh
bash scripts/tests/test-roothide-interpose.sh
python3 tests/test-restore-cleanup.py
python3 tests/test-roothide-service-ownership.py
```

The interposition test needs permission to bind a local UNIX socket. `--files-only` explicitly skips that portion when the host sandbox forbids it. The shared source installer defaults to standard mode; only its copy inside the roothide package is stamped for Dopamine-roothide.

The builder runs `scripts/audit-roothide-package-stage.py` before packaging. It checks code locations, executable entitlements, portable dependencies and symlinks, selectable runtime variants, private helper-library loading, and self-contained maintainer scripts. It does not replace device testing.

On the test iPad, full macOS 15.6.1 installation, fresh VM boot, PVG frames, DHCP/Internet access, audio output, private shared-folder reads/writes and read-only enforcement, package upgrades, uninstall/reinstall with retained data, cancellation cleanup, diagnostics, and SpringBoard reload have been observed. The original VM/settings/DHCP files and retained host vmnet configuration passed checksum checks. Standard app/guest-tools builds and 192 comparisons with the original install launcher also passed.

An ordinary containerized probe app with no injected jailbreak libraries passed its own-file read/write and system-file read controls. It could not access the tested private settings or launcher even with their physical paths supplied, enumerate either randomized-root parent, obtain the running App/VMM paths, or look up the three tested Mach services. Of 21 fixed host paths, only the pre-existing `/var/mobile/Media/VirtualMac` directory exposed metadata; reading that directory was denied. The probe and its temporary Dopamine-roothide configuration were removed afterward. This is bounded visibility evidence, not a claim that all detection methods are covered. Existing data in the old public directory remains a detectable artifact until it is explicitly migrated.

On roothide13, an authorized migration, rollback, and migration preserved all 21 legacy entries' inode, size, allocation, ownership, permissions and modification time, plus configuration hashes. The migrated test clone booted with PVG frames and a ready guest agent. A fresh uninjected sandbox probe while App/VMM were live found none of the 21 fixed host paths accessible, and could not discover the `virtualmac` URL scheme (HTTPS positive control passed). All tested files, live process paths, root enumeration and three Mach services remained blocked. When the exact randomized root was supplied in advance, metadata for directories (including existing User/Library and App directories, not only migrated Legacy) was visible, although directory contents and VM disk files were unreadable. Root randomization therefore remains part of the hiding boundary; this is not universal undetectability.

An actual iPad reboot and re-jailbreak changed both bootstrap roots. The migrated clone booted under the new root with PVG frames, guest agent, setuid launcher and network services working; settings and original VM/host network checksums matched the pre-reboot values. After the user logged in, Guest Tools payload installation and desktop menu activation succeeded. On roothide14, a new uninjected probe against the new root and live App/VMM again passed fixed-path, file-content, process-path, Mach-service, root-enumeration and URL-scheme checks, with the same known-root directory-metadata limitation. The probe, data container, registration and temporary config were removed.

Remaining release checks include microphone capture, broader graphics/peripheral coverage, and standard-jailbreak hardware regression. Keep original user VMs intact and use a cloned or newly-created test VM.

The `postinst` does not delete old host artifacts. Cleanup of a previous experimental build must target only files verified to belong to that test, after its writers have stopped. Do not delete system DHCP leases, shared network preferences, or existing VM data.
