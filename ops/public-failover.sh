#!/usr/bin/env bash
# ops/public-failover.sh — point the public node's nginx at a peer, or back.
#
# The public endpoint terminates at the api node's nginx (ports 15007/16006),
# which proxies to its own xahaud. Any maintenance that stops that xahaud
# (vacuum, upgrade) would be a public outage - unless nginx is first pointed
# at the other node's public ports, which it reaches on the LAN. nginx reloads
# are zero-downtime, so the switch and the restore are invisible to clients.
#
# First used by hand for the 2026-10-02 vacuum of xah-node-2; this is that
# procedure as a tool, with the config backed up and the health check built in.
#
# Usage: ops/public-failover.sh NODE --to PEER      # serve PEER's xahaud
#        ops/public-failover.sh NODE --restore      # back to localhost
#        ops/public-failover.sh NODE --status
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODE=""; PEER=""; MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to)      PEER="$2"; MODE=to; shift 2 ;;
    --restore) MODE=restore; shift ;;
    --status)  MODE=status; shift ;;
    -*)        die "unknown flag: $1" ;;
    *)         NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] && [ -n "$MODE" ] || die "usage: $0 NODE --to PEER | --restore | --status"
guard_reject_target "$NODE"
"$INV" node "$NODE" address >/dev/null 2>&1 || die "unknown node: $NODE"
if [ -n "$PEER" ]; then
  guard_reject_target "$PEER"
  "$INV" node "$PEER" address >/dev/null 2>&1 || die "unknown peer: $PEER"
fi
CONF=/etc/nginx/conf.d/xahaud-edge.conf
BAK=/root/xahaud-edge.conf.pre-failover
remote() { node_ssh "$NODE" "$@"; }

check() {   # the public path on NODE answers, and says whose xahaud it is
  remote "curl -s --max-time 10 --data '{\"method\":\"server_info\",\"params\":[{}]}' http://127.0.0.1:15007/ \
    | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"result\"][\"info\"];print(\"public path OK: state=\"+d.get(\"server_state\",\"?\")+\" build=\"+d.get(\"build_version\",\"?\")+\" pubkey=\"+d.get(\"pubkey_node\",\"?\")[:12])'" \
    || die "public path through $NODE:15007 is NOT answering — fix before leaving it like this"
}

case "$MODE" in
  status)
    remote "grep -nE 'proxy_pass' $CONF"; check ;;
  to)
    ADDR="$("$INV" node "$PEER" address)"
    guard_reject_target "$PEER" "$ADDR"
    [ "$PEER" != "$NODE" ] || die "cannot fail over to itself"
    hdr "$NODE nginx -> $PEER ($ADDR)"
    remote "[ -f $BAK ] || cp $CONF $BAK"
    remote "sed -i 's#proxy_pass http://127.0.0.1:5007;#proxy_pass http://$ADDR:5007;#; s#proxy_pass http://127.0.0.1:6006;#proxy_pass http://$ADDR:6006;#' $CONF"
    remote "nginx -t 2>&1 | tail -1 && systemctl reload nginx"
    sleep 2; check
    ok "$NODE now serves the public endpoint from $PEER" ;;
  restore)
    hdr "$NODE nginx -> localhost"
    remote "if [ -f $BAK ]; then cp $BAK $CONF; else sed -i -E 's#proxy_pass http://[0-9.]+:5007;#proxy_pass http://127.0.0.1:5007;#; s#proxy_pass http://[0-9.]+:6006;#proxy_pass http://127.0.0.1:6006;#' $CONF; fi"
    remote "nginx -t 2>&1 | tail -1 && systemctl reload nginx"
    sleep 2; check
    remote "rm -f $BAK"
    ok "$NODE serves its own xahaud again" ;;
esac
