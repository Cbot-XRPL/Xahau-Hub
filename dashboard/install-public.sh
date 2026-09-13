#!/usr/bin/env bash
# dashboard/install-public.sh — install the PUBLIC status + API docs page.
#
# Separate from install.sh on purpose. That installs the ops dashboard, which
# shows internal addresses, VM ids and disk state and must stay on the LAN.
# This installs the public-facing page, which can only ever show what the
# public RPC already tells any caller.
#
# It is NOT placed in front of the API. cluster.cbotlabs.xyz goes straight to
# xahaud; putting a python shim in that path would add a hop and a failure mode
# to the thing people actually depend on, to save them one click.
#
# Usage: dashboard/install-public.sh [--node NAME] [--status] [--uninstall]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

MODE=install; NODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --status) MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

NODE="$(resolve_node "${NODE:-$("$INV" get cluster.monitoring.node)}")"
node_env "$NODE"
UNIT="xah-public-info"
PORT="$("$INV" get cluster.monitoring.public_port)"
PUB_RPC="https://$("$INV" get cluster.proxy.public_hostname_rpc)"
PUB_WS="wss://$("$INV" get cluster.proxy.public_hostname_ws)"

HOST_ADDR="$("$INV" get cluster.host.address)"
HOST_NAME="$("$INV" get cluster.host.name)"
guard_reject_target "$NODE" "$N_ADDRESS"
[ "$N_ADDRESS" != "$HOST_ADDR" ] || die "GUARD: $NODE resolves to the Proxmox host. Refusing."
[ "$NODE" != "$HOST_NAME" ] || die "GUARD: refusing to install onto the Proxmox host."

if [ "$MODE" = status ]; then
  hdr "$UNIT on $NODE"
  node_ssh "$NODE" "systemctl is-enabled $UNIT 2>/dev/null; systemctl is-active $UNIT 2>/dev/null" || true
  info "healthz: $(curl -fsS --max-time 5 "http://${N_ADDRESS}:${PORT}/healthz" 2>/dev/null || echo 'no answer')"
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  confirm "remove $UNIT from $NODE?"
  node_ssh "$NODE" "systemctl disable --now $UNIT 2>/dev/null; rm -f /etc/systemd/system/${UNIT}.service; systemctl daemon-reload; echo removed"
  ok "$UNIT removed"; exit 0
fi

need python3
python3 -m py_compile "$REPO_ROOT/dashboard/public-info.py" >/dev/null \
  || die "public-info.py does not compile"
rm -rf "$REPO_ROOT/dashboard/__pycache__"

hdr "installing the public info page on $NODE"
info "it polls the public RPC of every enabled node; it reads no inventory and ssh's nowhere"

node_ssh "$NODE" "mkdir -p $N_OPS_DIR/dashboard"
xscp "$REPO_ROOT/dashboard/public-info.py" "${N_SSH_USER}@${N_ADDRESS}:$N_OPS_DIR/dashboard/public-info.py" >/dev/null
node_ssh "$NODE" "chmod +x $N_OPS_DIR/dashboard/public-info.py"

# one --rpc per enabled node, labelled by role so the page reads sensibly
RPCARGS=""
while read -r n; do
  [ -z "$n" ] && continue
  a="$("$INV" node "$n" address)"; r="$("$INV" node "$n" role)"
  guard_reject_target "$n" "$a"
  RPCARGS="$RPCARGS --rpc '${n} (${r})=http://${a}:${N_RPC_PUBLIC}'"
done < <("$INV" nodes --enabled)

node_ssh "$NODE" "cat > /etc/systemd/system/${UNIT}.service" <<UNITEOF
[Unit]
Description=Xahau public status + API documentation page
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $N_OPS_DIR/dashboard/public-info.py --bind 0.0.0.0 --port ${PORT} ${RPCARGS} --public-rpc ${PUB_RPC} --public-ws ${PUB_WS}
Restart=always
RestartSec=5
# It answers GET/HEAD and polls an HTTP endpoint. It needs nothing else.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
MemoryMax=128M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF

node_ssh "$NODE" "systemctl daemon-reload && systemctl enable --now $UNIT && systemctl restart $UNIT"
ok "$UNIT started on $NODE:${PORT}"

info "waiting for the first poll"
for i in $(seq 1 20); do
  if curl -fsS --max-time 4 "http://${N_ADDRESS}:${PORT}/healthz" >/dev/null 2>&1; then
    ok "live at http://${N_ADDRESS}:${PORT}/"; break
  fi
  sleep 3
  [ "$i" = 20 ] && { node_ssh "$NODE" "journalctl -u $UNIT -n 20 --no-pager" >&2 || true; die "did not come up"; }
done

hdr "next — route it publicly"
cat >&2 <<NEXT
  On the tunnel host (the NPM LXC):
      cd ~/cloudflare-tunnel
      bash tunnel-host.sh add status.cbotlabs.xyz http://${N_ADDRESS}:${PORT}

  Then the CNAME by hand in Cloudflare (cloudflared cannot write this zone):
      Type CNAME   Name status.cbotlabs.xyz   Target <TUNNEL_ID>.cfargotunnel.com   Proxied
NEXT
