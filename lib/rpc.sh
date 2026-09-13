# shellcheck shell=bash
# lib/rpc.sh — talk to xahaud. Source, do not execute.
#
# Admin RPC is 127.0.0.1 only, so admin calls must originate on the node
# itself (locally, or wrapped in node_ssh). Public RPC can be called from
# anywhere the port is reachable.

[ -n "${_XAH_RPC_SOURCED:-}" ] && return 0
_XAH_RPC_SOURCED=1

: "${REPO_ROOT:?rpc.sh needs REPO_ROOT}"

# rpc_local COMMAND [JSON-PARAMS] — admin RPC over 127.0.0.1. Run ON the node.
rpc_local() {
  local cmd="${1:?rpc_local needs a command}"; shift
  local params="${1:-{\}}"
  local port="${XAH_ADMIN_PORT:-$("$INV" get cluster.ports.rpc_admin)}"
  local body
  body="$(printf '{"method":"%s","params":[%s]}' "$cmd" "$params")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time "${XAH_RPC_TIMEOUT:-25}" \
      -H 'content-type: application/json' \
      --data "$body" "http://127.0.0.1:${port}/" 2>/dev/null && return 0
  fi
  # Fallback: the binary's own RPC client. Same endpoint, same admin rights.
  local bin cfg
  bin="$("$INV" get cluster.defaults.xahaud_bin)"
  cfg="$("$INV" get cluster.defaults.xahaud_cfg)"
  [ -x "$bin" ] || return 1
  "$bin" --silent --conf "$cfg" "$cmd" 2>/dev/null
}

# rpc_public NODE COMMAND [JSON-PARAMS] — public RPC over the network.
rpc_public() {
  local node="${1:?rpc_public needs a node}" cmd="${2:?rpc_public needs a command}"
  local params="${3:-{\}}"
  guard_reject_target "$node"
  local addr port
  addr="$("$INV" node "$node" address)"
  port="$("$INV" get cluster.ports.rpc_public)"
  guard_reject_target "$addr"
  curl -fsS --max-time "${XAH_RPC_TIMEOUT:-25}" \
    -H 'content-type: application/json' \
    --data "$(printf '{"method":"%s","params":[%s]}' "$cmd" "$params")" \
    "http://${addr}:${port}/" 2>/dev/null
}

# rpc_field JSON dotted.path — read a value out of an RPC reply.
rpc_field() {
  local json="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -re ".result.${path} // empty" 2>/dev/null
  else
    python3 -c '
import json,sys
try: d=json.load(sys.stdin).get("result",{})
except Exception: sys.exit(1)
for p in sys.argv[1].split("."):
    if isinstance(d,list):
        try: d=d[int(p)]
        except Exception: sys.exit(1)
    elif isinstance(d,dict):
        if p not in d: sys.exit(1)
        d=d[p]
    else: sys.exit(1)
print(d if not isinstance(d,(dict,list)) else json.dumps(d))
' "$path" <<<"$json" 2>/dev/null
  fi
}

# rpc_ok JSON — true when the reply carries result.status == success
rpc_ok() { [ "$(rpc_field "$1" status 2>/dev/null || true)" = success ]; }

# server_info convenience. Uses admin locally, public remotely.
server_info_local()  { rpc_local server_info; }
server_info_public() { rpc_public "$1" server_info; }

# complete_ledgers -> "LOW HIGH" (empty when the node reports none/"empty")
# parse_complete_ledgers "LOW-HIGH" -> "LOW HIGH", or nothing.
# Returns 0 even when there is no range. "empty" is a NORMAL state for a node
# that is still syncing, and returning non-zero made the ERR trap in callers
# print "unexpected failure at ...", which reads like a crash rather than a
# node that simply has no ledgers yet. Callers test for an empty result.
parse_complete_ledgers() {
  local cl="${1:-}"
  cl="${cl##*,}"                       # last range if several
  case "$cl" in
    *-*) printf '%s %s' "${cl%%-*}" "${cl##*-}" ;;
    *)   : ;;
  esac
  return 0
}

# node_pubkey NODE — the node's pubkey_node, the identity [cluster_nodes] uses.
# Admin RPC is localhost-only, so this goes over ssh and asks the node itself.
# Falls back to public RPC, which also reports pubkey_node.
node_pubkey() {
  local node="${1:?node_pubkey needs a node}" port json
  guard_reject_target "$node"
  port="$("$INV" get cluster.ports.rpc_admin)"
  json="$(node_ssh "$node" "curl -fsS --max-time 15 -H 'content-type: application/json' --data '{\"method\":\"server_info\",\"params\":[{}]}' http://127.0.0.1:${port}/" 2>/dev/null || true)"
  [ -z "$json" ] && json="$(rpc_public "$node" server_info || true)"
  [ -z "$json" ] && return 1
  rpc_field "$json" info.pubkey_node
}

# node_info_local_via_ssh NODE — full server_info from the node's admin RPC.
node_info() {
  local node="${1:?node_info needs a node}" port json
  guard_reject_target "$node"
  port="$("$INV" get cluster.ports.rpc_admin)"
  json="$(node_ssh "$node" "curl -fsS --max-time 20 -H 'content-type: application/json' --data '{\"method\":\"server_info\",\"params\":[{}]}' http://127.0.0.1:${port}/" 2>/dev/null || true)"
  [ -z "$json" ] && json="$(rpc_public "$node" server_info || true)"
  printf '%s' "$json"
}
