#!/usr/bin/env bash
# provision/05-host-check.sh — READ-ONLY preflight on pve2. Changes nothing.
#
# This script used to "prep" the host: it edited /etc/lvm/lvm.conf, installed a
# copy of the ops tooling to /opt/xahau-hub, and dropped a cron job in
# /etc/cron.d. That was wrong. pve2 is a shared hypervisor that also runs the
# ai-hub builder VM; a node-provisioning repo does not get to install resident
# agents on it or rewrite host-global LVM policy as a side effect of `make`.
#
# So: this repo is CONTAINED TO ITS OWN VMs. On the host it only ever reads,
# and only for as long as one command takes (see ops/host-run.sh). Everything
# that needs to run on a schedule — growth-watch, prune-guard, healthcheck —
# runs from cron INSIDE each node, installed by provision/20-guest-bootstrap.sh.
#
# What this checks, all read-only:
#   1. thin pool autoextend policy in lvm.conf, and prints the exact edit to
#      make BY HAND if it is not what inventory.yml expects
#   2. the no-overcommit math against the live pool (delegates to 01)
#   3. install media availability
#   4. that no previous run left xahau-hub residue on the host
#
# Usage: provision/05-host-check.sh [--no-space]
#        ops/host-run.sh provision/05-host-check.sh      # from a workstation
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
[ "${1:-}" = "-h" ] && { sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

guard_require_host
need lvs; need qm

THRESH="$("$INV" get cluster.thresholds.lvm_autoextend_threshold)"
PCT="$("$INV" get cluster.thresholds.lvm_autoextend_percent)"
WARN=0

hdr "1. lvm.conf thin pool autoextend (read-only)"
CONF=/etc/lvm/lvm.conf
[ -f "$CONF" ] || die "$CONF not found"

report_lvm() {
  local key="$1" want="$2" line got
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONF" | head -1 || true)"
  if [ -z "$line" ]; then
    got="(unset — LVM built-in default applies)"
  else
    got="$(printf '%s' "$line" | tr -s ' \t' ' ' | sed 's/^ //')"
  fi
  printf '  %-38s %s\n' "$key" "$got"
  if [ -n "$line" ] && printf '%s' "$line" | grep -qE "=[[:space:]]*${want}[[:space:]]*$"; then
    return 0
  fi
  WARN=1
  printf '    want: %s = %s\n' "$key" "$want"
  return 1
}
report_lvm thin_pool_autoextend_threshold "$THRESH" || true
report_lvm thin_pool_autoextend_percent   "$PCT"   || true

lvm dumpconfig activation 2>/dev/null | grep -E 'thin_pool_autoextend' | sed 's/^/  effective: /' || true

if [ "$WARN" = 1 ]; then
  warn "lvm.conf does not match inventory.yml's intent. This script will NOT edit it."
  cat >&2 <<EDIT

  If you want that policy, edit it yourself — it is host-global and affects
  every guest on $(hostname -s), not just this cluster's nodes:

      cp -a $CONF ${CONF}.bak.\$(date -u +%Y%m%d%H%M%S)
      \$EDITOR $CONF        # in the activation { } block:
                            #   thin_pool_autoextend_threshold = $THRESH
                            #   thin_pool_autoextend_percent   = $PCT

  percent=$PCT means: do NOT autoextend, alert only. This host does not
  overcommit, so growing the pool is a deliberate decision with the math
  redone — never an automatic one. Leaving lvm.conf at its distro default is
  also a valid choice: it changes nothing about whether the nodes fit, which
  is what check 2 actually proves.
EDIT
else
  ok "autoextend policy matches inventory.yml (threshold $THRESH, percent $PCT)"
fi

hdr "2. no-overcommit math against the live pool"
if [ "${1:-}" = "--no-space" ]; then
  warn "--no-space: skipping"
else
  "$REPO_ROOT/provision/01-space-check.sh" || die "the allocation math does not clear — do not create nodes yet"
fi

hdr "3. install media"
ISO="$("$INV" get cluster.defaults.iso)"
ISO_FILE="/var/lib/vz/template/iso/${ISO##*/}"
CLOUDIMG="$("$INV" get cluster.defaults.cloudimg_url)"
if [ -f "$ISO_FILE" ]; then
  ok "ISO present: $ISO_FILE"
else
  info "no ISO at $ISO_FILE — not needed for cloud-init mode"
fi
found=0
for f in /var/lib/vz/template/iso/"${CLOUDIMG##*/}" /var/lib/vz/template/cache/"${CLOUDIMG##*/}"; do
  [ -f "$f" ] && { ok "cloud image present: $f"; found=1; }
done
[ "$found" = 1 ] || info "cloud image not cached; 10-create-vm.sh --mode cloudinit downloads it to a temp path"

hdr "4. containment — no xahau-hub residue on this host"
RESIDUE=0
for p in /opt/xahau-hub /root/.xahau-hub /etc/cron.d/xahau-hub-growth \
         /etc/cron.d/xahau-hub /etc/systemd/system/xah-dashboard.service; do
  if [ -e "$p" ]; then
    err "residue: $p"
    RESIDUE=1
  fi
done
if [ "$RESIDUE" = 1 ]; then
  cat >&2 <<'RESID'

  Those paths are left over from the old host-resident design. Nothing in this
  repo needs them any more. Remove them:

      rm -rf /opt/xahau-hub /root/.xahau-hub
      rm -f  /etc/cron.d/xahau-hub-growth /etc/cron.d/xahau-hub
      systemctl disable --now xah-dashboard 2>/dev/null
      rm -f  /etc/systemd/system/xah-dashboard.service && systemctl daemon-reload

  The dashboard now runs inside a node VM (dashboard/install.sh), and the
  growth/prune/health crons run inside each node.
RESID
else
  ok "clean: this repo holds no persistent footprint on $(hostname -s)"
fi

hdr "next"
cat >&2 <<'NEXT'
  This script changed nothing. Provisioning continues with:
      make create-vm  NODE=xah-node-1   # root disk only, no DB disk yet
      make attach-db  NODE=xah-node-1
      make bootstrap  NODE=xah-node-1   # runs INSIDE the guest
NEXT
[ "$WARN" = 1 ] && warn "preflight passed with advisories (see check 1)" || ok "host preflight clean"
exit 0
