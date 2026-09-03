#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RECEIVER="$REPO_ROOT/build/guest-gamepad-probe"

PORT=${VZ_GAMEPAD_PORT:-25863}
TIMEOUT_MS=${VZ_GAMEPAD_TIMEOUT_MS:-750}
TRANSPORT=${VZ_GAMEPAD_TRANSPORT:-vsock}
PRINT_STATE=0

usage() {
    cat <<EOF
usage: sudo $0 [--transport vsock|udp] [--port PORT]
               [--timeout-ms MILLISECONDS] [--stats] [--print-state]

Starts the command-line VirtualMac gamepad-to-IOHID receiver with the generic
HID profile used by Steam Input and Wine. Virtio Socket is the default and does
not require guest networking. Environment overrides:
  VZ_GAMEPAD_TRANSPORT  default: vsock
  VZ_GAMEPAD_PORT       default: 25863
  VZ_GAMEPAD_TIMEOUT_MS default: 750
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --transport)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            TRANSPORT=$2
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            PORT=$2
            shift 2
            ;;
        --timeout-ms)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            TIMEOUT_MS=$2
            shift 2
            ;;
        --print-state)
            PRINT_STATE=1
            shift
            ;;
        --stats)
            # Statistics are enabled by default; accept the explicit spelling
            # used in documentation and manual test commands.
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$TRANSPORT" == vsock || "$TRANSPORT" == udp ]] || {
    echo "transport must be vsock or udp" >&2
    exit 2
}

[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || {
    echo "port must be between 1 and 65535" >&2
    exit 2
}
[[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] &&
    ((TIMEOUT_MS >= 100 && TIMEOUT_MS <= 10000)) || {
    echo "timeout must be between 100 and 10000 milliseconds" >&2
    exit 2
}
[[ -x "$RECEIVER" ]] || {
    echo "receiver is not built: $RECEIVER" >&2
    echo "run VirtualMac/scripts/development/build-guest-gamepad-probe.sh first" >&2
    exit 1
}
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "creating the virtual HID device requires root in this VM" >&2
    echo "run: sudo $0 --transport $TRANSPORT --port $PORT --timeout-ms $TIMEOUT_MS" >&2
    exit 1
fi

arguments=(
    --transport "$TRANSPORT"
    --port "$PORT"
    --timeout-ms "$TIMEOUT_MS"
    --stats
)
if [[ "$PRINT_STATE" == 1 ]]; then
    arguments+=(--print-state)
fi

echo "[gamepad-start] generic IOHID receiver: $TRANSPORT $PORT, timeout ${TIMEOUT_MS}ms"
exec "$RECEIVER" "${arguments[@]}"
