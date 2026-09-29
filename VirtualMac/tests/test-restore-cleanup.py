#!/usr/bin/env python3
"""Exercise the actual restore watcher with disposable process groups and files."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

SOURCE = Path(__file__).parents[1] / "vz/install/start-install.sh"
text = SOURCE.read_text()
start = text.index("restore_process_pid=$$\n(") + len("restore_process_pid=$$\n(")
end = text.index('\n) >"$temporary/vz-usbmuxd-cleanup.log"', start)
WATCHER = text[start:end]
FILES = ("vzusbmuxd", "vz-usb-restore.sock", "vz-usbmuxd-enable", "vz-usbmuxd.pid")


def environment(root, mode="1"):
    return {**os.environ, "VZ_INSTALL_ROOTHIDE": mode, "temporary": str(root),
            "socket_directory": str(root), "native_socket_directory": str(root),
            "usbmux_socket": str(root / "usbmuxd")}


def prepare(root, pid):
    for name in FILES:
        (root / name).touch()
    (root / "vz-usbmuxd.pid").write_text(str(pid))
    (root / "usbmuxd").symlink_to("vzusbmuxd")


def wait_until(predicate, message, seconds=6):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(message)
        time.sleep(0.02)


def stop(process):
    if process and process.poll() is None:
        process.kill()
        process.wait(timeout=3)


def completed_restore(newer):
    with tempfile.TemporaryDirectory(prefix="virtualmac-cleanup-") as work:
        root = Path(work)
        helper = subprocess.Popen(["/bin/sleep", "30"])
        successor = subprocess.Popen(["/bin/sleep", "30"]) if newer else None
        watcher = None
        try:
            dead = subprocess.Popen(["/usr/bin/true"])
            dead.wait(timeout=3)
            prepare(root, successor.pid if successor else helper.pid)
            env = {**environment(root), "restore_process_pid": str(dead.pid),
                   "started_helper_pid": str(helper.pid)}
            watcher = subprocess.Popen(["/bin/sh", "-c", WATCHER], env=env)
            helper.wait(timeout=6)
            assert watcher.wait(timeout=6) == 0
            if successor:
                assert successor.poll() is None
                assert (root / "vz-usbmuxd.pid").read_text() == str(successor.pid)
                assert (root / "usbmuxd").is_symlink()
                assert all((root / name).exists() for name in FILES)
            else:
                assert not list(root.iterdir()), "completed restore left transport files"
        finally:
            stop(helper)
            stop(successor)
            stop(watcher)
    print("PASS older watcher preserves newer restore" if newer else
          "PASS completed restore cleans private transport")


def cancelled_restore(mode):
    with tempfile.TemporaryDirectory(prefix="virtualmac-cancel-") as work:
        root = Path(work)
        prepare(root, 0)
        # The readiness write runs after the real watcher installs its signal
        # trap, so cancellation does not depend on scheduler timing.
        watcher = WATCHER.replace(
            '    while kill -0 "$restore_process_pid"',
            '    echo ready > "$temporary/watcher-ready"\n'
            '    while kill -0 "$restore_process_pid"', 1)
        script = ('set -eu\n'
                  'sleep 30 &\n'
                  'started_helper_pid=$!\n'
                  'echo "$started_helper_pid" > "$temporary/vz-usbmuxd.pid"\n'
                  'restore_process_pid=$$\n(\n' + watcher + '\n) &\nwait\n')
        parent = subprocess.Popen(["/bin/sh", "-c", script],
                                  env=environment(root, mode), start_new_session=True)
        finished = False
        try:
            wait_until(lambda: (root / "watcher-ready").exists(),
                       "cleanup watcher did not initialize")
            os.killpg(parent.pid, signal.SIGTERM)
            parent.wait(timeout=5)
            if mode == "1":
                wait_until(lambda: not any((root / name).exists() for name in FILES)
                           and not (root / "usbmuxd").is_symlink(),
                           "cancelled restore did not clean transport")
                assert not any((root / name).exists() for name in FILES)
                assert not (root / "usbmuxd").is_symlink()
            else:
                assert (root / "vz-usbmuxd.pid").exists()
                assert (root / "vz-usb-restore.sock").exists()
            finished = True
        finally:
            # Only this test's freshly-created session is signalled.
            if not finished:
                try:
                    os.killpg(parent.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            stop(parent)
    print("PASS RootHide cancellation cleans private transport" if mode == "1" else
          "PASS standard cancellation signal behavior unchanged")


if __name__ == "__main__":
    completed_restore(False)
    completed_restore(True)
    cancelled_restore("0")
    cancelled_restore("1")
