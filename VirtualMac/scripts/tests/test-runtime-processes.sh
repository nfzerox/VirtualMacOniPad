#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/runtime-processes"
mkdir -p "$OUT"
xcrun --sdk macosx clang -Wall -Wextra -Werror -DVZ_ROOTHIDE \
    -I"$VZ_REPO_ROOT/tests/fixtures" \
    -Dgeteuid=test_geteuid -Dgetpid=test_getpid -Drealpath=test_realpath \
    -Dkill=test_kill -Dusleep=test_usleep \
    "$VZ_REPO_ROOT/vz/install/roothide_runtime_processes.c" \
    "$VZ_REPO_ROOT/tests/fixtures/runtime-processes.c" -o "$OUT/runtime-processes"
python3 - "$OUT/runtime-processes" <<'PY'
import os
import subprocess
import sys

binary = sys.argv[1]
env = {k: v for k, v in os.environ.items() if not k.startswith('TEST_')}
expected = ['101', '103', '104', '106', '107']
listed = subprocess.run([binary, '--list'], env=env, capture_output=True, text=True, check=True)
assert listed.stdout.splitlines() == expected
vms = subprocess.run([binary, '--list-vms'], env=env, capture_output=True, text=True, check=True)
assert vms.stdout.splitlines() == ['101', '106']
guests = subprocess.run([binary, '--list-guests'], env=env, capture_output=True, text=True, check=True)
assert guests.stdout.splitlines() == ['106']
stopped = subprocess.run([binary, '--stop'], env=env, capture_output=True, text=True, check=True)
assert stopped.stdout.splitlines() == ['stop ' + p for p in expected]
for flag in ('TEST_NOT_ROOT', 'TEST_LIST_ERROR', 'TEST_STILL_RUNNING'):
    result = subprocess.run([binary, '--stop'], env={**env, flag: '1'},
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 1, (flag, result)
    assert 'stop ' not in result.stdout or flag == 'TEST_STILL_RUNNING'
result = subprocess.run([binary, '--stop'], env={**env, 'TEST_MISSING_FILES': '1'},
                        capture_output=True, text=True, check=True)
assert not result.stdout
print('PASS native lifecycle selection excludes system/other-root/suffix matches; errors fail safely')
PY
