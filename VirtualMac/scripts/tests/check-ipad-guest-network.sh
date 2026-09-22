#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${VZ_GUEST_HOST:?set VZ_GUEST_HOST to the guest address}"
: "${VZ_GUEST_USER:?set VZ_GUEST_USER to the guest SSH user}"
GUEST_HOST="$VZ_GUEST_HOST"
GUEST_USER="$VZ_GUEST_USER"
GUEST_PORT="${VZ_GUEST_USB_PORT:-2208}"
: "${VZ_GUEST_PASSWORD:?set VZ_GUEST_PASSWORD in .env or the environment}"

need_command curl
need_command lsof
need_command ssh
need_command sshpass
ensure_ipad_usb

if lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "local guest SSH port $GUEST_PORT is already in use"
fi

sshpass -p "$VZ_IPAD_PASSWORD" ssh \
    "${IPAD_SSH_ARGS[@]}" \
    -o ControlMaster=no -o ControlPath=none \
    -N -L "127.0.0.1:$GUEST_PORT:$GUEST_HOST:22" \
    "$IPAD_TARGET" &
tunnel_pid=$!
cleanup() {
    # sshpass exits after authentication and leaves ssh re-parented, so the
    # original background PID alone is not sufficient to close the tunnel.
    listener_pids="$(lsof -t -iTCP:"$GUEST_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$listener_pids" ]]; then
        # shellcheck disable=SC2086
        kill $listener_pids 2>/dev/null || true
    fi
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..40}; do
    lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
    kill -0 "$tunnel_pid" 2>/dev/null ||
        die "iPad guest SSH tunnel exited before opening"
    sleep 0.25
done
lsof -nP -iTCP:"$GUEST_PORT" -sTCP:LISTEN >/dev/null 2>&1 ||
    die "iPad guest SSH tunnel did not open"

remote_check=$'set -eu\n'
remote_check+=$'address=$(ipconfig getifaddr en0)\n'
remote_check+=$'test -n "$address"\n'
remote_check+=$'echo "guest IPv4: $address"\n'
remote_check+=$'route -n get default | grep "gateway:"\n'
# The watchdog repairs the stale DHCP/ARP state that survives a host network
# change. Assert the payload shipped it and launchd loaded it; whether it
# actually repairs is only observable by switching the host network.
remote_check+=$'test -x /Library/VirtualMac/network-watchdog.sh\n'
remote_check+=$'launchctl print system/com.mac.virtual.network-watchdog >/dev/null\n'
remote_check+=$'echo "guest network watchdog: loaded"\n'
remote_check+=$'for url in https://google.com https://apple.com https://macrumors.com https://9to5mac.com; do\n'
remote_check+=$'  curl -4 -ILsS --connect-timeout 8 --max-time 25 -o /dev/null -w "$url code=%{http_code} remote=%{remote_ip}\\n" "$url"\n'
remote_check+=$'done\n'

sshpass -p "$VZ_GUEST_PASSWORD" ssh \
    -p "$GUEST_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    "$GUEST_USER@127.0.0.1" "$remote_check"
