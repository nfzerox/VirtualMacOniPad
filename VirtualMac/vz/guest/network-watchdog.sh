#!/bin/sh
#
# Virtual Mac guest network watchdog
#
# Runs inside the macOS guest of "Virtual Mac on iPad". Detects the state that
# breaks after the *host* (iPad) changes network, and repairs it without the
# user having to disable/re-enable the adapter by hand.
#
# Why polling instead of a link/path event:
#   The guest NIC is virtio. Its link never drops and its IPv4 address/subnet
#   normally stays valid, so neither an interface status change nor
#   NWPathMonitor reports anything when the iPad switches Wi-Fi. The only
#   reliable in-guest symptom is that the default gateway stops answering.
#
# Detection:
#   Ping the *default gateway* (the host bridge or the real LAN router), not the
#   internet. This deliberately distinguishes "guest-side state is stale" from
#   "the iPad itself is offline": if the iPad has no uplink but the link is
#   healthy, the gateway still answers and we do nothing.
#
# Repair ladder (cheapest first, stops as soon as the gateway answers):
#   1. flush the stale ARP entry and force a re-probe
#   2. renew the DHCP lease   (same as System Settings > Renew DHCP Lease)
#   3. bounce the interface   (link layer restart plus a renew)
#   4. toggle the network service (same as the manual adapter off/on)
#
#   Every step waits for the gateway to come back before the next one runs.
#   Fixed sleeps used to declare a repair failed while DHCP was still in
#   progress, which escalated to a disruptive step for no reason and could
#   leave the reported state wrong.
#
# Optional config file: /Library/VirtualMac/network-watchdog.conf
#   INTERVAL=3          seconds between health checks
#   FAILS=3             consecutive failures before repairing
#   INTERFACE=en0       force an interface (default: autodetect)
#   SAFETY_RENEW=0      seconds between unconditional DHCP renews (0 = off)
#   MAX_BACKOFF=60      slowest retry interval after repeated failures
#   ARP_WAIT=2          seconds to wait after flushing ARP
#   RENEW_WAIT=4        seconds to wait after a DHCP renew
#   BOUNCE_WAIT=10      seconds to wait after bouncing the interface
#   SERVICE_WAIT=10     seconds to wait after toggling the network service

set -u

CONFIG=/Library/VirtualMac/network-watchdog.conf
LOG=/var/log/virtualmac-network-watchdog.log

INTERVAL=3
FAILS=3
INTERFACE=""
SAFETY_RENEW=0
MAX_BACKOFF=60
ARP_WAIT=2
RENEW_WAIT=4
BOUNCE_WAIT=10
SERVICE_WAIT=10

if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

# Network service name, resolved once while the network is healthy. Resolving it
# during a repair is unreliable: networksetup talks to configd, which can return
# nothing useful while the network is being reconfigured. That used to disable
# the last-resort step exactly when it was needed.
SERVICE=""

log() {
    printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

# Interface carrying the default route, falling back to the first usable en*.
iface() {
    if [ -n "$INTERFACE" ]; then
        printf '%s' "$INTERFACE"
        return
    fi
    i=$(/sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/interface:/{print $2; exit}')
    if [ -z "${i:-}" ]; then
        for candidate in en0 en1 en2 en3; do
            if /sbin/ifconfig "$candidate" >/dev/null 2>&1; then
                i=$candidate
                break
            fi
        done
    fi
    printf '%s' "${i:-}"
}

# Current default gateway.
gateway() {
    /sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/gateway:/{print $2; exit}'
}

healthy() {
    g=$(gateway)
    [ -n "${g:-}" ] || return 1
    /sbin/ping -c 1 -W 800 -q "$g" >/dev/null 2>&1
}

# Wait up to $1 seconds for the gateway to answer again.
wait_for_gateway() {
    wg_remaining=$1
    while [ "$wg_remaining" -gt 0 ]; do
        healthy && return 0
        /bin/sleep 1
        wg_remaining=$((wg_remaining - 1))
    done
    healthy
}

# Name of the network service backed by $1, e.g. "Ethernet". Retries briefly,
# because this is only meaningful while the network is usable.
resolve_service() {
    rs_dev=$1
    [ -n "${rs_dev:-}" ] || return 1
    rs_tries=0
    while [ "$rs_tries" -lt 3 ]; do
        rs_name=$(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null |
            /usr/bin/awk -v dev="$rs_dev" '
                /^\([0-9]+\)/ {
                    name = $0
                    sub(/^\([0-9]+\) /, "", name)
                    next
                }
                index($0, "Device: " dev ")") { print name; exit }
            ')
        if [ -n "${rs_name:-}" ]; then
            printf '%s' "$rs_name"
            return 0
        fi
        rs_tries=$((rs_tries + 1))
        /bin/sleep 1
    done
    return 1
}

# Returns 0 as soon as the gateway answers again.
repair() {
    i=$(iface)
    if [ -z "${i:-}" ]; then
        log "repair aborted: no interface found"
        return 1
    fi

    # 1. Drop stale ARP state and force a fresh resolution. Cheap, and it does
    #    not disturb connections that are still working.
    g=$(gateway)
    [ -n "${g:-}" ] && /usr/sbin/arp -d "$g" 2>/dev/null
    /usr/sbin/arp -d -a 2>/dev/null
    wait_for_gateway "$ARP_WAIT" && return 0

    # 2. Renew the lease: refreshes address, router and DNS configuration.
    /usr/sbin/ipconfig set "$i" DHCP 2>/dev/null
    wait_for_gateway "$RENEW_WAIT" && return 0

    # 3. Bounce the interface. After the host moves to a different subnet this
    #    is the step that actually recovers the guest, and the DHCP exchange it
    #    triggers can take several seconds, so wait before judging it failed.
    /sbin/ifconfig "$i" down 2>/dev/null
    /bin/sleep 1
    /sbin/ifconfig "$i" up 2>/dev/null
    /usr/sbin/ipconfig set "$i" DHCP 2>/dev/null
    wait_for_gateway "$BOUNCE_WAIT" && return 0

    # 4. Last resort: toggle the network service. This is the scripted form of
    #    the "disable the adapter, then enable it" workaround, and it rebuilds
    #    the service's DHCP client state that ifconfig alone may not reset.
    if [ -n "${SERVICE:-}" ]; then
        log "escalating: toggling network service '$SERVICE'"
        /usr/sbin/networksetup -setnetworkserviceenabled "$SERVICE" off 2>/dev/null
        /bin/sleep 2
        /usr/sbin/networksetup -setnetworkserviceenabled "$SERVICE" on 2>/dev/null
        /usr/sbin/ipconfig set "$i" DHCP 2>/dev/null
        wait_for_gateway "$SERVICE_WAIT"
        return $?
    fi
    log "escalating: no network service name cached; cannot toggle it"
    return 1
}

boot_iface=$(iface)
boot_gateway=$(gateway)
if [ -n "$boot_iface" ]; then
    SERVICE=$(resolve_service "$boot_iface")
fi
log "watchdog started (interval=${INTERVAL}s fails=${FAILS} iface=${boot_iface} gateway=${boot_gateway} service=${SERVICE})"

failures=0
backoff=0
last_repair=0
last_safety=$(/bin/date +%s)

while :; do
    if healthy; then
        if [ "$failures" -ge "$FAILS" ]; then
            log "gateway reachable again"
        fi
        # If the watchdog started while the network was already broken there was
        # no healthy moment to resolve the service name; take one now.
        if [ -z "${SERVICE:-}" ]; then
            i=$(iface)
            if [ -n "${i:-}" ]; then
                resolved=$(resolve_service "$i")
                if [ -n "${resolved:-}" ]; then
                    SERVICE=$resolved
                    log "resolved network service '$SERVICE'"
                fi
            fi
        fi
        failures=0
        backoff=0
    else
        failures=$((failures + 1))
        if [ "$failures" -ge "$FAILS" ]; then
            now=$(/bin/date +%s)
            # Never repair more often than every 15s, and back off when the
            # repair keeps failing (e.g. a gateway that filters ICMP).
            if [ $((now - last_repair)) -ge 15 ]; then
                last_repair=$now
                log "gateway unreachable (${failures} checks); repairing iface=$(iface)"
                if repair; then
                    log "repair succeeded"
                    failures=0
                    backoff=0
                else
                    backoff=$((backoff + INTERVAL))
                    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
                    log "repair failed; next attempt in ~$((INTERVAL + backoff))s"
                fi
            fi
        fi
    fi

    # Optional safety net: an unconditional periodic renew, useful if the
    # gateway stops answering ICMP but the link state is still stale.
    if [ "${SAFETY_RENEW:-0}" -gt 0 ]; then
        now=$(/bin/date +%s)
        if [ $((now - last_safety)) -ge "$SAFETY_RENEW" ]; then
            last_safety=$now
            i=$(iface)
            [ -n "${i:-}" ] && /usr/sbin/ipconfig set "$i" DHCP 2>/dev/null
        fi
    fi

    /bin/sleep $((INTERVAL + backoff))
done
