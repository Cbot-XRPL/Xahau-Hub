#!/usr/bin/env bash
# provision/00-nvme-setup.sh — PHASE 1.5. Run on pve2 once the 4 TB NVMe is in.
#
# HARDWARE NOT YET PRESENT. Install the single-drive PCIe x4 adapter in slot
# 2, 3, 5 or 7 and leave the x16 slots (1, 4, 8) free for a future GPU. A
# single-drive adapter needs no bifurcation configuration.
#
# Creates: pvcreate -> vgcreate nvme-vg -> one LV per node at its new, larger
# cap, registers the VG with Proxmox as an LVM storage, and leaves the
# remainder UNALLOCATED for node 3 and for raising caps later.
#
# This does NOT migrate any data. Migration is one node at a time so the
# endpoint stays up — see ops/migrate-to-nvme.sh and docs/RUNBOOK.md.
#
# Usage: provision/00-nvme-setup.sh [--device /dev/nvmeXn1] [--dry-run] [--yes]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

DEV=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --device)  DEV="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes)     XAH_YES=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[ "$DRY" = 1 ] || guard_require_host
DEV="${DEV:-$("$INV" get nvme.device)}"
VG="$("$INV" get nvme.vg)"
SID="$("$INV" get nvme.pve_storage_id)"

hdr "phase 1.5 — NVMe setup"
printf '  %-16s %s\n' device "$DEV" vg "$VG" "pve storage" "$SID"

if [ "$DRY" = 0 ]; then
  need pvcreate; need vgcreate; need lvcreate; need pvesm

  [ -b "$DEV" ] || die "$DEV is not a block device. Is the card seated in slot 2/3/5/7 and does the BIOS see it? Check: lspci | grep -i nvme ; nvme list"

  # Refuse to wipe anything that already matters.
  if [ "$(lsblk -dnro TYPE "$DEV")" != disk ]; then die "$DEV is not a whole disk"; fi
  if [ -n "$(lsblk -no NAME "$DEV" | tail -n +2)" ]; then
    lsblk "$DEV" >&2
    die "$DEV already has partitions/children. Refusing to touch it. Inspect by hand."
  fi
  if blkid "$DEV" >/dev/null 2>&1; then
    die "$DEV already has a signature ($(blkid -o value -s TYPE "$DEV")). Refusing."
  fi
  if pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$DEV"; then
    warn "$DEV is already an LVM PV"
  fi
  if vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | grep -qx "$VG"; then
    ok "VG $VG already exists"
    VG_EXISTS=1
  else
    VG_EXISTS=0
  fi

  SIZE_TB="$(awk -v b="$(blockdev --getsize64 "$DEV")" 'BEGIN{printf "%.2f", b/1e12}')"
  EXPECT="$("$INV" get nvme.expected_size_tb)"
  info "$DEV reports ${SIZE_TB} TB (expected ~${EXPECT} TB)"
  awk -v s="$SIZE_TB" -v e="$EXPECT" 'BEGIN{exit !(s > e*0.85)}' \
    || die "$DEV is much smaller than expected — check you are pointing at the right device"

  # Sanity: this drive must be a DRAM-cache, high-endurance part. A QLC drive
  # without DRAM will not survive a NuDB write pattern.
  if command -v nvme >/dev/null 2>&1; then nvme list >&2 || true; fi
fi

hdr "planned layout"
"$INV" get nvme.volumes >/dev/null
python3 - "$REPO_ROOT/inventory.yml" <<'PY' >&2
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), 'lib'))
import inventory as I
d = I.load_yaml(sys.argv[1])
tot = 0
for v in d['nvme']['volumes']:
    print("  %-14s %6d GiB  -> %s" % (v['lv'], v['size_gib'], v['node']))
    tot += int(v['size_gib'])
cap = int(d['nvme']['expected_size_tb']) * 931
print("  %-14s %6d GiB  allocated" % ("", tot))
print("  %-14s %6d GiB  remainder, LEFT UNALLOCATED (node 3 + headroom)" % ("", cap - tot))
PY

if [ "$DRY" = 1 ]; then
  info "--dry-run: stopping here"
  exit 0
fi

confirm "pvcreate $DEV and create VG $VG — this DESTROYS anything on $DEV"

hdr "pvcreate / vgcreate"
pvcreate "$DEV"
if [ "$VG_EXISTS" = 0 ]; then vgcreate "$VG" "$DEV"; else vgextend "$VG" "$DEV"; fi
vgs "$VG"

hdr "lvcreate"
while IFS='|' read -r lv size node; do
  [ -z "$lv" ] && continue
  guard_reject_target "$node"
  if lvs --noheadings -o lv_name "$VG" 2>/dev/null | tr -d ' ' | grep -qx "$lv"; then
    ok "$lv already exists"
  else
    info "+ lvcreate -L ${size}G -n $lv $VG   (for $node)"
    lvcreate -L "${size}G" -n "$lv" "$VG"
  fi
done < <(python3 - "$REPO_ROOT/inventory.yml" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), 'lib'))
import inventory as I
for v in I.load_yaml(sys.argv[1])['nvme']['volumes']:
    print("%s|%s|%s" % (v['lv'], v['size_gib'], v['node']))
PY
)
lvs "$VG"

hdr "register with Proxmox"
if pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$SID"; then
  ok "storage '$SID' already registered"
else
  # LVM (thick) rather than a thin pool: caps are raised with lvextend +
  # xfs_growfs online, and thick volumes cannot overcommit by accident.
  pvesm add lvm "$SID" --vgname "$VG" --content images,rootdir --shared 0
  ok "registered pve storage '$SID' on VG $VG"
fi
pvesm status | head -1; pvesm status | grep -E "^($SID|local-lvm)" || true

hdr "next"
cat >&2 <<'NEXT'
  Free space is deliberately left in the VG. Raise a cap with:
      lvextend -L +200G nvme-vg/lv-xah1-db
      # then inside the guest, online, no downtime:
      xfs_growfs /var/lib/xahaud

  Migrate one node at a time so the endpoint stays up:
      ops/migrate-to-nvme.sh xah-node-1
  Then raise ledger_history now that disk is cheap, and record the new
  numbers in docs/DECISIONS.md.
NEXT
ok "NVMe setup complete"
