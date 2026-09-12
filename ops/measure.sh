#!/usr/bin/env bash
# ops/measure.sh — GB per million ledgers. Run INSIDE a node VM.
#
# Nobody currently knows this number, and every later sizing decision depends
# on it: whether full history fits, whether the 700 GiB cap can rise, how deep
# ledger_history can go, how big node 3's LV needs to be.
#
# Run it once node 1 reports a STABLE complete_ledgers range that covers the
# full requested history — measuring mid-backfill gives a number that is too
# small and too confident.
#
#   du -sh /var/lib/xahaud/db/nudb
#   du -sh /var/lib/xahaud/db/*.db        # transaction.db, ledger.db
#   divide by (ledger range / 1e6)
#
# Writes a paste-ready block for docs/DECISIONS.md, and with --record appends
# it there directly.
#
# Usage: ops/measure.sh [--record] [--json] [--force]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"

RECORD=0; JSON=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --record) RECORD=1; shift ;;
    --json)   JSON=1; shift ;;
    --force)  FORCE=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

NODE="$(resolve_node "${XAH_NODE:-}")"
node_env "$NODE"
MOUNT="$N_DB_MOUNT"
mountpoint -q "$MOUNT" || die "$MOUNT is not mounted"

hdr "$NODE — measuring database size against ledger range"

SI="$(server_info_local || true)"
[ -n "$SI" ] || die "server_info failed — xahaud must be running to report complete_ledgers"
STATE="$(rpc_field "$SI" info.server_state || echo unknown)"
CL="$(rpc_field "$SI" info.complete_ledgers || echo '')"
VALIDATED="$(rpc_field "$SI" info.validated_ledger.seq || echo '')"
[ -n "$CL" ] || die "node reports no complete_ledgers yet"

if ! read -r LOW HIGH < <(parse_complete_ledgers "$CL"); then
  die "cannot parse complete_ledgers='$CL'"
fi
RANGE=$(( HIGH - LOW + 1 ))
WANT="$(awk '/^\[ledger_history\]/{getline; print; exit}' "$N_XAHAUD_CFG" 2>/dev/null || echo "$N_LEDGER_HISTORY_INITIAL")"

printf '  %-24s %s\n' "server_state"      "$STATE"
printf '  %-24s %s\n' "complete_ledgers"  "$CL"
printf '  %-24s %s\n' "range (ledgers)"   "$RANGE"
printf '  %-24s %s\n' "ledger_history"    "$WANT"
printf '  %-24s %s\n' "validated ledger"  "${VALIDATED:-?}"

# ── is the measurement trustworthy? ────────────────────────────────────────
if [ "$STATE" != full ] && [ "$STATE" != proposing ] && [ "$STATE" != validating ]; then
  warn "server_state is '$STATE', not 'full' — the node is still catching up."
fi
if [ "$RANGE" -lt $(( WANT * 95 / 100 )) ]; then
  warn "range ($RANGE) is below 95% of ledger_history ($WANT) — backfill looks incomplete."
  warn "A number measured mid-backfill understates the real cost per million ledgers."
  [ "$FORCE" = 1 ] || confirm "Measure anyway?"
fi

# ── sizes, in bytes so the arithmetic is honest ────────────────────────────
bytes_of() { du -sb --apparent-size=0 "$1" 2>/dev/null | cut -f1 || du -sb "$1" 2>/dev/null | cut -f1 || echo 0; }
NUDB_B="$(du -sb "$MOUNT/db/nudb" 2>/dev/null | cut -f1 || echo 0)"
SQL_B=0
SQL_LINES=""
for f in "$MOUNT"/db/*.db; do
  [ -e "$f" ] || continue
  b="$(du -sb "$f" | cut -f1)"
  SQL_B=$(( SQL_B + b ))
  SQL_LINES+="$(printf '  %-24s %s\n' "$(basename "$f")" "$(numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "$b")")"$'\n'
done
TOTAL_B="$(du -sb "$MOUNT/db" | cut -f1)"
DF_USED_B=$(( $(df -B1 --output=used "$MOUNT" | tail -1 | tr -dc '0-9') ))
CAP_B=$(( N_DB_GIB * 1024 * 1024 * 1024 ))

hdr "sizes"
printf '  %-24s %s\n' "nudb"  "$(numfmt --to=iec --suffix=B "$NUDB_B" 2>/dev/null || echo "$NUDB_B")"
printf '%s' "$SQL_LINES"
printf '  %-24s %s\n' "sqlite total" "$(numfmt --to=iec --suffix=B "$SQL_B" 2>/dev/null || echo "$SQL_B")"
printf '  %-24s %s\n' "db/ total (du)" "$(numfmt --to=iec --suffix=B "$TOTAL_B" 2>/dev/null || echo "$TOTAL_B")"
printf '  %-24s %s\n' "volume used (df)" "$(numfmt --to=iec --suffix=B "$DF_USED_B" 2>/dev/null || echo "$DF_USED_B")"
printf '  %-24s %s GiB\n' "cap" "$N_DB_GIB"

# ── the number ─────────────────────────────────────────────────────────────
read -r GB_PER_M NUDB_PER_M SQL_PER_M FULL_FIT HEADROOM_M < <(awk -v t="$TOTAL_B" -v n="$NUDB_B" -v s="$SQL_B" -v r="$RANGE" -v cap="$CAP_B" 'BEGIN{
  m=r/1000000.0; g=1073741824.0;
  tpm=(t/g)/m; npm=(n/g)/m; spm=(s/g)/m;
  printf "%.2f %.2f %.2f %.2f %.2f", tpm, npm, spm, (cap/g)/tpm, ((cap/g)-(t/g))/tpm;
}')

hdr "GB PER MILLION LEDGERS"
printf '  %-24s %s GiB/million   <-- THE NUMBER\n' "total"  "$GB_PER_M"
printf '  %-24s %s GiB/million\n' "nudb only"    "$NUDB_PER_M"
printf '  %-24s %s GiB/million\n' "sqlite only"  "$SQL_PER_M"
printf '  %-24s %s million ledgers would fill the %s GiB cap\n' "implied capacity" "$FULL_FIT" "$N_DB_GIB"
printf '  %-24s %s million more ledgers fit in what is left\n' "remaining headroom" "$HEADROOM_M"

SAFE_LH="$(awk -v f="$FULL_FIT" 'BEGIN{printf "%d", int(f*1000000*0.80/100000)*100000}')"
printf '  %-24s %s (80%% of the cap, keep online_delete above it)\n' "suggested ledger_history" "$SAFE_LH"
[ "$SAFE_LH" -ge "$N_ONLINE_DELETE" ] && warn "that suggestion is >= online_delete ($N_ONLINE_DELETE) — raise online_delete in config/roles/${N_ROLE}.yml first, or the node will fetch history only to delete it again"

BLOCK="$(cat <<MD

### Measurement — $(date -u '+%Y-%m-%d %H:%M UTC') — $NODE ($N_ROLE)

| field | value |
|---|---|
| server_state | \`$STATE\` |
| complete_ledgers | \`$CL\` |
| range | $RANGE ledgers |
| ledger_history (configured) | $WANT |
| nudb | $(numfmt --to=iec --suffix=B "$NUDB_B" 2>/dev/null || echo "$NUDB_B") |
| sqlite (transaction.db + ledger.db) | $(numfmt --to=iec --suffix=B "$SQL_B" 2>/dev/null || echo "$SQL_B") |
| db/ total | $(numfmt --to=iec --suffix=B "$TOTAL_B" 2>/dev/null || echo "$TOTAL_B") |
| volume cap | $N_DB_GIB GiB |
| **GB per million ledgers** | **$GB_PER_M GiB/million** |
| — nudb share | $NUDB_PER_M GiB/million |
| — sqlite share | $SQL_PER_M GiB/million |
| implied capacity at this cap | $FULL_FIT million ledgers |
| suggested ledger_history (80% of cap) | $SAFE_LH |

Full Xahau history is roughly $( [ -n "$VALIDATED" ] && awk -v v="$VALIDATED" 'BEGIN{printf "%.1f", v/1000000}' || echo '?' ) million ledgers today, so full
history would need about $( [ -n "$VALIDATED" ] && awk -v v="$VALIDATED" -v g="$GB_PER_M" 'BEGIN{printf "%.0f", v/1000000*g}' || echo '?' ) GiB at this measured rate.
MD
)"

if [ "$RECORD" = 1 ]; then
  DEC="$REPO_ROOT/docs/DECISIONS.md"
  [ -f "$DEC" ] || die "$DEC not found"
  printf '%s\n' "$BLOCK" >> "$DEC"
  sed -i 's/^> \*\*MEASUREMENT PENDING\*\*.*/> **MEASURED** — see the measurement table(s) at the end of this file./' "$DEC"
  ok "appended to $DEC (and cleared MEASUREMENT PENDING)"
  info "commit it: git add docs/DECISIONS.md && git commit -m 'measure: GB per million ledgers on $NODE'"
else
  hdr "paste this into docs/DECISIONS.md (or re-run with --record)"
  printf '%s\n' "$BLOCK"
fi

[ "$JSON" = 1 ] && printf '{"node":"%s","range":%s,"gb_per_million":%s,"nudb_bytes":%s,"sqlite_bytes":%s,"cap_gib":%s}\n' \
  "$NODE" "$RANGE" "$GB_PER_M" "$NUDB_B" "$SQL_B" "$N_DB_GIB"
exit 0
