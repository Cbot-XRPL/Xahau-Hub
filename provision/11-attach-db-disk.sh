#!/usr/bin/env bash
# provision/11-attach-db-disk.sh — hot-add the database disk AFTER the OS install.
#
#   qm set 110 --scsi1 local-lvm:700,iothread=1,discard=on
#
# Proxmox hot-plugs it and the guest sees /dev/sdb without a reboot. If it does
# not appear, force a rescan inside the guest:
#   echo "- - -" > /sys/class/scsi_host/host0/scan
#
# The disk's SIZE is the containment boundary. It sits on the same thin pool as
# the other VMs, and a runaway database there can exhaust the pool — LVM then
# suspends volumes rather than degrading gracefully. The filesystem cap is the
# enforcement mechanism: xahaud must hit ENOSPC on its own volume and stop.
#
# Usage: provision/11-attach-db-disk.sh NODE [--dry-run] [--format]
#   --format   also run mkfs.xfs + fstab inside the guest over ssh
#              (equivalently: run provision/20-guest-bootstrap.sh in the guest)
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODE=""; DRY=0; FORMAT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --format)  FORMAT=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE"
guard_reject_target "$NODE"
[ "$DRY" = 1 ] || guard_require_host
eval "$("$INV" node "$NODE")"
guard_vmid "$N_VMID"

hdr "$NODE — attach ${N_DB_GIB} GiB DB disk to vmid $N_VMID"

if [ "$DRY" = 0 ]; then
  qm status "$N_VMID" >/dev/null 2>&1 || die "vmid $N_VMID does not exist — run provision/10-create-vm.sh first"

  if qm config "$N_VMID" | grep -qE '^scsi1:'; then
    ok "scsi1 already attached: $(qm config "$N_VMID" | grep '^scsi1:')"
    ATTACHED=1
  else
    ATTACHED=0
  fi

  # Refuse to attach while the guest has never booted — that means the OS is
  # not installed yet and the installer could still swallow this disk.
  if [ "$ATTACHED" = 0 ]; then
    STATE="$(qm status "$N_VMID" | awk '{print $2}')"
    if [ "$STATE" != running ]; then
      warn "vmid $N_VMID is '$STATE'. This script is meant to run AFTER Ubuntu is installed,"
      warn "so the installer never sees the database disk and cannot pull it into the root LVM layout."
      confirm "Has Ubuntu already been installed on $NODE?"
    fi
    "$REPO_ROOT/provision/01-space-check.sh" >/dev/null \
      || die "space check failed — refusing to attach. Run provision/01-space-check.sh."
  fi
fi

# ── the actual attach ───────────────────────────────────────────────────────
CMD=( qm set "$N_VMID" --scsi1 "$N_DB_STORAGE:$N_DB_GIB,$N_DISK_OPTS" )
if [ "$DRY" = 1 ]; then
  printf '  %s\n' "${CMD[*]}"
elif [ "${ATTACHED:-0}" = 0 ]; then
  info "+ ${CMD[*]}"
  "${CMD[@]}"
  ok "attached $N_DB_STORAGE:$N_DB_GIB as scsi1 (hot-plugged, no reboot needed)"
fi

if [ "$DRY" = 0 ]; then
  hdr "verify"
  qm config "$N_VMID" | grep -E '^(scsi0|scsi1|memory|balloon|cpu|scsihw|onboot):' || true
  cat >&2 <<GUEST

  Inside the guest, /dev/sdb should now be present. If not:
      echo "- - -" > /sys/class/scsi_host/host0/scan

  Then (provision/20-guest-bootstrap.sh does all of this):
      mkfs.xfs -L $N_DB_LABEL /dev/sdb
      mkdir -p $N_DB_MOUNT
      echo 'LABEL=$N_DB_LABEL $N_DB_MOUNT xfs defaults,nofail 0 2' >> /etc/fstab
      mount -a

  XFS is mandatory: full history hits single-file size limits on other
  filesystems and converting later means a full resync.
  nofail is non-negotiable: a missing database disk must not wedge boot.
  Mount by LABEL=, never /dev/sdb — device ordering can change.
GUEST

  if [ "$FORMAT" = 1 ]; then
    hdr "formatting inside the guest over ssh"
    confirm "mkfs.xfs -L $N_DB_LABEL on ${NODE}'s second disk — this DESTROYS any data on it. Proceed?"
    node_ssh "$NODE" "XAH_YES=1 bash -s" <<REMOTE
set -Eeuo pipefail
echo "- - -" > /sys/class/scsi_host/host0/scan 2>/dev/null || true
sleep 2
dev=\$(lsblk -dnro NAME,SIZE,TYPE | awk '\$3=="disk" && \$1!="sda" {print "/dev/"\$1; exit}')
[ -n "\$dev" ] || { echo "no second disk found in guest" >&2; exit 1; }
if blkid "\$dev" >/dev/null 2>&1; then echo "\$dev already has a filesystem: \$(blkid -o value -s TYPE "\$dev"). Refusing." >&2; exit 1; fi
mkfs.xfs -L $N_DB_LABEL "\$dev"
mkdir -p $N_DB_MOUNT
grep -q 'LABEL=$N_DB_LABEL' /etc/fstab || echo 'LABEL=$N_DB_LABEL $N_DB_MOUNT xfs defaults,nofail 0 2' >> /etc/fstab
mount -a
df -h $N_DB_MOUNT
REMOTE
    ok "DB volume formatted and mounted on $NODE"
  fi
fi

hdr "next"
echo "  provision/20-guest-bootstrap.sh    # INSIDE the guest ($N_ADDRESS)" >&2
