#!/usr/bin/env bash
# ops/install-ratelimit.sh — put nginx in front of xahaud, on the node itself.
#
# xahaud does not rate limit a public endpoint. Measured on this cluster: 150
# requests at ~146 req/s, all 200, load_factor never moved. One caller can
# saturate it. This adds the limit that actually holds.
#
# It runs ON the node rather than as a separate box so there is no extra
# network hop, and it is nginx rather than something bespoke because this is
# precisely what nginx is for.
#
# ZERO DOWNTIME: nginx listens on NEW ports. xahaud keeps serving 5007/6006
# throughout. Nothing changes for callers until you point the tunnel at the new
# ports, and pointing it back is the rollback.
#
# Usage: ops/install-ratelimit.sh NODE [--status] [--uninstall] [--test]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODE=""; MODE=install
while [ $# -gt 0 ]; do
  case "$1" in
    --status) MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --test) MODE=test; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE"
NODE="$(resolve_node "$NODE")"
node_env "$NODE"
guard_reject_target "$NODE" "$N_ADDRESS"

CONF=/etc/nginx/conf.d/xahaud-edge.conf

if [ "$MODE" = status ]; then
  hdr "$NODE edge"
  node_ssh "$NODE" "systemctl is-enabled nginx 2>/dev/null; systemctl is-active nginx 2>/dev/null; ss -lntp 2>/dev/null | grep -E ':($N_EDGE_RPC_PORT|$N_EDGE_WS_PORT)' || echo '  edge ports not listening'"
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  confirm "remove the edge rate limiter from $NODE? (point the tunnel back at $N_RPC_PUBLIC/$N_WS_PUBLIC FIRST)"
  node_ssh "$NODE" "rm -f $CONF && nginx -t && systemctl reload nginx && echo removed"
  ok "edge removed from $NODE"
  exit 0
fi

if [ "$MODE" = test ]; then
  hdr "does the limit actually fire?"
  addr="$N_ADDRESS"; port="$N_EDGE_RPC_PORT"
  info "60 requests as one simulated client (CF-Connecting-IP: 203.0.113.9)"
  limited=0; okc=0
  for _ in $(seq 1 60); do
    c="$(curl -so /dev/null -w '%{http_code}' --max-time 5 \
        -H 'content-type: application/json' -H 'CF-Connecting-IP: 203.0.113.9' \
        --data '{"method":"ping","params":[{}]}' "http://${addr}:${port}/" 2>/dev/null || echo 000)"
    case "$c" in 200) okc=$((okc+1)) ;; 429) limited=$((limited+1)) ;; esac
  done
  printf '  200: %s   429: %s\n' "$okc" "$limited"
  [ "$limited" -gt 0 ] && ok "the limit fires" || warn "nothing was limited — burst may be larger than this test"

  info "a DIFFERENT client should be unaffected"
  c="$(curl -so /dev/null -w '%{http_code}' --max-time 5 \
      -H 'content-type: application/json' -H 'CF-Connecting-IP: 198.51.100.4' \
      --data '{"method":"ping","params":[{}]}' "http://${addr}:${port}/" 2>/dev/null || echo 000)"
  [ "$c" = 200 ] && ok "second client got 200 — limiting is per client, not global" \
                 || err "second client got $c — the limit is global, which is not what we want"
  exit 0
fi

# ── install ─────────────────────────────────────────────────────────────────
hdr "installing the edge rate limiter on $NODE"

node_ssh "$NODE" "command -v nginx >/dev/null 2>&1" || {
  info "installing nginx"
  node_ssh "$NODE" "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null"
}
node_ssh "$NODE" "nginx -v" 2>&1 | sed 's/^/  /'

# nginx ships a default site on :80 that we neither want nor use.
node_ssh "$NODE" "rm -f /etc/nginx/sites-enabled/default"

hdr "rendering config"
TMP="$(mktemp)"
"$REPO_ROOT/lib/render.py" "$REPO_ROOT/config/xahaud-edge.conf.j2" \
  "node_name=$NODE" \
  "rendered_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  "proxy_address=$("$INV" get cluster.proxy.address)" \
  "edge_rpc_port=$N_EDGE_RPC_PORT" \
  "edge_ws_port=$N_EDGE_WS_PORT" \
  "rpc_public_port=$N_RPC_PUBLIC" \
  "ws_public_port=$N_WS_PUBLIC" \
  "rpc_rate=$N_EDGE_RPC_RATE" \
  "rpc_burst=$N_EDGE_RPC_BURST" \
  "rpc_conn=$N_EDGE_RPC_CONN" \
  "ws_conn=$N_EDGE_WS_CONN" \
  "zone_size=$N_EDGE_ZONE_SIZE" \
  "max_body=$N_EDGE_MAX_BODY" \
  "read_timeout=$N_EDGE_READ_TIMEOUT" \
  "ws_timeout=$N_EDGE_WS_TIMEOUT" > "$TMP"
ok "rendered ($(wc -l < "$TMP") lines)"

xscp "$TMP" "${N_SSH_USER}@${N_ADDRESS}:$CONF" >/dev/null
rm -f "$TMP"

hdr "validating before reload"
node_ssh "$NODE" "nginx -t" 2>&1 | sed 's/^/  /' \
  || { node_ssh "$NODE" "rm -f $CONF"; die "nginx rejected the config — removed it, nginx untouched"; }

node_ssh "$NODE" "systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx || systemctl restart nginx"
ok "nginx reloaded"

hdr "verify"
node_ssh "$NODE" "ss -lntp 2>/dev/null | grep -E ':($N_EDGE_RPC_PORT|$N_EDGE_WS_PORT)'" | sed 's/^/  /' \
  || die "edge ports are not listening"

code="$(curl -so /dev/null -w '%{http_code}' --max-time 8 -H 'content-type: application/json' \
        --data '{"method":"ping","params":[{}]}' "http://${N_ADDRESS}:${N_EDGE_RPC_PORT}/" 2>/dev/null || echo 000)"
[ "$code" = 200 ] && ok "RPC through the edge: HTTP $code" || die "RPC through the edge returned $code"

hdr "next"
cat >&2 <<NEXT
  xahaud is still serving $N_RPC_PUBLIC/$N_WS_PUBLIC directly; nothing has changed
  for callers yet. Point the tunnel at the limited ports:

      cd ~/cloudflare-tunnel
      \$EDITOR hosts.txt     # change the two cluster lines to:
        cluster.cbotlabs.xyz     http://${N_ADDRESS}:${N_EDGE_RPC_PORT}
        ws-cluster.cbotlabs.xyz  http://${N_ADDRESS}:${N_EDGE_WS_PORT}
      bash tunnel-host.sh apply

  Rollback is the same edit in reverse.
  Check it works:  ops/install-ratelimit.sh $NODE --test
NEXT
