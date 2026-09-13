#!/usr/bin/env bash
# dashboard/install.sh — install the read-only monitoring dashboard IN A VM.
#
# It does NOT install on the Proxmox host, and refuses to if asked. The host
# runs guests; it does not accrete python services, systemd units and open
# ports. The target comes from cluster.monitoring.host in inventory.yml and
# defaults to ai-hub (VM 100), the ops box — which is also not something the
# dashboard is responsible for watching.
#
# Pushes inventory.yml + lib/ + dashboard/ to the target's ops dir, writes a
# systemd unit, starts it, and waits for /healthz. Idempotent: re-run it after
# any change to the dashboard or to inventory.yml.
#
# The dashboard is READ ONLY. It answers GET, runs fixed probe commands, and
# routes every ssh through lib/guard.sh's forbidden-target list, so it can
# never reach the UNL validator host.
#
# Usage:
#   dashboard/install.sh                 # sync + (re)start
#   dashboard/install.sh --sync-only     # push files, do not touch the service
#   dashboard/install.sh --status        # is it up, what does /healthz say
#   dashboard/install.sh --uninstall     # stop, disable, remove the unit
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
usage_if_help "${1:-}"

MODE=install
case "${1:-}" in
  --sync-only) MODE=sync ;;
  --status)    MODE=status ;;
  --uninstall) MODE=uninstall ;;
  "")          : ;;
  *)           die "unknown argument: $1 (try --help)" ;;
esac

TGT_NAME="$("$INV" get cluster.monitoring.host)"
TGT_ADDR="$("$INV" get cluster.monitoring.host_address)"
TGT_USER="$("$INV" get cluster.monitoring.host_user)"
OPS_DIR="$("$INV" get cluster.defaults.ops_dir)"
BIND="$("$INV" get cluster.monitoring.bind)"
PORT="$("$INV" get cluster.monitoring.port)"
REFRESH="$("$INV" get cluster.monitoring.refresh_s)"
UNIT="$("$INV" get cluster.monitoring.service)"

PVE_NAME="$("$INV" get cluster.host.name)"
PVE_ADDR="$("$INV" get cluster.host.address)"

guard_reject_target "$TGT_NAME" "$TGT_ADDR"

# ── the dashboard does not live on the Proxmox host ──────────────────────────
#  Encoded here rather than left to discipline, because "just this once, on the
#  host" is how a hypervisor ends up with a python service, a pip cache and an
#  open port that nobody remembers adding.
if [ "$TGT_NAME" = "$PVE_NAME" ] || [ "$TGT_ADDR" = "$PVE_ADDR" ]; then
  die "REFUSING: cluster.monitoring.host is '$TGT_NAME' ($TGT_ADDR), which is the Proxmox host.
The dashboard runs in a VM. Point cluster.monitoring.host at a guest — ai-hub (VM 100) is the intended one.
The host runs guests; it does not run monitoring services."
fi

TARGET="${TGT_USER}@${TGT_ADDR}"

# ── local or remote? ─────────────────────────────────────────────────────────
#  If the target is this machine, skip ssh entirely and install in place.
LOCAL=0
if [ "$(hostname -s)" = "$TGT_NAME" ] || ip -4 -o addr show 2>/dev/null | grep -qw "$TGT_ADDR"; then
  LOCAL=1
fi

# systemd needs root. When installing locally as a non-root user, escalate only
# for the unit itself — the file sync stays unprivileged.
SUDO=""
if [ "$LOCAL" = 1 ] && [ "$(id -u)" != 0 ]; then
  SUDO="sudo"
  if ! sudo -n true 2>/dev/null; then
    warn "installing a systemd unit on $TGT_NAME needs root, and sudo will prompt for a password."
    warn "If this is running unattended it will fail here — run it from a terminal, or pre-authorise with 'sudo -v'."
  fi
fi

# tssh/trsync — talk to the target, locally or over ssh, without caring which.
tssh()  { if [ "$LOCAL" = 1 ]; then bash -c "$1"; else xssh "$TARGET" "$1"; fi; }
tsudo() { if [ "$LOCAL" = 1 ]; then $SUDO bash -c "$1"; else xssh "$TARGET" "$1"; fi; }
URL="http://${TGT_ADDR}:${PORT}/"

# ── status / uninstall short paths ───────────────────────────────────────────
if [ "$MODE" = status ]; then
  hdr "$UNIT on $TGT_NAME"
  xssh "$TARGET" "systemctl is-enabled $UNIT 2>/dev/null; systemctl is-active $UNIT 2>/dev/null; systemctl show $UNIT -p MainPID --value" || true
  echo
  info "healthz: $(curl -fsS --max-time 5 "http://${TGT_ADDR}:${PORT}/healthz" 2>/dev/null || echo 'no answer')"
  info "url:     $URL"
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  confirm "stop and remove $UNIT on $TGT_NAME?"
  tsudo "systemctl disable --now $UNIT 2>/dev/null; rm -f /etc/systemd/system/${UNIT}.service; systemctl daemon-reload; echo removed"
  ok "$UNIT removed from $TGT_NAME. Files under $OPS_DIR were left in place."
  exit 0
fi

# ── sanity before touching the host ──────────────────────────────────────────
need python3
python3 -m py_compile "$REPO_ROOT/dashboard/xah-dashboard.py" >/dev/null \
  || die "dashboard/xah-dashboard.py does not compile — fix it before installing"
rm -rf "$REPO_ROOT/dashboard/__pycache__"
"$INV" check >/dev/null || die "inventory check failed — fix inventory.yml first"

hdr "installing the monitoring dashboard on $TGT_NAME ($TGT_ADDR)$( [ "$LOCAL" = 1 ] && echo ' — local install' )"
info "the Proxmox host ($PVE_NAME) is NOT touched; the collector reaches it read-only over ssh"

# ── push ─────────────────────────────────────────────────────────────────────
info "syncing inventory.yml, lib/ and dashboard/ to ${TGT_NAME}:${OPS_DIR}"
if [ "$LOCAL" = 1 ]; then
  $SUDO mkdir -p "$OPS_DIR"
  $SUDO rsync -a --delete "$REPO_ROOT/dashboard" "$REPO_ROOT/lib" "$OPS_DIR/"
  $SUDO install -m 644 "$REPO_ROOT/inventory.yml" "$OPS_DIR/inventory.yml"
  $SUDO chmod +x "$OPS_DIR/dashboard/xah-dashboard.py" "$OPS_DIR/lib/inventory.py"
else
  xssh "$TARGET" "mkdir -p '$OPS_DIR'"
  if command -v rsync >/dev/null 2>&1 && xssh "$TARGET" "command -v rsync >/dev/null 2>&1"; then
    xrsync -a --delete "$REPO_ROOT/dashboard" "$REPO_ROOT/lib" "${TARGET}:${OPS_DIR}/"
    xrsync -a "$REPO_ROOT/inventory.yml" "${TARGET}:${OPS_DIR}/inventory.yml"
  else
    warn "rsync unavailable on one end — falling back to tar over ssh"
    tar -C "$REPO_ROOT" -cf - dashboard lib inventory.yml | xssh "$TARGET" "tar -C '$OPS_DIR' -xf -"
  fi
  xssh "$TARGET" "chmod +x '$OPS_DIR/dashboard/xah-dashboard.py' '$OPS_DIR/lib/inventory.py'"
fi

# The collector ssh's into the nodes. Pre-seed the host's known_hosts so the
# very first probe after a fresh install is not the one that has to learn the
# key — a service with no tty cannot answer a prompt.
while read -r node; do
  [ -z "$node" ] && continue
  addr="$("$INV" node "$node" address)"
  guard_reject_target "$node" "$addr"
  KH="$( [ "$LOCAL" = 1 ] && echo "$HOME/.ssh/known_hosts" || echo /root/.ssh/known_hosts )"
  tssh "mkdir -p \"$(dirname "$KH")\"; ssh-keyscan -T 4 -H '$addr' >> '$KH' 2>/dev/null; sort -u -o '$KH' '$KH'" || true
done < <("$INV" nodes --enabled)

if [ "$MODE" = sync ]; then
  ok "files synced. Service not touched (--sync-only)."
  exit 0
fi

# ── unit ─────────────────────────────────────────────────────────────────────
info "writing /etc/systemd/system/${UNIT}.service"
UNIT_TMP="$(mktemp)"
cat > "$UNIT_TMP" <<UNITEOF
[Unit]
Description=Xahau cluster monitoring dashboard (read-only)
Documentation=file://${OPS_DIR}/dashboard/xah-dashboard.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${OPS_DIR}
ExecStart=/usr/bin/python3 ${OPS_DIR}/dashboard/xah-dashboard.py --bind ${BIND} --port ${PORT} --refresh ${REFRESH}
Restart=always
RestartSec=5
# It only reads. Nothing it does should ever need to escalate or write.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
MemoryMax=256M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF

if [ "$LOCAL" = 1 ]; then
  $SUDO install -m 644 "$UNIT_TMP" "/etc/systemd/system/${UNIT}.service"
else
  xssh "$TARGET" "cat > /etc/systemd/system/${UNIT}.service" < "$UNIT_TMP"
fi
rm -f "$UNIT_TMP"

info "enabling and starting $UNIT"
tsudo "systemctl daemon-reload && systemctl enable --now $UNIT && systemctl restart $UNIT"

# ── verify ───────────────────────────────────────────────────────────────────
info "waiting for the first collection cycle"
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  body="$(curl -fsS --max-time 5 "http://${TGT_ADDR}:${PORT}/healthz" 2>/dev/null || true)"
  case "$body" in *'"ok": true'*|*'"ok":true'*) ok "dashboard is live at $URL"; exit 0 ;; esac
  sleep 3
done

err "the dashboard did not report healthy within 90s"
xssh "$TARGET" "systemctl status $UNIT --no-pager -l | head -30; journalctl -u $UNIT -n 40 --no-pager" || true
exit 1
