#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
OUT="$VZ_BUILD_ROOT/tests/roothide-storage"
mkdir -p "$OUT"

# Exercise the application's real persistence function without loading UIKit
# or the extracted iOS virtualization frameworks into the host test process.
python3 - "$VZ_REPO_ROOT/vz/host/VirtualMacApp.m" "$OUT/installation-attempt.inc" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('static void VZWriteInstallationAttempt(')
end = source.index('\n- (BOOL)prefersStatusBarHidden', start)
pathlib.Path(sys.argv[2]).write_text(source[start:end])
library = pathlib.Path(sys.argv[1]).with_name('VZVMLibraryViewController.m').read_text()
start = library.index('BOOL VZWriteVMOptions(')
end = library.index('\nBOOL VZIsValidVMBundle(', start)
pathlib.Path(sys.argv[2]).with_name('write-vm-options.inc').write_text(library[start:end])
PY

for mode in standard roothide; do
    compile=(xcrun --sdk macosx clang -Wall -Wextra -Werror -fblocks
        -framework Foundation -I"$OUT")
    if [[ "$mode" == roothide ]]; then
        compile+=(-DVZ_ROOTHIDE -I"$VZ_REPO_ROOT/tests/fixtures")
    fi
    "${compile[@]}" \
        "$VZ_REPO_ROOT/tests/test-roothide-storage.m" \
        "$VZ_REPO_ROOT/vz/host/VZAppSettings.m" -o "$OUT/$mode"
    "$OUT/$mode" "$OUT"
done
