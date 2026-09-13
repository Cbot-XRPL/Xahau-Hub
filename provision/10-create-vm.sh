#!/usr/bin/env bash
# provision/10-create-vm.sh — create a node VM on pve2 with its ROOT DISK ONLY.
#
# The database disk is deliberately NOT attached here. If the Ubuntu installer
# can see it, it can pull it into the root LVM layout or offer to partition it,
# and unwinding that after the fact is miserable. Attach it afterwards with
# provision/11-attach-db-disk.sh, which hot-plugs it into the running guest.
#
# Usage:
#   provision/10-create-vm.sh NODE [--mode iso|cloudinit] [--start] [--dry-run]
#
#   --mode iso        (default) attach the Ubuntu 24.04 ISO and install by hand
#   --mode cloudinit  import the Ubuntu cloud image, static IP from inventory,
#                     ssh key from --sshkey / ~/.ssh/authorized_keys
#   --sshkey FILE     public key(s) for cloud-init (default root's authorized_keys)
#   --start           start the VM after creating it
#   --dry-run         print the qm commands and exit
#
# Applied from inventory.yml: --cpu host (kvm64 hides AES/SHA/AVX and signature
# verification takes a real hit), --balloon 0 (xahaud does not tolerate memory
# being reclaimed out from under it), virtio-scsi-single, iothread, discard,
# onboot.
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODE=""; MODE=iso; START=0; DRY=0; SSHKEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="$2"; shift 2 ;;
    --sshkey)  SSHKEY="$2"; shift 2 ;;
    --start)   START=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE [--mode iso|cloudinit]"
case "$MODE" in iso|cloudinit) : ;; *) die "--mode must be iso or cloudinit" ;; esac

guard_reject_target "$NODE"
[ "$DRY" = 1 ] || guard_require_host
[ "$DRY" = 1 ] || { need qm; need pvesm; }

eval "$("$INV" node "$NODE")"
guard_vmid "$N_VMID"

PHASE_NOW="$("$INV" get cluster.phase)"
if [ "$N_ENABLED" != "1" ]; then
  warn "$NODE is enabled: false in inventory.yml (declared phase $N_PHASE, cluster is phase $PHASE_NOW)"
  confirm "Create $NODE anyway?"
fi
if [ "$N_PHASE" -gt "$PHASE_NOW" ] 2>/dev/null; then
  warn "$NODE is a phase $N_PHASE node and the cluster is at phase $PHASE_NOW."
  warn "Phase 2 needs the 384 GB RAM upgrade AND the NVMe. See docs/PHASE-2.md."
  confirm "Continue?"
fi

hdr "$NODE — vmid $N_VMID, role $N_ROLE"
printf '  %-14s %s\n' vcpu "$N_VCPU" \
                      ram  "$N_RAM_MB MiB (balloon 0)" \
                      root "$N_ROOT_GIB GiB on $N_STORAGE" \
                      db   "$N_DB_GIB GiB on $N_DB_STORAGE — NOT attached by this script" \
                      net  "$N_ADDRESS/$N_NETMASK_CIDR via $N_GATEWAY on $N_BRIDGE" \
                      mode "$MODE"

run() {
  if [ "$DRY" = 1 ]; then printf '  %s\n' "$*"; else
    info "+ $*"; "$@"; fi
}

if [ "$DRY" = 0 ]; then
  if qm status "$N_VMID" >/dev/null 2>&1; then
    die "VMID $N_VMID already exists on $(hostname -s). Refusing to clobber it. Destroy it deliberately first, or pick a different vmid in inventory.yml."
  fi
  hdr "pre-flight"
  "$REPO_ROOT/provision/01-space-check.sh" >/dev/null \
    || die "space check failed — refusing to provision. Run provision/01-space-check.sh for detail."
  ok "space check passed (no overcommit, reserve intact)"
  "$REPO_ROOT/provision/02-net-check.sh" "$NODE" >/dev/null \
    || die "network check failed — refusing to provision. Run provision/02-net-check.sh for detail.
A VM built on a wrong gateway boots, answers ssh on the LAN, and has no internet — which looks like apt hanging, not like a network problem."
  ok "network check passed (gateway answers, address free, endpoints reachable)"
fi

# ── create: root disk only ──────────────────────────────────────────────────
hdr "qm create (root disk only)"
CREATE=( qm create "$N_VMID"
  --name "$NODE"
  --description "xahau-hub $N_ROLE node ($NODE). Managed by the Xahau-Hub repo — do not hand-edit. inventory.yml is the source of truth."
  --ostype "$N_OSTYPE"
  --cpu "$N_CPU"
  --cores "$N_VCPU"
  --sockets 1
  --numa 1
  --memory "$N_RAM_MB"
  --balloon "$N_BALLOON"
  --scsihw "$N_SCSIHW"
  --net0 "virtio,bridge=$N_BRIDGE"
  --onboot "$N_ONBOOT"
  --agent enabled=1
  --tags "xahau-hub,$N_ROLE,phase$N_PHASE"
)
run "${CREATE[@]}"

if [ "$MODE" = cloudinit ]; then
  IMG="/var/lib/vz/template/cache/$(basename "$N_CLOUDIMG_URL")"
  if [ "$DRY" = 0 ] && [ ! -f "$IMG" ]; then
    info "downloading $N_CLOUDIMG_URL"
    mkdir -p "$(dirname "$IMG")"
    curl -fL --progress-bar -o "$IMG.part" "$N_CLOUDIMG_URL" && mv "$IMG.part" "$IMG"
  fi
  [ "$DRY" = 1 ] || [ -f "$IMG" ] || die "cloud image missing: $IMG"

  # `qm importdisk` is the legacy spelling of `qm disk import`; prefer the
  # modern one and fall back, so this keeps working across PVE versions.
  IMPORT=(qm disk import "$N_VMID" "$IMG" "$N_STORAGE")
  if [ "$DRY" = 0 ] && ! qm help disk >/dev/null 2>&1; then
    IMPORT=(qm importdisk "$N_VMID" "$IMG" "$N_STORAGE")
  fi
  if [ "$DRY" = 1 ]; then
    printf '  %s\n' "${IMPORT[*]}"
    VOL="$N_STORAGE:vm-$N_VMID-disk-0"
  else
    info "+ ${IMPORT[*]}"
    IMPORT_OUT="$("${IMPORT[@]}" 2>&1 | tee /dev/stderr)"
    # Read the volume id back from the config rather than assuming disk-0 —
    # the numbering depends on what the VM already has.
    VOL="$(qm config "$N_VMID" | awk -F'[:,]' '/^unused[0-9]+:/{print $2":"$3; exit}' | tr -d ' ')"
    [ -n "$VOL" ] || VOL="$(grep -oE "'[^']*vm-$N_VMID-disk-[0-9]+'" <<<"$IMPORT_OUT" | tr -d "'" | tail -1)"
    [ -n "$VOL" ] || die "could not determine the imported volume id. Check: qm config $N_VMID"
    ok "imported as $VOL"
  fi

  run qm set "$N_VMID" --scsi0 "$VOL,$N_DISK_OPTS"
  run qm resize "$N_VMID" scsi0 "${N_ROOT_GIB}G"
  run qm set "$N_VMID" --ide2 "$N_STORAGE:cloudinit" --boot order=scsi0
  # Cloud images expect a serial console; keep the graphical one as well so
  # the noVNC console in the UI still works if something needs eyeballing.
  run qm set "$N_VMID" --serial0 socket
  run qm set "$N_VMID" --ipconfig0 "ip=$N_ADDRESS/$N_NETMASK_CIDR,gw=$N_GATEWAY" \
                       --nameserver "$N_NAMESERVERS" --ciuser root
  # cloud-init sets the guest hostname from the VM name, which inventory
  # guarantees is the node name — the ops scripts resolve themselves from it.
  # Public keys travel with the staged repo (ops/host-run.sh puts them at
  # $REPO_ROOT/guest-keys.pub), so the host needs no permanent copy of its own.
  KEYS="${SSHKEY:-}"
  if [ -z "$KEYS" ]; then
    for cand in "$REPO_ROOT/guest-keys.pub" "$REPO_ROOT/secrets/guest-keys.pub" \
                /root/.ssh/authorized_keys; do
      [ -f "$cand" ] && { KEYS="$cand"; break; }
    done
  fi
  if [ -f "$KEYS" ]; then
    run qm set "$N_VMID" --sshkeys "$KEYS"
    ok "injected $(grep -c . "$KEYS" 2>/dev/null || echo '?') ssh key(s) from $KEYS"
  else
    die "no ssh key file found. A cloud image has no password login — the VM would be unreachable. Pass --sshkey FILE."
  fi
else
  run qm set "$N_VMID" --scsi0 "$N_STORAGE:$N_ROOT_GIB,$N_DISK_OPTS"
  run qm set "$N_VMID" --ide2 "$N_ISO,media=cdrom" --boot "order=ide2;scsi0"
fi

# ── assert the DB disk was NOT attached ─────────────────────────────────────
if [ "$DRY" = 0 ]; then
  if qm config "$N_VMID" | grep -qE '^scsi1:'; then
    die "scsi1 exists on $N_VMID already — the installer must not see the DB disk. Remove it before installing Ubuntu."
  fi
  ok "scsi1 is absent: the Ubuntu installer cannot touch the database volume"
  [ "$START" = 1 ] && run qm start "$N_VMID"
fi

hdr "next"
cat >&2 <<NEXT
  1. Install Ubuntu 24.04 LTS on scsi0 (${N_ROOT_GIB} GiB). Static $N_ADDRESS/$N_NETMASK_CIDR,
     gateway $N_GATEWAY. Install qemu-guest-agent and your ssh key.
     (cloud-init mode: it is already configured — just \`qm start $N_VMID\`.)
  2. provision/11-attach-db-disk.sh $NODE      # hot-adds the ${N_DB_GIB} GiB DB disk
  3. provision/20-guest-bootstrap.sh           # run INSIDE the guest
NEXT
ok "$NODE created (vmid $N_VMID), root disk only"
