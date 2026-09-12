#!/usr/bin/env bash
# ops/migrate-to-nvme.sh — PHASE 1.5. Move one node's DB volume to the NVMe.
#
# ONE NODE AT A TIME so the public endpoint stays up throughout. The other
# node keeps serving while this one is down.
#
# Two strategies:
#   --method move-disk  (default) stop xahaud, stop the VM, `qm move-disk`,
#                       start, grow the filesystem. Proxmox copies the block
#                       device; nothing inside the guest changes except size.
#   --method rsync      stop xahaud, attach the new LV as a third disk, mkfs
#                       XFS with the same label pattern, rsync, swap labels,
#                       remount. Keeps the old copy until you drop it, which
#                       is the safer option the first time.
#
# Afterwards the RAID 10 goes back to holding only OS disks, and the cap can
# rise from the NVMe's unallocated remainder: lvextend + xfs_growfs, online.
#
# Usage: ops/migrate-to-nvme.sh NODE [--method move-disk|rsync] [--grow GiB] [--dry-run]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

NODE=""; METHOD=move-disk; GROW=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --method) METHOD="$2"; shift 2 ;;
    --grow)   GROW="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE [--method move-disk|rsync]"
NODE="$(resolve_node "$NODE")"; node_env "$NODE"
guard_vmid "$N_VMID"
SID="$("$INV" get nvme.pve_storage_id)"
VG="$("$INV" get nvme.vg)"

LV="$(python3 - "$REPO_ROOT/inventory.yml" "$NODE" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), 'lib'))
import inventory as I
for v in I.load_yaml(sys.argv[1])['nvme']['volumes']:
    if v['node'] == sys.argv[2]:
        print(v['lv']); break
PY
)"
[ -n "$LV" ] || die "$NODE has no nvme volume declared in inventory.yml under nvme.volumes"
NEW_GIB="$(python3 - "$REPO_ROOT/inventory.yml" "$NODE" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), 'lib'))
import inventory as I
for v in I.load_yaml(sys.argv[1])['nvme']['volumes']:
    if v['node'] == sys.argv[2]:
        print(v['size_gib']); break
PY
)"

hdr "migrate $NODE to NVMe"
printf '  %-18s %s\n' node "$NODE ($N_ROLE, vmid $N_VMID)"
printf '  %-18s %s GiB on %s\n' "current db" "$N_DB_GIB" "$N_DB_STORAGE"
printf '  %-18s %s GiB as %s/%s\n' "target" "${GROW:-$NEW_GIB}" "$VG" "$LV"
printf '  %-18s %s\n' method "$METHOD"

# ── the other nodes must be healthy before this one goes down ───────────────
hdr "pre-flight: is the endpoint covered while $NODE is down?"
OTHERS=0; HEALTHY=0
while read -r m; do
  [ "$m" = "$NODE" ] && continue
  OTHERS=$(( OTHERS + 1 ))
  st="$(rpc_field "$(node_info "$m" 2>/dev/null || echo '{}')" info.server_state 2>/dev/null || echo unreachable)"
  printf '  %-14s %s\n' "$m" "$st"
  case "$st" in full|proposing|validating) HEALTHY=$(( HEALTHY + 1 )) ;; esac
done < <("$INV" nodes --enabled)
if [ "$OTHERS" -gt 0 ] && [ "$HEALTHY" = 0 ]; then
  warn "no other node is currently serving. Taking $NODE down means the endpoint goes dark."
  confirm "Continue anyway?"
fi

[ "$DRY" = 1 ] && { info "--dry-run: stopping here"; exit 0; }
confirm "Stop xahaud on $NODE and migrate its database volume?"

hdr "1. stop xahaud (NuDB flushes on shutdown — be patient)"
node_ssh "$NODE" "systemctl stop $N_XAHAUD_SERVICE"
node_ssh "$NODE" "systemctl is-active --quiet $N_XAHAUD_SERVICE" \
  && die "$N_XAHAUD_SERVICE is still running on $NODE — refusing to move a live database"
ok "xahaud stopped"

if [ "$METHOD" = move-disk ]; then
  hdr "2. qm move-disk (guest powered off)"
  node_ssh "$NODE" "shutdown -h now" || true
  info "waiting for vmid $N_VMID to stop"
  for i in $(seq 1 60); do
    st="$(host_ssh "qm status $N_VMID" | awk '{print $2}')"
    [ "$st" = stopped ] && break
    sleep 5
    [ "$i" = 60 ] && { host_ssh "qm stop $N_VMID"; sleep 5; }
  done
  ok "vmid $N_VMID stopped"

  # Proxmox copies scsi1 to the new storage and, with --delete 0, keeps the
  # original as an unused disk. Keep it until the node is verified good.
  host_ssh "qm move-disk $N_VMID scsi1 $SID --delete 0" \
    || die "move-disk failed. The original volume is untouched — start the VM and investigate."
  ok "scsi1 now lives on $SID; the old volume is retained as an unused disk"

  host_ssh "qm start $N_VMID"
  info "waiting for ssh on $NODE"
  for i in $(seq 1 60); do node_ssh "$NODE" true 2>/dev/null && break; sleep 5; done
  node_ssh "$NODE" true || die "$NODE did not come back. Console: qm terminal $N_VMID"

else
  hdr "2. rsync onto a freshly attached LV"
  host_ssh "qm set $N_VMID --scsi2 $SID:${GROW:-$NEW_GIB},$N_DISK_OPTS"
  ok "attached $SID:${GROW:-$NEW_GIB} as scsi2 (hot-plugged)"
  node_ssh "$NODE" "XAH_YES=1 bash -s" <<REMOTE
set -Eeuo pipefail
echo "- - -" > /sys/class/scsi_host/host0/scan 2>/dev/null || true
sleep 3
new=\$(lsblk -dnro NAME,TYPE | awk '\$2=="disk"{print "/dev/"\$1}' | while read -r d; do
  [ -n "\$(lsblk -no NAME "\$d" | tail -n +2)" ] && continue
  blkid "\$d" >/dev/null 2>&1 && continue
  echo "\$d"; break
done)
[ -n "\$new" ] || { echo "no blank disk found for the new volume" >&2; exit 1; }
echo "new volume: \$new"
mkfs.xfs -L ${N_DB_LABEL}new "\$new"
mkdir -p /mnt/xahdb-new
mount LABEL=${N_DB_LABEL}new /mnt/xahdb-new
rsync -aHAX --info=progress2 --exclude 'wallet.db' $N_DB_MOUNT/ /mnt/xahdb-new/
umount /mnt/xahdb-new
umount $N_DB_MOUNT
# swap the labels so fstab (LABEL=$N_DB_LABEL) picks up the new volume
old=\$(blkid -L $N_DB_LABEL); xfs_admin -L ${N_DB_LABEL}old "\$old"
new_dev=\$(blkid -L ${N_DB_LABEL}new); xfs_admin -L $N_DB_LABEL "\$new_dev"
mount -a
findmnt -no SOURCE,SIZE,FSTYPE $N_DB_MOUNT
chown -R $N_XAHAUD_USER:$N_XAHAUD_USER $N_DB_MOUNT
REMOTE
  ok "data copied; $N_DB_MOUNT now uses the NVMe volume (old one kept, labelled ${N_DB_LABEL}old)"
fi

hdr "3. grow the filesystem"
if [ -n "$GROW" ]; then
  host_ssh "lvextend -L ${GROW}G $VG/$LV" || warn "lvextend reported an error (already that size?)"
fi
node_ssh "$NODE" "xfs_growfs $N_DB_MOUNT && df -h $N_DB_MOUNT"
ok "filesystem grown online, no downtime needed for this step"

hdr "4. start and verify"
node_ssh "$NODE" "systemctl start $N_XAHAUD_SERVICE"
for i in $(seq 1 60); do
  si="$(node_info "$NODE" || true)"
  if [ -n "$si" ]; then
    ok "$NODE: server_state=$(rpc_field "$si" info.server_state) complete_ledgers=$(rpc_field "$si" info.complete_ledgers)"
    break
  fi
  sleep 5
done
"$REPO_ROOT/ops/healthcheck.sh" "$NODE" || true

cat >&2 <<NEXT

  Next, in order:
    1. Watch it for a few hours. ops/growth-watch.sh --mode guest
    2. Only then drop the old volume:
         move-disk:  qm set $N_VMID --delete unused0
         rsync:      wipefs the ${N_DB_LABEL}old volume, then detach scsi1
    3. Raise the cap now that disk is cheap:
         lvextend -L +200G $VG/$LV   &&   xfs_growfs $N_DB_MOUNT   (online)
       then raise ledger_history in config/roles/$N_ROLE.yml, keeping
       online_delete above it, re-render and restart.
    4. Record the new numbers in docs/DECISIONS.md.
  Then migrate the next node. Never two at once.
NEXT
