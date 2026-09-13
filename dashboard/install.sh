#!/usr/bin/env bash
# dashboard/install.sh — install the read-only monitoring dashboard INSIDE a node.
#
# It does NOT install onto the Proxmox host. pve2 is a shared hypervisor this
# repo does not own; a monitoring service is exactly the kind of thing that
# accretes packages, units and open ports on a box that should only run guests.
# So the dashboard is a systemd unit inside a node VM, and this script refuses
# any target that resolves to cluster.host.
#
# Pushes inventory.yml + lib/ + dashboard/ into the node's ops dir, writes the
# unit, starts it, and waits for /healthz. Idempotent: re-run after any change
# to the dashboard or to inventory.yml.
#
# Usage:
#   dashboard/install.sh [--node NAME]      # sync + (re)start
#   dashboard/install.sh --sync-only        # push files, do not touch the service
#   dashboard/install.sh --status           # is it up, what does /healthz say
#   dashboard/install.sh --uninstall        # stop, disable, remove the unit
#   dashboard/install.sh --enable-peer-probe
#       Mint a key on the dashboard node and authorise it on the other enabled
#       nodes so their cards read live instead of 'ssh probe failed'. This
#       widens node-to-node trust, so it is an explicit flag and never
#       automatic. The key is restricted by source address and stripped of
#       pty/forwarding, and it is separate from any key you use yourself.
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

MODE=install; NODE=""; PEERKEY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --node)      NODE="$2"; shift 2 ;;
    --enable-peer-probe) PEERKEY=1; shift ;;
    --sync-only) MODE=sync; shift ;;
    --status)    MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help)   sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$NODE" ] || NODE="$("$INV" get cluster.monitoring.node)"
[ -n "$NODE" ] || die "cluster.monitoring.node is not set in inventory.yml"
NODE="$(resolve_node "$NODE")"
node_env "$NODE"

BIND="$("$INV" get cluster.monitoring.bind)"
PORT="$("$INV" get cluster.monitoring.port)"
REFRESH="$("$INV" get cluster.monitoring.refresh_s)"
UNIT="$("$INV" get cluster.monitoring.service)"
HOST_ADDR="$("$INV" get cluster.host.address)"
HOST_NAME="$("$INV" get cluster.host.name)"

# ── containment: this must land in a VM, never on the hypervisor ─────────────
guard_reject_target "$NODE" "$N_ADDRESS"
[ "$N_ADDRESS" != "$HOST_ADDR" ] || die "GUARD: $NODE resolves to $N_ADDRESS, which is $HOST_NAME, the Proxmox host.
The dashboard runs inside a node VM. Refusing."
[ "$NODE" != "$HOST_NAME" ] || die "GUARD: refusing to install onto the Proxmox host ($HOST_NAME)."

URL="http://${N_ADDRESS}:${PORT}/"
UNIT_PATH="/etc/systemd/system/${UNIT}.service"

# ── status / uninstall short paths ───────────────────────────────────────────
if [ "$MODE" = status ]; then
  hdr "$UNIT on $NODE ($N_ADDRESS)"
  node_ssh "$NODE" "systemctl is-enabled $UNIT 2>/dev/null; systemctl is-active $UNIT 2>/dev/null; systemctl show $UNIT -p MainPID --value" || true
  echo
  info "healthz: $(curl -fsS --max-time 5 "http://${N_ADDRESS}:${PORT}/healthz" 2>/dev/null || echo 'no answer')"
  info "url:     $URL"
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  confirm "stop and remove $UNIT on $NODE?"
  node_ssh "$NODE" "systemctl disable --now $UNIT 2>/dev/null; rm -f $UNIT_PATH; systemctl daemon-reload; systemctl reset-failed $UNIT 2>/dev/null; echo removed"
  ok "$UNIT removed from $NODE. Files under $N_OPS_DIR were left in place."
  exit 0
fi

# ── sanity before touching anything ──────────────────────────────────────────
need python3
python3 -m py_compile "$REPO_ROOT/dashboard/xah-dashboard.py" >/dev/null \
  || die "dashboard/xah-dashboard.py does not compile — fix it before installing"
rm -rf "$REPO_ROOT/dashboard/__pycache__"
"$INV" check >/dev/null || die "inventory check failed — fix inventory.yml first"

hdr "installing the monitoring dashboard in $NODE ($N_ADDRESS)"
node_ssh "$NODE" true || die "cannot ssh to $NODE ($N_ADDRESS)"
node_ssh "$NODE" "command -v python3 >/dev/null" || die "$NODE has no python3 — the collector needs it"

# ── push ─────────────────────────────────────────────────────────────────────
info "syncing dashboard/, lib/ and inventory.yml -> ${NODE}:${N_OPS_DIR}"
node_ssh "$NODE" "mkdir -p '$N_OPS_DIR' && chmod 700 '$N_OPS_DIR'"
xrsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
  "$REPO_ROOT/dashboard" "$REPO_ROOT/lib" \
  "${N_SSH_USER}@${N_ADDRESS}:$N_OPS_DIR/" >/dev/null
xrsync -a "$REPO_ROOT/inventory.yml" "${N_SSH_USER}@${N_ADDRESS}:$N_OPS_DIR/inventory.yml" >/dev/null
node_ssh "$NODE" "chmod +x '$N_OPS_DIR/dashboard/xah-dashboard.py' '$N_OPS_DIR/lib/inventory.py'; chmod -R go-rwx '$N_OPS_DIR'"
ok "synced"

# The collector reads ITS OWN node locally and peers over ssh. Peer probing
# needs a key the node does not have yet — say so rather than silently
# generating one and quietly widening node-to-node trust.
PEERS="$("$INV" nodes --enabled | grep -vx "$NODE" || true)"
if [ -n "$PEERS" ]; then
  if [ "$PEERKEY" = 1 ]; then
    hdr "peer probe key"
    KEYFILE=/root/.ssh/xah-dashboard
    node_ssh "$NODE" "mkdir -p /root/.ssh && chmod 700 /root/.ssh
      [ -f $KEYFILE ] || ssh-keygen -q -t ed25519 -N '' -C 'xah-dashboard@$NODE' -f $KEYFILE
      grep -q 'IdentityFile $KEYFILE' /root/.ssh/config 2>/dev/null || {
        printf 'Host *\n  IdentityFile %s\n' $KEYFILE >> /root/.ssh/config
        chmod 600 /root/.ssh/config; }"
    PUB="$(node_ssh "$NODE" "cat ${KEYFILE}.pub")"
    [ -n "$PUB" ] || die "could not read the peer probe public key from $NODE"
    ok "key on $NODE: $(cut -d' ' -f3 <<< "$PUB")"

    while read -r peer; do
      [ -z "$peer" ] && continue
      paddr="$("$INV" node "$peer" address)"
      guard_reject_target "$peer" "$paddr"
      # Restricted: only from the dashboard node, no pty, no forwarding. The
      # probe is a heredoc script, so a forced command= would break it — the
      # real containment is that the collector only ever sends fixed probes.
      RESTRICT="from=\"${N_ADDRESS}\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty"
      node_ssh "$peer" "mkdir -p /root/.ssh && chmod 700 /root/.ssh
        touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
        grep -qF '$(cut -d' ' -f2 <<< "$PUB")' /root/.ssh/authorized_keys \
          || printf '%s %s\n' '$RESTRICT' '$PUB' >> /root/.ssh/authorized_keys"
      node_ssh "$NODE" "ssh-keyscan -T 4 -H '$paddr' >> /root/.ssh/known_hosts 2>/dev/null; sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts" || true
      if node_ssh "$NODE" "ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new root@$paddr true"; then
        ok "$NODE -> $peer: probe key works"
      else
        warn "$NODE -> $peer: key installed but the test connection failed"
      fi
    done <<< "$PEERS"
  elif node_ssh "$NODE" "ls /root/.ssh/xah-dashboard >/dev/null 2>&1"; then
    while read -r peer; do
      [ -z "$peer" ] && continue
      paddr="$("$INV" node "$peer" address)"
      guard_reject_target "$peer" "$paddr"
      node_ssh "$NODE" "ssh-keyscan -T 4 -H '$paddr' >> /root/.ssh/known_hosts 2>/dev/null; sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts" || true
    done <<< "$PEERS"
    ok "peer probe key already present; known_hosts refreshed"
  else
    warn "$NODE has no peer probe key, so peer cards ($(tr '\n' ' ' <<< "$PEERS")) will show"
    warn "'ssh probe failed'. Its own card is read locally and is unaffected."
    info "enable it deliberately with: dashboard/install.sh --node $NODE --enable-peer-probe"
  fi
fi

if [ "$MODE" = sync ]; then
  ok "files synced. Service not touched (--sync-only)."
  exit 0
fi

# ── unit ─────────────────────────────────────────────────────────────────────
info "writing $UNIT_PATH on $NODE"
node_ssh "$NODE" "cat > $UNIT_PATH" <<UNITEOF
[Unit]
Description=Xahau cluster monitoring dashboard (read-only)
Documentation=file://${N_OPS_DIR}/dashboard/xah-dashboard.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${N_OPS_DIR}
Environment=XAH_NODE=${NODE}
ExecStart=/usr/bin/python3 ${N_OPS_DIR}/dashboard/xah-dashboard.py \\
  --bind ${BIND} --port ${PORT} --refresh ${REFRESH} --node ${NODE}
Restart=always
RestartSec=5
# It only reads. Nothing it does should ever need to escalate or write.
NoNewPrivileges=yes
PrivateTmp=yes
# /usr and /etc read-only; /root readable so the peer ssh key still resolves,
# but not writable — known_hosts is pre-seeded at install time instead.
ProtectSystem=full
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
MemoryMax=256M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF

info "enabling and restarting $UNIT"
node_ssh "$NODE" "systemctl daemon-reload && systemctl enable $UNIT >/dev/null && systemctl restart $UNIT"

# ── verify ───────────────────────────────────────────────────────────────────
info "waiting for the first collection cycle"
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  body="$(curl -fsS --max-time 5 "http://${N_ADDRESS}:${PORT}/healthz" 2>/dev/null || true)"
  case "$body" in *'"ok": true'*|*'"ok":true'*) ok "dashboard is live at $URL"; exit 0 ;; esac
  sleep 3
done

err "the dashboard did not report healthy within 90s"
node_ssh "$NODE" "systemctl status $UNIT --no-pager -l | head -20; journalctl -u $UNIT -n 40 --no-pager" >&2 || true
exit 1
