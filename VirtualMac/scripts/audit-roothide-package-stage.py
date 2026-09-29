#!/usr/bin/env python3
"""Validate the native RootHide package without running its iOS executables."""

from pathlib import Path
import plistlib
import struct
import subprocess
import sys

PRIVATE_PATH_LIBRARY = "@loader_path/.jbroot/usr/lib/VirtualMacPaths.dylib"
REQUIRED_ENTITLEMENTS = (
    "platform-application",
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.storage.AppBundles",
    "com.apple.private.security.storage.AppDataContainers",
)
MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def require(condition, message):
    if not condition:
        raise SystemExit("RootHide package audit: " + message)


def output(*arguments):
    return subprocess.check_output(arguments, text=True)


def audit(stage):
    control = (stage / "DEBIAN/control").read_text()
    require("Architecture: iphoneos-arm64e\n" in control,
            "package architecture must be iphoneos-arm64e")
    require("Package: com.mac.virtual\n" in control, "unexpected package identity")
    install = stage / "usr/libexec/VirtualMac/install"
    script = (install / "start-install.sh").read_text()
    require((install / "runtime-processes").is_file(), "native process owner check is missing")
    require((install / "legacy-storage").is_file(), "reversible legacy migration utility is missing")
    require("VZ_INSTALL_ROOTHIDE=1\n" in script, "installer was not stamped for RootHide")
    require("VZ_INSTALL_ROOTHIDE=0\n" not in script, "installer still has standard mode")
    subprocess.run(["sh", "-n", str(install / "start-install.sh")], check=True)
    postinst = (stage / "DEBIAN/postinst").read_text()
    require('chown root:wheel "$runtime/install/install-launcher"' in postinst and
            'chmod 4755 "$runtime/install/install-launcher"' in postinst,
            "target-side setuid ownership setup is missing")
    require('chown root:wheel "$runtime/install/legacy-storage"' in postinst and
            'chmod 4755 "$runtime/install/legacy-storage"' in postinst,
            "legacy migration utility setuid ownership setup is missing")
    for name in ("preinst", "postinst", "prerm"):
        path = stage / "DEBIAN" / name
        require(path.stat().st_mode & 0o111, name + " is not executable")
        require("stop-runtime.sh" not in path.read_text(),
                name + " references a non-shipped script")
        subprocess.run(["sh", "-n", str(path)], check=True)
    count = executables = 0
    dependencies = {}
    for path in stage.rglob("*"):
        relative = path.relative_to(stage)
        if path.is_symlink():
            target = path.readlink().as_posix()
            require(not target.startswith("/") and ".jbroot-" not in target,
                    f"nonportable symlink: {relative} -> {target}")
            continue
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(32)
        if header[:4] not in MACHO_MAGICS:
            continue
        count += 1
        require(relative.parts[0] not in ("var", "tmp", "System"),
                f"code is in a forbidden directory: {relative}")
        linked = output("otool", "-L", str(path))
        dependencies[relative.as_posix()] = linked
        for prefix in ("/var/jb/", "/var/root/", "/.jbroot-", "/tmp/"):
            require(prefix not in linked, f"fixed host dependency {prefix}: {relative}")
        if header[:4] == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", header, 12)[0] == 2:
            executables += 1
            raw = output("ldid", "-e", str(path))
            entitlements = plistlib.loads(raw.encode()) if raw.strip() else {}
            for key in REQUIRED_ENTITLEMENTS:
                require(entitlements.get(key) is True, f"{relative} lacks {key}")
    require(count > 0 and executables > 0, "no executable payload was found")
    runtime = "usr/libexec/VirtualMac/payload/"
    installation = runtime + "Installation.xpc/Contents/"
    mobile_device = installation + "Frameworks/MobileDevice.framework/Versions/A/"
    helpers = ["usr/libexec/InternetSharing", "usr/libexec/bootpd", "usr/sbin/rtadvd",
               mobile_device + "Resources/usbmuxd"]
    for variant in ("", ".ipados15", ".ipados15-auth", ".ipados16"):
        helpers += [installation + "MacOS/com.apple.Virtualization.Installation" + variant,
                    mobile_device + "MobileDevice" + variant]
    helpers += ["usr/libexec/InternetSharing.ipados15", "usr/libexec/InternetSharing.ipados16"]
    for helper in helpers:
        require(PRIVATE_PATH_LIBRARY in dependencies.get(helper, ""),
                "private path library is missing from " + helper)
    for variant in ("ipados15", "ipados16"):
        for relative in (
            runtime + "VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine." + variant,
            installation + "Frameworks/InstallationCompat.dylib." + variant,
        ):
            require(relative in dependencies, "missing runtime variant: " + relative)
    for name in ("com.apple.NetworkSharing.plist", "com.apple.bootpd.plist"):
        path = stage / "Library/LaunchDaemons" / name
        value = plistlib.loads(path.read_bytes())
        require(value["Program"].startswith("/usr/"), "nonportable program in " + name)
        require((stage / value["Program"].lstrip("/")).is_file(), "missing program for " + name)
        for key in ("StandardOutPath", "StandardErrorPath"):
            require(value[key].startswith("/var/mobile/Library/VirtualMac/Network/"),
                    "host log path in " + name)
        require(".jbroot-" not in str(value), "random root persisted in " + name)
    print(f"RootHide package audit passed: {count} Mach-O files, {executables} executables")


if __name__ == "__main__":
    require(len(sys.argv) == 2, "usage: audit-roothide-package-stage.py STAGE")
    audit(Path(sys.argv[1]))
