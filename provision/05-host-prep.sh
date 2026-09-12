#!/usr/bin/env bash
# provision/05-host-prep.sh — prepare pve2 BEFORE any node exists.
#
# The monitoring is the safety net for running a growing database on the same
# array as everything else, so it goes up first. 700 GiB without
# growth-watch.sh running is worse than 500 GiB with it.
#
# Does, idempotently:
#   1. thin_pool_autoextend_threshold / _percent in /etc/lvm/lvm.conf
#   2. installs ops/growth-watch.sh + lib/ to /opt/xahau-hub on the host
#   3. host cron for growth-watch.sh (thin pool data% and metadata%)
#   4. sanity-checks the Ubuntu ISO / cloud image availability
#
# Usage: provision/05-host-prep.sh [--no-cron]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
[ "${1:-}" = "-h" ] && { sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

guard_require_host
need lvs; need qm

THRESH="$("$INV" get cluster.thresholds.lvm_autoextend_threshold)"
PCT="$("$INV" get cluster.thresholds.lvm_autoextend_percent)"
GROWTH_CRON="$("$INV" get cluster.thresholds.growth_interval)"
DEST=/opt/xahau-hub

hdr "1. lvm.conf thin pool autoextend"
CONF=/etc/lvm/lvm.conf
[ -f "$CONF" ] || die "$CONF not found"
cp -a "$CONF" "${CONF}.xahau-hub.bak.$(date -u +%Y%m%d%H%M%S)"

set_lvm() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CONF"; then
    sed -i -E "s|^([[:space:]]*)${key}[[:space:]]*=.*|\1${key} = ${val}|" "$CONF"
  elif grep -qE "^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=" "$CONF"; then
    sed -i -E "0,/^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=.*/s||\t${key} = ${val}|" "$CONF"
  else
    sed -i -E "s|^(activation \{)|\1\n\t${key} = ${val}|" "$CONF"
  fi
  local got; got="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONF" | head -1 | tr -s ' ')"
  printf '  %s\n' "${got# }"
}
# threshold 100 disables autoextend entirely; we want the *alert*, and with
# percent=0 LVM will not silently grow the pool past what we planned for.
set_lvm thin_pool_autoextend_threshold "$THRESH"
set_lvm thin_pool_autoextend_percent   "$PCT"
info "percent=$PCT means: do NOT autoextend, alert only. This host does not overcommit;"
info "growing the pool is a deliberate decision with the math redone, not an automatic one."
lvm dumpconfig activation 2>/dev/null | grep -E 'thin_pool_autoextend' || true

hdr "2. install ops tooling to $DEST"
mkdir -p "$DEST"
for d in lib ops config; do
  mkdir -p "$DEST/$d"
  cp -a "$REPO_ROOT/$d/." "$DEST/$d/" 2>/dev/null || true
done
install -m 644 "$REPO_ROOT/inventory.yml" "$DEST/inventory.yml"
rm -rf "$DEST/out" "$DEST/secrets"
chmod -R go-rwx "$DEST"
ok "installed $DEST (inventory + lib + ops + config)"

hdr "3. host cron — growth-watch"
if [ "${1:-}" = "--no-cron" ]; then
  warn "--no-cron: skipping cron install"
else
  CRONF=/etc/cron.d/xahau-hub-growth
  cat > "$CRONF" <<CRON
# xahau-hub — thin pool + DB growth watch on $(hostname -s). Managed by
# provision/05-host-prep.sh. Alerts at ${GROWTH_CRON}.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
$GROWTH_CRON root XAH_REPO_ROOT=$DEST $DEST/ops/growth-watch.sh --mode host >>/var/log/xahau-growth.log 2>&1
CRON
  chmod 644 "$CRONF"
  ok "installed $CRONF"
  XAH_REPO_ROOT="$DEST" "$DEST/ops/growth-watch.sh" --mode host || warn "first growth-watch run reported a problem (see above)"
fi

hdr "4. install media check"
ISO="$("$INV" get cluster.defaults.iso)"
ISO_FILE="/var/lib/vz/template/iso/${ISO##*/}"
if [ -f "$ISO_FILE" ]; then
  ok "ISO present: $ISO_FILE"
else
  warn "ISO not found at $ISO_FILE"
  info "either download it:  pvesh create /nodes/$(hostname -s)/storage/local/download-url ... "
  info "or use cloud-init mode: provision/10-create-vm.sh NODE --mode cloudinit"
fi

hdr "next"
cat >&2 <<'NEXT'
  provision/01-space-check.sh          # re-confirm the no-overcommit math
  provision/10-create-vm.sh xah-node-1 # root disk only, no DB disk yet
NEXT
ok "host prep complete"
