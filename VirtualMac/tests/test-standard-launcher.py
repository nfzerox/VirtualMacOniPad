#!/usr/bin/env python3
"""Compare original/current launcher decisions with destructive syscalls stubbed."""

import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
library = "/var/mobile/Media/VirtualMac"
image = library + "/Restore Images/macOS test.ipsw"
attempt = library + "/Installations/Test.installation"
valid = [image, attempt + "/Staging.bundle.installing", library + "/Test.bundle",
         attempt + "/Installer.install.log", "4", "4294967296", "68719476736"]
cases = [[], ["--diagnose"], valid, ["--unknown"], valid[:-1], valid + ["extra"]]
for number in ("0", "1", "987654", "-1", "1x", ""):
    cases.append(["--cancel-install", number, attempt])
for path in (attempt, image, library, library + "-other/a.installation",
             attempt + "/../data", attempt + "/..", attempt + "\nx"):
    cases += [["--delete-artifact", path], ["--cancel-install", "1234", path]]
for index, values in enumerate((
    [image + "x", image.replace(".ipsw", ".zip"), image.replace(".ipsw", ".IPSW"),
     library + "/Restore ImagesX/a.ipsw", library + "/Restore Images/../a.ipsw"],
    [attempt + "/bad", attempt + "/../x.bundle.installing"],
    [library + "/nested/Test.bundle", library + "/Test.bundle/", library + "/测试 VM.bundle"],
    [attempt + "/bad", attempt + "/x\n.install.log"],
    ["", "-4", "4x", "04"], ["", "4294967296x", "0"], ["", "0", "99999999999999999999"],
)):
    for value in values:
        changed = valid.copy()
        changed[index] = value
        cases.append(changed)
count = 0
for rootless in (False, True):
    for deny_root in (False, True):
        env = {key: value for key, value in os.environ.items()
               if key not in ("TEST_ROOTLESS", "TEST_DENY_ROOT")}
        if rootless:
            env["TEST_ROOTLESS"] = "1"
        if deny_root:
            env["TEST_DENY_ROOT"] = "1"
        for arguments in cases:
            results = []
            for version in ("original", "current"):
                result = subprocess.run([str(root / version), *arguments], env=env,
                                        capture_output=True, timeout=3)
                results.append((result.returncode, result.stdout, result.stderr))
            assert results[0] == results[1], (rootless, deny_root, arguments, results)
            count += 1
print(f"PASS standard launcher: {count} original/current behavior comparisons")
