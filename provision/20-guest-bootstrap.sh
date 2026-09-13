#!/usr/bin/env bash
# provision/20-guest-bootstrap.sh — run INSIDE a node VM, as root.
#
# Idempotent. Brings a fresh Ubuntu 24.04 guest to the point where xahaud can
# be started with a rendered config:
#
#   1. packages, sysctl, ulimits, timesync
#   2. the XFS database volume: mkfs (only if blank), LABEL=, fstab with nofail
#   3. the xahaud user and the directory layout
#   4. xahaud itself (official installer, pinnable)
#   5. a systemd drop-in that forces our config path and sane limits
#   6. logrotate for debug.log
#   7. ops/ tooling + the prune-guard / growth-watch / healthcheck crons
#
# It deliberately does NOT start xahaud. The SQLite page_size must be right at
# first start — with the 4096 default a history server can exhaust its
# transaction database while disk is still free, and the only fix is
# `xahaud --vacuum`, which can run for days. So: bootstrap, deploy the rendered
# config, then start. ops/deploy-node.sh does that in the right order.
#
# Usage (inside the guest):
#   provision/20-guest-bootstrap.sh [--node NAME] [--skip-xahaud] [--skip-mkfs]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODE=""; SKIP_XAHAUD=0; SKIP_MKFS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --node)         NODE="$2"; shift 2 ;;
    --skip-xahaud)  SKIP_XAHAUD=1; shift ;;
    --skip-mkfs)    SKIP_MKFS=1; shift ;;
    -h|--help)      sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root"
guard_require_guest

NODE="${NODE:-$(hostname -s)}"
guard_reject_target "$NODE"
eval "$("$INV" node "$NODE")"
ok "bootstrapping $N_NAME (role $N_ROLE, vmid $N_VMID)"

# ── 1. packages, kernel, limits ─────────────────────────────────────────────
hdr "1. packages and host tuning"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl wget jq xfsprogs rsync sqlite3 logrotate cron \
  chrony qemu-guest-agent bc python3 net-tools lsof >/dev/null
systemctl enable --now chrony qemu-guest-agent cron >/dev/null 2>&1 || true
ok "packages installed"

cat > /etc/sysctl.d/60-xahaud.conf <<'SYS'
# xahau-hub — tuning for a public history node
vm.swappiness = 1
vm.max_map_count = 262144
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 20
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 1048576
SYS
sysctl --system >/dev/null
cat > /etc/security/limits.d/60-xahaud.conf <<LIM
${N_XAHAUD_USER} soft nofile 65536
${N_XAHAUD_USER} hard nofile 262144
LIM
ok "sysctl + ulimits applied (swappiness=1: never swap a NuDB working set)"

# ── 2. the XFS database volume ───────────────────────────────────────────────
hdr "2. database volume — XFS, LABEL=$N_DB_LABEL, nofail"
ROOT_DEV="$(findmnt -no SOURCE / | sed 's/\[.*//')"
ROOT_DISK="/dev/$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null | head -1)"
info "root filesystem is on $ROOT_DEV (disk ${ROOT_DISK})"

DB_DEV=""
if blkid -L "$N_DB_LABEL" >/dev/null 2>&1; then
  DB_DEV="$(blkid -L "$N_DB_LABEL")"
  ok "existing volume labelled $N_DB_LABEL found at $DB_DEV"
else
  # pick the first whole disk that is not the root disk and has no children
  while read -r name type; do
    [ "$type" = disk ] || continue
    dev="/dev/$name"
    [ "$dev" = "$ROOT_DISK" ] && continue
    [ -n "$(lsblk -no NAME "$dev" | tail -n +2)" ] && continue
    DB_DEV="$dev"; break
  done < <(lsblk -dnro NAME,TYPE)
  [ -n "$DB_DEV" ] || die "no unused second disk found. Attach it from the host first:
  provision/11-attach-db-disk.sh $N_NAME
then force a rescan here:  echo \"- - -\" > /sys/class/scsi_host/host0/scan"

  SIZE_G=$(( $(blockdev --getsize64 "$DB_DEV") / 1024 / 1024 / 1024 ))
  info "candidate DB device: $DB_DEV (${SIZE_G} GiB, expected ~${N_DB_GIB} GiB)"
  if [ "$SIZE_G" -lt $(( N_DB_GIB * 9 / 10 )) ] || [ "$SIZE_G" -gt $(( N_DB_GIB * 11 / 10 )) ]; then
    warn "$DB_DEV is ${SIZE_G} GiB but inventory says ${N_DB_GIB} GiB for $N_NAME"
    confirm "Use $DB_DEV as the database volume anyway?"
  fi
  if existing="$(blkid -o value -s TYPE "$DB_DEV" 2>/dev/null)" && [ -n "$existing" ]; then
    die "$DB_DEV already holds a '$existing' filesystem. Refusing to mkfs over it. Inspect it by hand."
  fi
  if [ "$SKIP_MKFS" = 1 ]; then
    die "--skip-mkfs given but $DB_DEV has no filesystem — nothing to mount"
  fi
  confirm "mkfs.xfs -L $N_DB_LABEL $DB_DEV (destroys anything on it)"
  # XFS is mandatory: full history hits single-file size limits elsewhere and
  # converting later means a full resync.
  mkfs.xfs -L "$N_DB_LABEL" "$DB_DEV"
  ok "mkfs.xfs done on $DB_DEV"
fi

mkdir -p "$N_DB_MOUNT"
# nofail is non-negotiable: a missing database disk must not wedge boot.
# LABEL= rather than /dev/sdb: device ordering changes when disks are added.
FSTAB_LINE="LABEL=$N_DB_LABEL $N_DB_MOUNT xfs defaults,nofail 0 2"
if grep -qE "^[^#]*LABEL=$N_DB_LABEL[[:space:]]" /etc/fstab; then
  sed -i -E "s|^[^#]*LABEL=$N_DB_LABEL[[:space:]].*|$FSTAB_LINE|" /etc/fstab
else
  printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
fi
grep -q 'nofail' <<<"$FSTAB_LINE" || die "refusing: fstab entry lacks nofail"
mountpoint -q "$N_DB_MOUNT" || mount -a
mountpoint -q "$N_DB_MOUNT" || die "$N_DB_MOUNT did not mount"
findmnt -no FSTYPE "$N_DB_MOUNT" | grep -qx xfs || die "$N_DB_MOUNT is not XFS. XFS is mandatory on database volumes."
ok "$N_DB_MOUNT mounted: $(findmnt -no SOURCE,FSTYPE,SIZE,AVAIL "$N_DB_MOUNT" | tr -s ' ')"

# ── 3. user and layout ──────────────────────────────────────────────────────
hdr "3. user and directory layout"
id -u "$N_XAHAUD_USER" >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --home-dir "$N_XAHAUD_PREFIX" "$N_XAHAUD_USER"
mkdir -p "$N_DB_MOUNT/db/nudb" "$N_XAHAUD_LOG_DIR" "$N_XAHAUD_CFG_DIR" "$N_XAHAUD_PREFIX/bin" "$N_XAHAUD_PREFIX/etc"
chown -R "$N_XAHAUD_USER:$N_XAHAUD_USER" "$N_DB_MOUNT" "$N_XAHAUD_LOG_DIR"
chmod 750 "$N_DB_MOUNT" "$N_XAHAUD_LOG_DIR"
# The config dir must be TRAVERSABLE by the xahaud user or it cannot read its
# own config — it fails with "Permission denied", falls back to compiled-in
# defaults, and tries to create a database next to the config. root owns the
# directory so the daemon cannot rewrite its own config; the xahaud group gets
# r-x so it can reach the file inside.
chown root:"$N_XAHAUD_USER" "$N_XAHAUD_CFG_DIR"
chmod 750 "$N_XAHAUD_CFG_DIR"
ok "layout: db=$N_DB_MOUNT/db  logs=$N_XAHAUD_LOG_DIR  cfg=$N_XAHAUD_CFG"

# ── 4. xahaud ───────────────────────────────────────────────────────────────
hdr "4. xahaud"
if [ "$SKIP_XAHAUD" = 1 ]; then
  warn "--skip-xahaud: not installing the binary"
elif [ -x "$N_XAHAUD_BIN" ]; then
  ok "already installed: $("$N_XAHAUD_BIN" --version 2>/dev/null | head -1 || echo "$N_XAHAUD_BIN")"
else
  INSTALLER="${XAHAUD_INSTALLER_URL:-$N_INSTALLER_URL}"
  info "fetching installer: $INSTALLER"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  if curl -fsSL --max-time 60 -o "$TMP/install.sh" "$INSTALLER"; then
    EXPECT_SHA="${XAHAUD_INSTALLER_SHA256:-${N_INSTALLER_SHA256:-}}"
    if [ -n "$EXPECT_SHA" ]; then
      GOT_SHA="$(sha256sum "$TMP/install.sh" | awk '{print $1}')"
      if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
        err "installer checksum mismatch — refusing to run it"
        err "  expected $EXPECT_SHA"
        err "  got      $GOT_SHA"
        die "Either the installer was updated upstream (re-verify it by hand, then update cluster.defaults.installer_sha256 in inventory.yml) or something is wrong. Do not run an unverified installer as root."
      fi
      ok "installer checksum verified ($GOT_SHA)"
    else
      warn "no pinned checksum — running an unpinned installer from the network as root."
      warn "Set cluster.defaults.installer_sha256 in inventory.yml. See docs/DECISIONS.md."
    fi
    sed -n '1,3p' "$TMP/install.sh" >&2
    confirm "Run the xahaud installer?"
    bash "$TMP/install.sh" || die "xahaud installer failed. Install the binary by hand to $N_XAHAUD_BIN and re-run with --skip-xahaud."
  else
    die "could not download the installer. Install xahaud by hand to $N_XAHAUD_BIN (see docs/RUNBOOK.md) and re-run with --skip-xahaud."
  fi
  [ -x "$N_XAHAUD_BIN" ] || die "$N_XAHAUD_BIN is still missing after install — the installer layout may have changed. Check docs/RUNBOOK.md."
  ok "installed $("$N_XAHAUD_BIN" --version 2>/dev/null | head -1 || true)"
fi

# ── one config, not two ─────────────────────────────────────────────────────
# The installer writes a real default config at $prefix/etc/xahaud.cfg (admin
# on port 5009, peers_max 20) and points its ExecStart at it. The repo owns
# $N_XAHAUD_CFG. Leaving both in place means two configs and a coin-flip over
# which one is live, so the installer's copy is backed up once and replaced
# with a symlink. Whichever path anything uses, it reads the repo's config.
INST_CFG="${N_XAHAUD_INSTALLER_CFG:-$N_XAHAUD_PREFIX/etc/xahaud.cfg}"
mkdir -p "$(dirname "$INST_CFG")"
if [ -L "$INST_CFG" ]; then
  ln -sfn "$N_XAHAUD_CFG" "$INST_CFG"
  ok "$INST_CFG -> $N_XAHAUD_CFG"
elif [ -f "$INST_CFG" ]; then
  cp -a "$INST_CFG" "${INST_CFG}.installer-default.bak"
  ln -sfn "$N_XAHAUD_CFG" "$INST_CFG"
  ok "replaced the installer's default config with a symlink -> $N_XAHAUD_CFG"
  info "its original is kept at ${INST_CFG}.installer-default.bak"
else
  ln -sfn "$N_XAHAUD_CFG" "$INST_CFG"
  ok "$INST_CFG -> $N_XAHAUD_CFG"
fi
# Re-running the installer to update the binary will NOT clobber this: it only
# writes a default when the config file is absent, and a symlink satisfies -f.

# ── 5. systemd drop-in ──────────────────────────────────────────────────────
hdr "5. systemd"
if systemctl list-unit-files | grep -q "^${N_XAHAUD_SERVICE}.service"; then
  mkdir -p "/etc/systemd/system/${N_XAHAUD_SERVICE}.service.d"
  cat > "/etc/systemd/system/${N_XAHAUD_SERVICE}.service.d/10-xahau-hub.conf" <<UNIT
# Managed by xahau-hub / provision/20-guest-bootstrap.sh. Do not hand-edit.
[Service]
ExecStart=
ExecStart=${N_XAHAUD_BIN} --silent --conf ${N_XAHAUD_CFG}
User=${N_XAHAUD_USER}
Group=${N_XAHAUD_USER}
LimitNOFILE=262144
Restart=on-failure
RestartSec=10
# A stop can take a while: NuDB flushes on shutdown and killing it mid-flush
# is how databases get corrupted.
TimeoutStopSec=600
KillSignal=SIGTERM
OOMPolicy=continue
ReadWritePaths=${N_DB_MOUNT} ${N_XAHAUD_LOG_DIR}
UNIT
  systemctl daemon-reload
  ok "drop-in installed: ExecStart pinned to --conf $N_XAHAUD_CFG, TimeoutStopSec=600"
else
  warn "no ${N_XAHAUD_SERVICE}.service found — the installer may not have created one."
  warn "Create it before starting. See docs/RUNBOOK.md."
fi

# The installer ships an auto-update timer. Binary updates are fine; a config
# rewrite is not. Flag it so it is a known quantity, not a surprise.
if systemctl list-timers --all 2>/dev/null | grep -qi xahau; then
  warn "an xahau auto-update timer is active. Binary updates are fine, but verify it never rewrites $N_XAHAUD_CFG."
  systemctl list-timers --all | grep -i xahau >&2 || true
fi

# ── 6. logrotate ────────────────────────────────────────────────────────────
hdr "6. logrotate"
cat > /etc/logrotate.d/xahaud <<ROT
${N_XAHAUD_LOG_DIR}/debug.log {
    daily
    rotate 7
    maxsize 512M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su ${N_XAHAUD_USER} ${N_XAHAUD_USER}
}
ROT
ok "debug.log rotates daily / 512M / 7 kept (copytruncate: xahaud keeps its fd)"

# ── 7. ops tooling and crons ────────────────────────────────────────────────
hdr "7. ops tooling and crons"
mkdir -p "$N_OPS_DIR"
if [ "$(readlink -f "$REPO_ROOT")" != "$(readlink -f "$N_OPS_DIR")" ]; then
  for d in lib ops config; do
    mkdir -p "$N_OPS_DIR/$d"; cp -a "$REPO_ROOT/$d/." "$N_OPS_DIR/$d/"
  done
  install -m 644 "$REPO_ROOT/inventory.yml" "$N_OPS_DIR/inventory.yml"
  rm -rf "$N_OPS_DIR/out" "$N_OPS_DIR/secrets"
fi
chmod -R go-rwx "$N_OPS_DIR"
mkdir -p "$N_OPS_DIR/.state"

CRONF=/etc/cron.d/xahau-hub
cat > "$CRONF" <<CRON
# xahau-hub — managed by provision/20-guest-bootstrap.sh. Do not hand-edit.
#
# prune-guard : fires can_delete when the DB volume crosses ${N_PRUNE_TRIGGER_PCT}%.
#               advisory_delete=1 means NOTHING prunes until this runs.
# growth-watch: df + du + alerting.
# healthcheck : server_info, complete_ledgers, peers.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
XAH_REPO_ROOT=$N_OPS_DIR
$N_PRUNE_INTERVAL root $N_OPS_DIR/ops/prune-guard.sh >>/var/log/xahau-prune.log 2>&1
$N_GROWTH_INTERVAL root $N_OPS_DIR/ops/growth-watch.sh --mode guest >>/var/log/xahau-growth.log 2>&1
$N_HEALTH_INTERVAL root $N_OPS_DIR/ops/healthcheck.sh --local --quiet >>/var/log/xahau-health.log 2>&1
CRON
chmod 644 "$CRONF"
for f in prune growth health; do : > "/var/log/xahau-$f.log"; chmod 640 "/var/log/xahau-$f.log"; done
ok "installed $CRONF (prune '$N_PRUNE_INTERVAL', growth '$N_GROWTH_INTERVAL', health '$N_HEALTH_INTERVAL')"

# ── done ────────────────────────────────────────────────────────────────────
hdr "bootstrap complete — xahaud is NOT started"
cat >&2 <<NEXT
  The config must be in place BEFORE the first start: SQLite page_size
  (${N_SQLITE_PAGE_SIZE}) only takes effect on a fresh database, and fixing it later
  means \`xahaud --vacuum\`, which can run for days on a history server.

  From your workstation:
      make render NODE=$N_NAME
      make deploy NODE=$N_NAME        # installs $N_XAHAUD_CFG then starts

  Or by hand, here:
      install -o $N_XAHAUD_USER -g $N_XAHAUD_USER -m 600 xahaud.cfg $N_XAHAUD_CFG
      install -m 644 validators.txt $N_XAHAUD_CFG_DIR/validators.txt
      systemctl enable --now $N_XAHAUD_SERVICE
NEXT
