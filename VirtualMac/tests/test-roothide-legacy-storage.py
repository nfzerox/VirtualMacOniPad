#!/usr/bin/env python3
"""Exercise atomic migration and rollback using the real utility and disposable data."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="vz-legacy-") as temporary:
    root = Path(temporary)
    env = {**os.environ, "VZ_TEST_ROOT": str(root)}
    host = root / "rootfs/var/mobile/Media/VirtualMac"
    private = root / "var/mobile/Library/VirtualMac/User/Legacy"
    lock = root / "var/mobile/Library/VirtualMac/Root/legacy-storage.lock"
    helper = root / "usr/libexec/VirtualMac/install/runtime-processes"
    for parent in (host.parent, private.parent, lock.parent, helper.parent):
        parent.mkdir(parents=True, exist_ok=True)
    helper.write_text('#!/bin/sh\n[ "$1" = --list-guests ] || exit 2\nexit 0\n')
    helper.chmod(0o755)

    def run(argument, succeeds=True, overrides=None):
        result = subprocess.run([str(binary), argument], env={**env, **(overrides or {})},
                                capture_output=True, text=True, timeout=5)
        assert (result.returncode == 0) == succeeds, result
        return result.stdout

    def signature(file):
        info = file.stat()
        return info.st_ino, info.st_size, info.st_blocks, info.st_mode, info.st_mtime_ns

    run("--migrate", False)
    host.mkdir()
    vm = host / "Original VM.bundle"
    vm.mkdir()
    disk = vm / "Disk.img"
    with disk.open("wb") as stream:
        stream.write(b"original header")
        stream.seek(64 * 1024 * 1024)
        stream.write(b"original tail")
    (host / "Settings.plist").write_bytes(b"unchanged settings")
    (host / "relative-link").symlink_to("Original VM.bundle/Disk.img")
    before = signature(disk)
    host_inode = host.stat().st_ino

    run("--status")
    run("--migrate", False, {"VZ_TEST_NONROOT": "1"})
    assert disk.exists()
    helper.write_text('#!/bin/sh\necho 123\n')
    run("--migrate", False)
    helper.write_text('#!/bin/sh\nexit 1\n')
    run("--migrate", False)
    helper.unlink()
    run("--migrate", False)
    helper.write_text('#!/bin/sh\n[ "$1" = --list-guests ] || exit 2\nexit 0\n')
    helper.chmod(0o755)

    private.mkdir()
    run("--migrate", False)
    private.rmdir()
    private.symlink_to(host, target_is_directory=True)
    run("--migrate", False)
    private.unlink()
    lock.unlink()
    lock.symlink_to(host / "Settings.plist")
    run("--migrate", False)
    assert (host / "Settings.plist").read_bytes() == b"unchanged settings"
    lock.unlink()
    with lock.open("w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        run("--migrate", False)

    run("--migrate")
    assert not host.exists() and private.stat().st_ino == host_inode
    migrated_disk = private / "Original VM.bundle/Disk.img"
    assert signature(migrated_disk) == before
    assert (private / "Settings.plist").read_bytes() == b"unchanged settings"
    assert os.readlink(private / "relative-link") == "Original VM.bundle/Disk.img"
    assert "host=absent private=present" in run("--status")
    run("--migrate", False)
    host.mkdir()
    (host / "sentinel").write_text("new public data must not be overwritten")
    run("--restore", False)
    assert (host / "sentinel").read_text() == "new public data must not be overwritten"
    (host / "sentinel").unlink()
    host.rmdir()
    run("--restore")
    assert signature(disk) == before and not private.exists()
    assert host.stat().st_ino == host_inode
    host.rename(host.with_name("saved"))
    host.symlink_to(host.with_name("saved"), target_is_directory=True)
    run("--migrate", False)
    assert host.is_symlink() and not private.exists()
    host.unlink()
    saved = host.with_name("saved")
    import shutil
    shutil.rmtree(saved)

    # Merge: move bundles from the legacy library into the main library.
    library = root / "var/mobile/Library/VirtualMac/User/Library"
    library.mkdir(parents=True)
    # Re-migrate so Legacy holds two bundles; one shares a name with an
    # existing main-library bundle to exercise the suffix path.
    host.mkdir()
    (host / "Shared.bundle").mkdir()
    (host / "Shared.bundle/Disk.img").write_bytes(b"legacy shared")
    (host / "Only Legacy.bundle").mkdir()
    (host / "Only Legacy.bundle/Disk.img").write_bytes(b"legacy only")
    (host / "Settings.plist").write_bytes(b"legacy settings")
    run("--migrate")
    assert not host.exists()
    (library / "Shared.bundle").mkdir()
    (library / "Shared.bundle/Disk.img").write_bytes(b"main shared")
    (library / "Main Only.bundle").mkdir()
    main_only_inode = (library / "Main Only.bundle").stat().st_ino
    legacy_shared_inode = (private / "Shared.bundle").stat().st_ino
    legacy_only_inode = (private / "Only Legacy.bundle").stat().st_ino
    run("--merge")
    # Main-only bundle is untouched.
    assert (library / "Main Only.bundle").stat().st_ino == main_only_inode
    # Name collision got a " 2" suffix; contents came from Legacy.
    assert (library / "Shared 2.bundle/Disk.img").read_bytes() == b"legacy shared"
    assert (library / "Shared.bundle/Disk.img").read_bytes() == b"main shared"
    # Unique bundle moved cleanly, inode preserved.
    assert (library / "Only Legacy.bundle").stat().st_ino == legacy_only_inode
    assert not (private / "Shared.bundle").exists()
    assert not (private / "Only Legacy.bundle").exists()
    # Non-bundle entries stay in Legacy.
    assert (private / "Settings.plist").exists()
    # Idempotent: nothing left to move.
    run("--merge")
    # Refuses without root.
    run("--merge", False, {"VZ_TEST_NONROOT": "1"})
    print("PASS legacy migration/rollback and merge; sparse inodes, metadata and contents preserved; unsafe states refused")
