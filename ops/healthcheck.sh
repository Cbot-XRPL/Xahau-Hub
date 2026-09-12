#!/usr/bin/env bash
# ops/healthcheck.sh — is each node actually serving what it claims to?
#
# Checks per node: reachability, server_state, complete_ledgers, window size
# against configured ledger_history, peer count, load_factor, amendment_blocked.
#
# And the one that matters most for a history endpoint: it remembers the LOWER
# BOUND of complete_ledgers between runs and alerts if it advances unexpectedly.
# With advisory_delete=1 nothing should prune except when prune-guard.sh fires
# on disk pressure, so a lower bound that creeps up on its own means the node
# is discarding history it was asked to keep — and a client that got a valid
# account_tx answer yesterday will get an incomplete one today.
#
# Usage:
#   ops/healthcheck.sh                 # every enabled node, over public RPC
#   ops/healthcheck.sh --local         # this node, over admin RPC (cron)
#   ops/healthcheck.sh xah-node-1      # one node
#   ops/healthcheck.sh --quiet         # only complain
# Exit: 0 all healthy, 1 warnings, 2 something is broken.
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

LOCAL=0; QUIET=0; TARGETS=()
MIN_PEERS="${XAH_MIN_PEERS:-5}"
while [ $# -gt 0 ]; do
  case "$1" in
    --local)  LOCAL=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    --min-peers) MIN_PEERS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  TARGETS+=("$1"); shift ;;
  esac
done

STATE_DIR="$REPO_ROOT/.state"; mkdir -p "$STATE_DIR"
RC=0
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }
bump() { [ "$1" -gt "$RC" ] && RC="$1"; return 0; }

if [ "$LOCAL" = 1 ]; then
  TARGETS=("$(resolve_node "${XAH_NODE:-}")")
elif [ "${#TARGETS[@]}" -eq 0 ]; then
  mapfile -t TARGETS < <("$INV" nodes --enabled)
fi

check_node() {
  local node="$1"
  guard_reject_target "$node"
  node_env "$node"
  local label="$node ($N_ROLE, $N_ADDRESS)"

  local si
  if [ "$LOCAL" = 1 ]; then si="$(server_info_local || true)"; else si="$(rpc_public "$node" server_info || true)"; fi

  if [ -z "$si" ]; then
    alert CRIT "$label: server_info UNREACHABLE ($( [ "$LOCAL" = 1 ] && echo 'admin RPC on 127.0.0.1' || echo "public RPC on port $N_RPC_PUBLIC" ))"
    bump 2; return 0
  fi

  local state cl peers lf ver blocked
  state="$(rpc_field "$si" info.server_state || echo unknown)"
  cl="$(rpc_field "$si" info.complete_ledgers || echo '')"
  peers="$(rpc_field "$si" info.peers || echo 0)"
  lf="$(rpc_field "$si" info.load_factor || echo 1)"
  ver="$(rpc_field "$si" info.build_version || echo '?')"
  blocked="$(rpc_field "$si" info.amendment_blocked || echo false)"

  say ""
  say "── $label"
  say "$(printf '   %-20s %s' build "$ver")"
  say "$(printf '   %-20s %s' server_state "$state")"
  say "$(printf '   %-20s %s' complete_ledgers "${cl:-none}")"
  say "$(printf '   %-20s %s (min %s, peers_max %s)' peers "$peers" "$MIN_PEERS" "$N_PEERS_MAX")"
  say "$(printf '   %-20s %s' load_factor "$lf")"

  case "$state" in
    full|proposing|validating) : ;;
    connected|syncing|tracking)
      alert WARN "$label: server_state=$state — not serving complete answers yet"; bump 1 ;;
    *)
      alert CRIT "$label: server_state=$state"; bump 2 ;;
  esac

  [ "$blocked" = true ] && { alert CRIT "$label: AMENDMENT BLOCKED — the binary is too old for the current amendment set. Update xahaud."; bump 2; }

  if [ "${peers%%.*}" -lt "$MIN_PEERS" ]; then
    alert WARN "$label: only $peers peers. All nodes share one public IP and xahaud limits inbound connections per source IP, so these peer outbound — check egress and keep peers_max modest."
    bump 1
  fi
  awk -v l="$lf" 'BEGIN{exit !(l>4)}' 2>/dev/null && { alert WARN "$label: load_factor $lf — fee escalation is active, the node is under load"; bump 1; }

  # ── the window ───────────────────────────────────────────────────────────
  local low high window want
  if ! read -r low high < <(parse_complete_ledgers "$cl"); then
    alert WARN "$label: complete_ledgers='$cl' — no usable range"; bump 1; return 0
  fi
  window=$(( high - low + 1 ))
  want="$N_LEDGER_HISTORY_INITIAL"
  say "$(printf '   %-20s %s ledgers (configured ledger_history %s)' window "$window" "$want")"

  if [ "$window" -lt $(( want * 90 / 100 )) ] && [ "$state" = full ]; then
    alert WARN "$label: window is $window ledgers, under 90% of the requested $want. Either still backfilling, or history is being dropped."
    bump 1
  fi

  # ── lower-bound drift ────────────────────────────────────────────────────
  local sf="$STATE_DIR/health-$node.state"
  local prev_low="" prev_ts=""
  if [ -f "$sf" ]; then
    # shellcheck disable=SC1090
    prev_low="$(awk -F= '/^low=/{print $2}' "$sf")"
    prev_ts="$(awk -F= '/^ts=/{print $2}' "$sf")"
  fi

  if [ -n "$prev_low" ] && [ "$low" -gt "$prev_low" ]; then
    local advanced=$(( low - prev_low ))
    say "$(printf '   %-20s +%s ledgers since %s' 'lower bound moved' "$advanced" "$prev_ts")"

    local use=-1
    if [ "$LOCAL" = 1 ] && mountpoint -q "$N_DB_MOUNT"; then
      use="$(df --output=pcent "$N_DB_MOUNT" | tail -1 | tr -dc '0-9')"
    fi
    local pruned_recently=0
    [ -f "$STATE_DIR/prune-guard.state" ] && grep -q 'action=can_delete_now' "$STATE_DIR/prune-guard.state" && pruned_recently=1

    if [ "$pruned_recently" = 1 ]; then
      say "   (expected: prune-guard fired can_delete — the window is rolling as designed)"
    elif [ "$use" -ge 0 ] && [ "$use" -lt $(( N_PRUNE_TRIGGER_PCT - 5 )) ]; then
      alert CRIT "$label: lower bound advanced by $advanced ledgers ($prev_low -> $low) while the volume is only ${use}% full and prune-guard did NOT fire. This node is pruning when it should not be. advisory_delete is supposed to hold pruning until can_delete is called — check [node_db] advisory_delete=1 in $N_XAHAUD_CFG and that nothing else is calling can_delete."
      bump 2
    elif [ "$advanced" -gt 100000 ]; then
      alert WARN "$label: lower bound jumped $advanced ledgers ($prev_low -> $low) with no recorded prune-guard action. Confirm what moved it."
      bump 1
    fi
  fi

  { printf 'ts=%s\n' "$(date -u +%FT%TZ)"
    printf 'low=%s\nhigh=%s\nwindow=%s\nstate=%s\npeers=%s\n' "$low" "$high" "$window" "$state" "$peers"; } > "$sf"

  # ── admin must not be reachable from anywhere but localhost ─────────────
  if [ "$LOCAL" = 0 ]; then
    if curl -fsS --max-time 5 -o /dev/null "http://${N_ADDRESS}:${N_RPC_ADMIN}/" 2>/dev/null; then
      alert CRIT "$label: ADMIN RPC ON PORT $N_RPC_ADMIN IS REACHABLE OVER THE NETWORK. It must bind 127.0.0.1 only and must never be proxied. Fix $N_XAHAUD_CFG now."
      bump 2
    else
      say "$(printf '   %-20s %s' 'admin port' "closed from the network (correct)")"
    fi
  fi
}

hdr "healthcheck — $(date -u +%FT%TZ)"
for n in "${TARGETS[@]}"; do check_node "$n"; done

say ""
case "$RC" in
  0) ok "all checked nodes healthy" ;;
  1) warn "healthcheck finished with warnings" ;;
  2) err "healthcheck found a serious problem" ;;
esac
exit "$RC"
