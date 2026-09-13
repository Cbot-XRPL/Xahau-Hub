#!/usr/bin/env bash
# provision/02-net-check.sh — verify the NETWORK assumptions before a VM that
# depends on them exists.
#
# 01-space-check.sh re-derives the disk math from live lvs output and refuses
# to proceed on a stale number. Nothing did the equivalent for the network,
# and an unverified `gateway:` in inventory.yml produced a VM that booted
# fine, answered ssh on the LAN, and could not reach the internet at all —
# which then looked like apt hanging rather than a wrong gateway.
#
# Checks, from the Proxmox host:
#   1. the inventory gateway actually answers (ARP + ping)
#   2. it matches the gateway the host itself uses
#   3. DNS resolves
#   4. each declared node address is FREE (nothing else is using it)
#   5. the bridge exists
#   6. the endpoints bootstrap needs are reachable
#
# Usage: provision/02-net-check.sh [NODE...] [--remote]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

REMOTE=0; TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done
[ "${#TARGETS[@]}" -gt 0 ] || mapfile -t TARGETS < <("$INV" nodes --enabled)

run() { if [ "$REMOTE" = 1 ]; then host_ssh "$@"; else bash -c "$*"; fi; }
[ "$REMOTE" = 1 ] || guard_require_host

GW="$("$INV" get cluster.defaults.gateway)"
BRIDGE="$("$INV" get cluster.defaults.bridge)"
RC=0

hdr "1. gateway $GW"
HOST_GW="$(run "ip route | awk '/^default/{print \$3; exit}'" | tr -d '\r')"
printf '  %-26s %s\n' "inventory says"     "$GW"
printf '  %-26s %s\n' "the host actually uses" "${HOST_GW:-unknown}"
if [ -n "$HOST_GW" ] && [ "$HOST_GW" != "$GW" ]; then
  err "MISMATCH. inventory.yml declares $GW but this host routes via $HOST_GW."
  err "A VM built with the wrong gateway boots, answers ssh on the LAN, and has NO internet."
  err "The symptom is apt hanging, which sends you looking in the wrong place entirely."
  err "Fix cluster.defaults.gateway in inventory.yml."
  RC=1
elif [ -z "$HOST_GW" ]; then
  warn "could not read the host's default route"
else
  ok "matches the host's default route"
fi

if run "ping -c2 -W2 $GW >/dev/null 2>&1"; then
  ok "$GW answers ping"
else
  err "$GW does not answer. Nothing there to route through."
  RC=1
fi

hdr "2. dns"
NS="$("$INV" get cluster.defaults.nameservers)"
printf '  %-26s %s\n' "nameservers" "$NS"
if run "getent hosts build.xahau.tech >/dev/null 2>&1"; then
  ok "resolution works from the host"
else
  warn "the host cannot resolve build.xahau.tech — guests may inherit the problem"
  [ "$RC" = 0 ] && RC=1
fi

hdr "3. bridge $BRIDGE"
if run "ip link show $BRIDGE >/dev/null 2>&1"; then
  ok "$BRIDGE exists"
  run "ip -4 -br addr show $BRIDGE" | sed 's/^/  /'
else
  err "$BRIDGE does not exist on this host"
  RC=1
fi

hdr "4. node addresses are free"
for n in "${TARGETS[@]}"; do
  guard_reject_target "$n"
  addr="$("$INV" node "$n" address)"
  vmid="$("$INV" node "$n" vmid)"
  # If the VM already exists, its own address answering is expected and fine.
  exists=0
  run "test -e /etc/pve/qemu-server/$vmid.conf" >/dev/null 2>&1 && exists=1
  if run "ping -c1 -W1 $addr >/dev/null 2>&1"; then
    if [ "$exists" = 1 ]; then
      ok "$(printf '%-14s %-16s in use by vmid %s (itself)' "$n" "$addr" "$vmid")"
    else
      err "$(printf '%-14s %-16s IS ALREADY IN USE by something else' "$n" "$addr")"
      err "  vmid $vmid does not exist yet, so something on the LAN already holds $addr."
      err "  Building on top of it means an address conflict. Pick another in inventory.yml."
      RC=1
    fi
  else
    ok "$(printf '%-14s %-16s free' "$n" "$addr")"
  fi
done

hdr "5. endpoints bootstrap needs"
for url in \
  "$("$INV" get cluster.defaults.installer_url)" \
  "https://build.xahau.tech/" \
  "https://vl.xahau.org" \
  "http://archive.ubuntu.com/ubuntu/" ; do
  code="$(run "curl -so /dev/null -w '%{http_code}' --max-time 15 '$url' 2>/dev/null" || echo 000)"
  case "$code" in
    2*|3*) ok "$(printf '%-6s %s' "$code" "$url")" ;;
    *)     err "$(printf '%-6s %s  UNREACHABLE' "${code:-000}" "$url")"; RC=1 ;;
  esac
done

hdr "verdict"
if [ "$RC" = 0 ]; then ok "network check PASSED"; else err "network check FAILED — fix before creating VMs"; fi
exit "$RC"
