#!/bin/bash

set -euo pipefail

VZ_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VZ_BUILD_ROOT="${VZ_BUILD_ROOT:-$VZ_REPO_ROOT/build}"
# Virtual Mac is intended to work on iPhone and iPad devices running iOS/iPadOS
# 14 and newer. The runtime must still verify the actual host OS; the build
# system should not reject newer releases ahead of the oldest supported version.
VZ_IPADOS_MIN_VERSION="${VZ_IPADOS_MIN_VERSION:-14.5}"

# Accept any iOS/iPadOS version starting at 14.0. This intentionally removes the
# previous 14.5/15.0-only hard stop while still preserving a minimum floor.
python3 - "$VZ_IPADOS_MIN_VERSION" <<'PY'
import sys
version = sys.argv[1]
parts = version.split('.')
if len(parts) < 2:
    raise SystemExit("error: VZ_IPADOS_MIN_VERSION must be a dotted version like 14.5")
try:
    major = int(parts[0])
    minor = int(parts[1])
except ValueError as exc:
    raise SystemExit(f"error: invalid version: {version!r}") from exc
if major < 14:
    raise SystemExit("error: VZ_IPADOS_MIN_VERSION must be 14.0 or newer")
PY
export VZ_IPADOS_MIN_VERSION

# StickDebug/JIT is required before launching the VM on-device. The build system
# can warn early without blocking the package export.
export VZ_STICKDEBUG_JIT_REQUIRED="${VZ_STICKDEBUG_JIT_REQUIRED:-1}"

if [[ "${VZ_IGNORE_ENV_FILE:-0}" != 1 && -f "$VZ_REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$VZ_REPO_ROOT/.env"
    set +a
fi

die() {
    echo "error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

need_file() {
    [[ -f "$1" ]] || die "missing file: $1"
}

real_mac_ssh_args() {
    : "${VZ_REAL_MAC_HOST:?set VZ_REAL_MAC_HOST in .env or the environment}"
    VZ_REAL_MAC_PORT="${VZ_REAL_MAC_PORT:-22}"
    : "${VZ_REAL_MAC_USER:?set VZ_REAL_MAC_USER in .env or the environment}"
    : "${VZ_REAL_MAC_PASSWORD:?set VZ_REAL_MAC_PASSWORD in .env or the environment}"

    REAL_MAC_SSH_ARGS=(
        -p "$VZ_REAL_MAC_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
    )
    REAL_MAC_SCP_ARGS=(
        -P "$VZ_REAL_MAC_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
    )
    REAL_MAC_TARGET="$VZ_REAL_MAC_USER@$VZ_REAL_MAC_HOST"
}

real_mac_ssh() {
    real_mac_ssh_args
    sshpass -p "$VZ_REAL_MAC_PASSWORD" ssh "${REAL_MAC_SSH_ARGS[@]}" "$REAL_MAC_TARGET" "$@"
}

real_mac_scp() {
    real_mac_ssh_args
    sshpass -p "$VZ_REAL_MAC_PASSWORD" scp "${REAL_MAC_SCP_ARGS[@]}" "$@"
}

ipad_ssh_args() {
    if [[ -z "${VZ_IPAD_UDID:-}" ]]; then
        need_command idevice_id
        local devices count
        devices="$(idevice_id -l)"
        count="$(printf '%s\n' "$devices" | awk 'NF { count++ } END { print count+0 }')"
        [[ "$count" == 1 ]] ||
            die "attach exactly one iPhone or iPad or set VZ_IPAD_UDID"
        VZ_IPAD_UDID="$devices"
    fi
    VZ_IPAD_PORT="${VZ_IPAD_PORT:-2221}"
    # Package installation, trust-cache updates, and userspace restart are
    # privileged operations. The supported Dopamine deployment is root-only.
    VZ_IPAD_USER=root
    : "${VZ_IPAD_PASSWORD:?set VZ_IPAD_PASSWORD in .env or the environment}"
    local control_path="/tmp/VirtualMac-ssh-%C"

    IPAD_SSH_ARGS=(
        -p "$VZ_IPAD_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
        -o ControlMaster=auto
        -o ControlPersist=60
        -o "ControlPath=$control_path"
    )
    IPAD_SCP_ARGS=(
        -P "$VZ_IPAD_PORT"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o PubkeyAuthentication=no
        -o PreferredAuthentications=password
        -o NumberOfPasswordPrompts=1
        -o ControlMaster=auto
        -o ControlPersist=60
        -o "ControlPath=$control_path"
    )
    IPAD_TARGET="$VZ_IPAD_USER@127.0.0.1"
}

ensure_ipad_usb() {
    ipad_ssh_args
    need_command iproxy
    mkdir -p "$VZ_BUILD_ROOT"
    if lsof -nP -iTCP:"$VZ_IPAD_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        return
    fi

    nohup iproxy -u "$VZ_IPAD_UDID" -l -s 127.0.0.1 \
        "$VZ_IPAD_PORT:22" >"$VZ_BUILD_ROOT/iproxy.log" 2>&1 </dev/null &
    for _ in {1..20}; do
        lsof -nP -iTCP:"$VZ_IPAD_PORT" -sTCP:LISTEN >/dev/null 2>&1 &&
            return
        sleep 0.25
    done
    die "iproxy did not open USB SSH port $VZ_IPAD_PORT"
}

ipad_ssh() {
    ensure_ipad_usb
    sshpass -p "$VZ_IPAD_PASSWORD" ssh \
        "${IPAD_SSH_ARGS[@]}" "$IPAD_TARGET" "$@"
}

ipad_scp() {
    ensure_ipad_usb
    sshpass -p "$VZ_IPAD_PASSWORD" scp "${IPAD_SCP_ARGS[@]}" "$@"
}

if [[ "${VZ_STICKDEBUG_JIT_REQUIRED:-0}" == "1" ]]; then
    echo "note: StickDebug JIT must be enabled before launching Virtual Mac on-device." >&2
fi
