#!/usr/bin/env bash
# ops/prune-guard.sh — the rolling window. Cron every 2h, INSIDE each node VM.
#
# online_delete is count-based, not size-based: there is no setting that says
# "prune at 80% disk". advisory_delete=1 means NOTHING prunes until can_delete
# is called, so disk pressure has to drive pruning explicitly — that is this
# script's whole job.
#
# WHY 70% AND NOT 90%. Online delete works by rotation: xahaud keeps a
# writable backend and an archive backend, and reclaims space by dropping the
# old archive when it rotates. That needs transient space for both. Waiting
# until the volume is nearly full can leave no room to perform the prune that
# would free the room. Trigger early.
#
# The measured transient cost of a real rotation sets the real threshold —
# record it in docs/DECISIONS.md and adjust prune_trigger_pct in inventory.yml
# from observation, not from this comment.
#
# Usage: ops/prune-guard.sh [--force] [--threshold N] [--dry-run] [--status]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

FORCE=0; DRY=0; STATUS=0; THRESHOLD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force)     FORCE=1; shift ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    --status)    STATUS=1; shift ;;
    -h|--help)   sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

NODE="$(resolve_node "${XAH_NODE:-}")"
node_env "$NODE"
MOUNT="$N_DB_MOUNT"
THRESHOLD="${THRESHOLD:-$N_PRUNE_TRIGGER_PCT}"
STATE_DIR="$REPO_ROOT/.state"; mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/prune-guard.state"
LOCK="$STATE_DIR/prune-guard.lock"

mountpoint -q "$MOUNT" || die "$MOUNT is not mounted — refusing to reason about disk pressure"

USE="$(df --output=pcent "$MOUNT" | tail -1 | tr -dc '0-9')"
AVAIL_G="$(df -BG --output=avail "$MOUNT" | tail -1 | tr -dc '0-9')"
SIZE_G="$(df -BG --output=size "$MOUNT" | tail -1 | tr -dc '0-9')"

if [ "$STATUS" = 1 ]; then
  printf 'node            %s (%s)\n' "$NODE" "$N_ROLE"
  printf 'volume          %s  %s%% used  %s GiB free of %s GiB\n' "$MOUNT" "$USE" "$AVAIL_G" "$SIZE_G"
  printf 'threshold       %s%%\n' "$THRESHOLD"
  printf 'advisory_delete %s (nothing prunes unless can_delete is called)\n' "$N_ADVISORY_DELETE"
  printf 'online_delete   %s\n' "$N_ONLINE_DELETE"
  [ -f "$STATE" ] && { echo '--- last run ---'; cat "$STATE"; }
  SI="$(server_info_local || true)"
  [ -n "$SI" ] && printf 'complete_ledgers %s\n' "$(rpc_field "$SI" info.complete_ledgers || echo '?')"
  exit 0
fi

# Only one rotation at a time. A second can_delete mid-rotation is how you
# lose a node for an afternoon.
exec 9>"$LOCK"
flock -n 9 || { info "another prune-guard run holds the lock — exiting"; exit 0; }

if [ "$USE" -lt "$THRESHOLD" ] && [ "$FORCE" = 0 ]; then
  info "$MOUNT at ${USE}% (threshold ${THRESHOLD}%) — nothing to do"
  printf 'ts=%s use=%s%% action=none\n' "$(date -u +%FT%TZ)" "$USE" > "$STATE"
  exit 0
fi

logger -t xah-prune "DB volume at ${USE}% — firing can_delete now" 2>/dev/null || true
alert WARN "$NODE: DB volume at ${USE}% (>= ${THRESHOLD}%) — firing can_delete now (${AVAIL_G} GiB free)"

# Before rotating, capture the window so the effect is measurable afterwards.
SI="$(server_info_local || true)"
BEFORE_CL="$(rpc_field "$SI" info.complete_ledgers 2>/dev/null || echo '?')"
BEFORE_STATE="$(rpc_field "$SI" info.server_state 2>/dev/null || echo '?')"
info "before: complete_ledgers=$BEFORE_CL server_state=$BEFORE_STATE use=${USE}% avail=${AVAIL_G}GiB"

if [ "$DRY" = 1 ]; then
  info "--dry-run: would call can_delete now"
  exit 0
fi

# Rotation needs transient space for both backends. If there is genuinely no
# room left to rotate, say so loudly rather than firing into a wall — the
# filesystem cap is the backstop and this is the moment a human is needed.
if [ "$AVAIL_G" -lt 20 ]; then
  alert CRIT "$NODE: only ${AVAIL_G} GiB free on $MOUNT. A rotation may not have room to complete. Lower prune_trigger_pct in inventory.yml and/or raise the cap (lvextend + xfs_growfs). See docs/RUNBOOK.md."
fi

START="$(date +%s)"
OUT="$(rpc_local can_delete '{"can_delete":"now"}' || true)"
if [ -z "$OUT" ]; then
  # older builds take it positionally through the binary's RPC client
  OUT="$("$N_XAHAUD_BIN" --silent --conf "$N_XAHAUD_CFG" can_delete now 2>&1 || true)"
fi
ELAPSED=$(( $(date +%s) - START ))

CAN_DELETE="$(rpc_field "$OUT" can_delete 2>/dev/null || true)"
if rpc_ok "$OUT" || [ -n "$CAN_DELETE" ]; then
  ok "can_delete accepted (can_delete=${CAN_DELETE:-?}) in ${ELAPSED}s"
else
  err "can_delete did not report success:"
  printf '%s\n' "$OUT" | head -20 >&2
  alert CRIT "$NODE: can_delete FAILED at ${USE}% disk. Pruning is not happening. Investigate now — docs/RUNBOOK.md."
fi

sleep 5
AFTER_USE="$(df --output=pcent "$MOUNT" | tail -1 | tr -dc '0-9')"
SI2="$(server_info_local || true)"
AFTER_CL="$(rpc_field "$SI2" info.complete_ledgers 2>/dev/null || echo '?')"

{
  printf 'ts=%s\n' "$(date -u +%FT%TZ)"
  printf 'action=can_delete_now rc_text=%s elapsed_s=%s\n' "${CAN_DELETE:-unknown}" "$ELAPSED"
  printf 'use_before=%s%% use_after=%s%% threshold=%s%%\n' "$USE" "$AFTER_USE" "$THRESHOLD"
  printf 'avail_before_gib=%s size_gib=%s\n' "$AVAIL_G" "$SIZE_G"
  printf 'complete_ledgers_before=%s\n' "$BEFORE_CL"
  printf 'complete_ledgers_after=%s\n' "$AFTER_CL"
} > "$STATE"

info "after: use=${AFTER_USE}% complete_ledgers=$AFTER_CL"
cat >&2 <<'NOTE'
  Rotation does not free space instantly — space comes back when the old
  archive backend is dropped. Watch the next few growth-watch runs.

  THREE THINGS TO VERIFY ON THE FIRST REAL ROTATION (record in DECISIONS.md):
    1. how much transient space the rotation actually consumed
    2. whether it also trimmed transaction.db / ledger.db, or whether the
       SQLite side needs separate attention
    3. how long it took and whether the node stayed responsive throughout
NOTE
