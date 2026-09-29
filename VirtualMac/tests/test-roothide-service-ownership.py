#!/usr/bin/env python3
"""Exercise maintainer-script service ownership without touching launchd."""

import os
from pathlib import Path
import subprocess

PACKAGING = Path(__file__).parents[1] / "packaging/roothide"
ROOT = "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
PLIST = ROOT + "/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
MOCKS = r'''
set -eu
native_root="$TEST_ROOT"
network_domain=user/501
jbroot() { printf '%s\n' "$TEST_ROOT/"; }
launchctl() {
    if test "$1" = print; then
        test "$2" = "$TEST_JOB" || return 1
        printf '%s\n' "$TEST_JOB = {" '    state = running'
        if test "$TEST_PATH" != missing; then
            printf '    path = %s\n' "$TEST_PATH"
        fi
        printf '}\n'
    else
        printf '%s\n' "$*"
    fi
}
'''


def script_body(name):
    text = (PACKAGING / name).read_text()
    if name == "postinst":
        start = text.index("native_root=$(jbroot /)")
        end = text.index("\nuicache -p", start)
    else:
        start = text.index("for domain in system user/501;")
        end = text.index('\nif test -x "$process_helper";', start)
    return text[start:end]


def main():
    cases = [
        (PLIST, True),
        ("/private" + PLIST, True),
        (PLIST + ".other", False),
        (PLIST + "/nested", False),
        (PLIST.replace(".jbroot-0123456789ABCDEF", ".jbroot-FEDCBA9876543210"), False),
        ("/System/Library/LaunchDaemons/com.apple.NetworkSharing.plist", False),
        ("missing", False),
    ]
    checked = 0
    for name in ("postinst", "stop-runtime.sh"):
        body = script_body(name)
        for domain in ("system", "user/501"):
            for path, owned in cases:
                job = domain + "/com.apple.NetworkSharing"
                env = {**os.environ, "TEST_ROOT": ROOT, "TEST_JOB": job,
                       "TEST_PATH": path}
                result = subprocess.run(["/bin/sh", "-c", MOCKS + body],
                                        env=env, capture_output=True, text=True,
                                        timeout=5)
                conflict = name == "postinst" and domain == "user/501" and not owned
                assert result.returncode == (1 if conflict else 0), (name, env, result)
                operations = result.stdout.splitlines()
                removed = [line for line in operations if line.startswith("bootout ")]
                assert removed == (["bootout " + job] if owned else []), (name, path, result)
                if conflict:
                    assert "another package owns " + job in result.stderr
                    assert not operations, "conflicting service was modified"
                elif name == "postinst":
                    assert "bootstrap user/501 /Library/LaunchDaemons/com.apple.NetworkSharing.plist" in operations
                    assert "bootstrap user/501 /Library/LaunchDaemons/com.apple.bootpd.plist" in operations
                checked += 1
    print(f"PASS RootHide service ownership: {checked} exact-path, alias, conflict and missing-path cases")


if __name__ == "__main__":
    main()
