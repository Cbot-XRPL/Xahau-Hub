#!/usr/bin/env bash
# ops/growth-watch.sh — the safety net. Cron every 6h.
#
# Two modes, because there are two things that can kill this setup:
#
#   --mode guest  (in each node VM)  df on the DB volume + du on the NuDB path
#                                    and the SQLite files
#   --mode host   (on pve2)          thin pool data_percent AND metadata_percent
#
# METADATA MATTERS AS MUCH AS DATA. A pool that exhausts causes LVM to suspend
# volumes, not degrade gracefully, and metadata exhaustion kills a pool just as
# dead — it is the failure people do not see coming. Both are checked.
#
# A bigger cap means more runway before the filesystem stops the node, which
# makes this script more important, not less: 700 GiB without growth-watch
# running is worse than 500 GiB with it.
#
# Alerts at warn (60%) and loud at crit (80%) on either axis; thresholds live
# in inventory.yml. Also records a growth history so GB/day is visible.
#
# Usage: ops/growth-watch.sh [--mode auto|host|guest] [--quiet] [--json]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

MODE=auto; QUIET=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)  MODE="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --json)  JSON=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ "$MODE" = auto ]; then
  if command -v lvs >/dev/null 2>&1 && [ -d /etc/pve ]; then MODE=host; else MODE=guest; fi
fi
STATE_DIR="$REPO_ROOT/.state"; mkdir -p "$STATE_DIR"
RC=0
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }

level_for() {                      # level_for PCT WARN CRIT -> ok|warn|crit
  local p="${1%%.*}" w="$2" c="$3"
  if [ "$p" -ge "$c" ]; then echo crit
  elif [ "$p" -ge "$w" ]; then echo warn
  else echo ok; fi
}

# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = host ]; then
  guard_require_host
  need lvs
  VG="$("$INV" get cluster.host.storage_vg)"
  TP="$("$INV" get cluster.host.storage_thinpool)"
  W="$("$INV" get cluster.thresholds.pool_warn_pct)"
  C="$("$INV" get cluster.thresholds.pool_crit_pct)"

  read -r SIZE DATA META < <(lvs --noheadings --nosuffix --units g \
      -o lv_size,data_percent,metadata_percent "$VG/$TP" | tr -s ' ' | sed 's/^ //')
  [ -n "${DATA:-}" ] || die "cannot read $VG/$TP"

  say "$(printf '%-22s %s' 'thin pool' "$VG/$TP  ${SIZE%.*} GiB")"
  HIST="$STATE_DIR/pool-history.tsv"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$DATA" "$META" >> "$HIST"

  for pair in "data:$DATA:$W:$C" "metadata:$META:$W:$C"; do
    IFS=: read -r k v w c <<<"$pair"
    lvl="$(level_for "$v" "$w" "$c")"
    say "$(printf '%-22s %6s %%   [%s]' "${k}_percent" "$v" "$lvl")"
    case "$lvl" in
      crit) alert CRIT "thin pool $VG/$TP ${k}_percent at ${v}% (>= ${c}%). A pool that exhausts SUSPENDS volumes. Act now: docs/RUNBOOK.md"; RC=2 ;;
      warn) alert WARN "thin pool $VG/$TP ${k}_percent at ${v}% (>= ${w}%)"; [ "$RC" = 0 ] && RC=1 ;;
    esac
  done

  # growth rate from history
  if [ "$(wc -l < "$HIST")" -gt 2 ]; then
    read -r t0 d0 _ < <(head -1 "$HIST"); read -r t1 d1 _ < <(tail -1 "$HIST")
    S0="$(date -d "$t0" +%s 2>/dev/null || echo 0)"; S1="$(date -d "$t1" +%s 2>/dev/null || echo 0)"
    if [ "$S1" -gt "$S0" ]; then
      say "$(awk -v d0="$d0" -v d1="$d1" -v s0="$S0" -v s1="$S1" -v sz="${SIZE%.*}" 'BEGIN{
        days=(s1-s0)/86400; if(days<=0){exit}
        gpd=((d1-d0)/100.0*sz)/days;
        printf "%-22s %+.2f GiB/day over %.1f days", "pool growth", gpd, days;
        if (gpd>0.01) printf "  -> %.0f days to 100%%", ((100-d1)/100.0*sz)/gpd;
      }')"
    fi
  fi

  say ""
  say "per-volume:"
  lvs --noheadings -o lv_name,lv_size,data_percent "$VG" 2>/dev/null \
    | grep -E 'vm-[0-9]+-disk' | while read -r line; do say "  $line"; done

  # unprovisioned reserve still intact?
  RES="$("$INV" get cluster.host.reserve_gib)"
  # --select regex support varies by LVM version; grep the plain listing instead
  # so this check can never silently measure nothing and report "reserve fine".
  ALLOC=0; COUNTED=0
  while read -r name sz; do
    case "$name" in vm-*-disk-*|lv-*-db) : ;; *) continue ;; esac
    ALLOC=$(( ALLOC + ${sz%%.*} )); COUNTED=$(( COUNTED + 1 ))
  done < <(lvs --noheadings --nosuffix --units g -o lv_name,lv_size "$VG" 2>/dev/null | tr -s ' ' | sed 's/^ //')
  [ "$COUNTED" = 0 ] && warn "could not enumerate volumes in VG $VG — the reserve check below is meaningless. Run: lvs $VG"
  FREE=$(( ${SIZE%.*} - ALLOC ))
  say ""
  say "$(printf '%-22s %s GiB provisioned, %s GiB unprovisioned (reserve %s GiB)' 'allocation' "$ALLOC" "$FREE" "$RES")"
  if [ "$FREE" -lt "$RES" ]; then
    alert WARN "unprovisioned reserve is down to ${FREE} GiB (target ${RES} GiB). This host does not overcommit — do not provision further without redoing the math."
    [ "$RC" = 0 ] && RC=1
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = guest ]; then
  NODE="$(resolve_node "${XAH_NODE:-}")"
  node_env "$NODE"
  W="$N_DB_WARN_PCT"; C="$N_DB_CRIT_PCT"
  MOUNT="$N_DB_MOUNT"
  mountpoint -q "$MOUNT" || { alert CRIT "$NODE: $MOUNT is NOT MOUNTED. xahaud is writing to the root disk or not at all. Fix immediately."; exit 2; }

  read -r SIZE USED AVAIL PCENT < <(df -BG --output=size,used,avail,pcent "$MOUNT" | tail -1 | tr -dc '0-9G% \n' | tr -s ' ')
  P="${PCENT%\%}"
  lvl="$(level_for "$P" "$W" "$C")"

  say "$(printf '%-22s %s (%s, role %s)' 'node' "$NODE" "$(hostname -s)" "$N_ROLE")"
  say "$(printf '%-22s %s  cap %s  used %s  free %s  [%s]' 'db volume' "$MOUNT" "$SIZE" "$USED" "$AVAIL" "$lvl")"
  say "$(printf '%-22s %s%% (warn %s%%, crit %s%%, prune fires at %s%%)' 'utilisation' "$P" "$W" "$C" "$N_PRUNE_TRIGGER_PCT")"

  NUDB="$MOUNT/db/nudb"
  if [ -d "$NUDB" ]; then
    say "$(printf '%-22s %s' 'nudb' "$(du -sh "$NUDB" 2>/dev/null | cut -f1)")"
  fi
  for f in "$MOUNT"/db/*.db; do
    [ -e "$f" ] || continue
    say "$(printf '%-22s %s' "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)")"
  done

  USED_G="${USED%G}"
  HIST="$STATE_DIR/db-history.tsv"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$USED_G" "$P" >> "$HIST"
  if [ "$(wc -l < "$HIST")" -gt 2 ]; then
    read -r t0 u0 _ < <(head -1 "$HIST"); read -r t1 u1 _ < <(tail -1 "$HIST")
    S0="$(date -d "$t0" +%s 2>/dev/null || echo 0)"; S1="$(date -d "$t1" +%s 2>/dev/null || echo 0)"
    [ "$S1" -gt "$S0" ] && say "$(awk -v u0="$u0" -v u1="$u1" -v s0="$S0" -v s1="$S1" -v av="${AVAIL%G}" 'BEGIN{
      days=(s1-s0)/86400; if(days<=0)exit;
      gpd=(u1-u0)/days; printf "%-22s %+.2f GiB/day over %.1f days", "growth", gpd, days;
      if(gpd>0.01) printf "  -> %.0f days to the cap", av/gpd;
    }')"
  fi

  # window + state, so a stalled sync shows up here too
  SI="$(server_info_local || true)"
  if [ -n "$SI" ]; then
    say "$(printf '%-22s %s' 'server_state' "$(rpc_field "$SI" info.server_state || echo '?')")"
    say "$(printf '%-22s %s' 'complete_ledgers' "$(rpc_field "$SI" info.complete_ledgers || echo '?')")"
    say "$(printf '%-22s %s' 'peers' "$(rpc_field "$SI" info.peers || echo '?')")"
  else
    say "$(printf '%-22s %s' 'server_info' 'unreachable (xahaud stopped?)')"
  fi

  case "$lvl" in
    crit) alert CRIT "$NODE: DB volume at ${P}% of ${SIZE} (>= ${C}%). ${AVAIL} free. The filesystem cap is the backstop, not the mechanism — check prune-guard is firing: ops/prune-guard.sh --status"; RC=2 ;;
    warn) alert WARN "$NODE: DB volume at ${P}% of ${SIZE} (>= ${W}%), ${AVAIL} free"; [ "$RC" = 0 ] && RC=1 ;;
  esac

  # If we are above the prune threshold and the last prune-guard run did
  # nothing, that is the actual emergency: the window is not rolling.
  PSTATE="$STATE_DIR/prune-guard.state"
  if [ "$P" -ge "$N_PRUNE_TRIGGER_PCT" ] && [ -f "$PSTATE" ] && grep -q 'action=none' "$PSTATE"; then
    alert CRIT "$NODE: at ${P}% but the last prune-guard run took no action. Pruning is NOT rolling. Run ops/prune-guard.sh --force and read docs/RUNBOOK.md."
    RC=2
  fi
fi

if [ "$JSON" = 1 ]; then
  printf '{"mode":"%s","rc":%s,"ts":"%s","host":"%s"}\n' "$MODE" "$RC" "$(date -u +%FT%TZ)" "$(hostname -s)"
fi
exit "$RC"
