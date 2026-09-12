#!/usr/bin/env bash
# provision/01-space-check.sh — no-overcommit gate. RUN THIS FIRST, ON pve2.
#
# Compares what inventory.yml wants to provision against what the thin pool
# actually has, and refuses if provisioning would exceed pool physical capacity
# or eat into the reserve.
#
# A thin pool that exhausts does not degrade gracefully — LVM SUSPENDS volumes.
# Metadata exhaustion kills a pool just as dead and is the failure people do
# not see coming, so metadata_percent is checked alongside data_percent.
#
# Usage: provision/01-space-check.sh [--remote]
#   --remote   run the host-side measurements over ssh from a workstation
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

REMOTE=0
[ "${1:-}" = "--remote" ] && REMOTE=1
[ "${1:-}" = "-h" ] && { sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

VG="$("$INV" get cluster.host.storage_vg)"
TP="$("$INV" get cluster.host.storage_thinpool)"
POOL_ID="$("$INV" get cluster.host.storage)"
CLAIM_GIB="$("$INV" get cluster.host.pool_physical_gib)"
RESERVE="$("$INV" get cluster.host.reserve_gib)"
PW="$("$INV" get cluster.thresholds.pool_warn_pct)"
PC="$("$INV" get cluster.thresholds.pool_crit_pct)"

run() {
  if [ "$REMOTE" = 1 ]; then host_ssh "$@"; else bash -c "$*"; fi
}

if [ "$REMOTE" = 0 ]; then
  guard_require_host
  need lvs
else
  info "measuring $POOL_ID on $("$INV" get cluster.host.name) over ssh"
fi

hdr "inventory intent"
"$INV" check || die "inventory check failed — fix inventory.yml before provisioning"

hdr "measured thin pool"
LVSLINE="$(run "lvs --noheadings --nosuffix --units b -o lv_size,data_percent,metadata_percent $VG/$TP 2>/dev/null" | tr -s ' ')" \
  || die "cannot read $VG/$TP — is this the right host?"
[ -n "${LVSLINE// /}" ] || die "lvs returned nothing for $VG/$TP"

SIZE_B="$(awk '{print $1}' <<<"${LVSLINE# }")"
DATA_PCT="$(awk '{printf "%.2f", $2}' <<<"${LVSLINE# }")"
META_PCT="$(awk '{printf "%.2f", $3}' <<<"${LVSLINE# }")"
SIZE_GIB=$(( SIZE_B / 1024 / 1024 / 1024 ))

printf '  %-28s %s\n' "thin pool"            "$VG/$TP"
printf '  %-28s %s GiB\n' "physical size"     "$SIZE_GIB"
printf '  %-28s %s GiB (inventory claim)\n' "expected"  "$CLAIM_GIB"
printf '  %-28s %s %%\n' "data_percent"       "$DATA_PCT"
printf '  %-28s %s %%\n' "metadata_percent"   "$META_PCT"

hdr "existing volumes on $POOL_ID"
run "lvs --noheadings -o lv_name,lv_size,data_percent,pool_lv $VG 2>/dev/null | grep -E 'vm-|^ *lv-' || true"

# ── reconcile the claim against reality ─────────────────────────────────────
DELTA=$(( SIZE_GIB > CLAIM_GIB ? SIZE_GIB - CLAIM_GIB : CLAIM_GIB - SIZE_GIB ))
if [ "$DELTA" -gt 32 ]; then
  err "pool is ${SIZE_GIB} GiB but inventory.yml claims ${CLAIM_GIB} GiB (delta ${DELTA} GiB)."
  die "Update cluster.host.pool_physical_gib in inventory.yml and redo the no-overcommit math. Do not proceed on a stale number."
fi

# ── the real gate: provisioned vs physical, using the measured size ─────────
PROV=400  # vm-100-disk-0, existing, DO NOT TOUCH
while read -r n; do
  [ -z "$n" ] && continue
  s="$("$INV" node "$n" storage)";    r="$("$INV" node "$n" root_gib)"
  ds="$("$INV" node "$n" db_storage)"; d="$("$INV" node "$n" db_gib)"
  [ "$s"  = "$POOL_ID" ] && PROV=$(( PROV + r ))
  [ "$ds" = "$POOL_ID" ] && PROV=$(( PROV + d ))
done < <("$INV" nodes --enabled)

FREE_AFTER=$(( SIZE_GIB - PROV ))
hdr "no-overcommit verdict"
printf '  %-28s %s GiB\n' "provisioned (enabled nodes)" "$PROV"
printf '  %-28s %s GiB\n' "pool physical (measured)"    "$SIZE_GIB"
printf '  %-28s %s GiB\n' "free after provisioning"     "$FREE_AFTER"
printf '  %-28s %s GiB\n' "required reserve"            "$RESERVE"

rc=0
if [ "$PROV" -gt "$SIZE_GIB" ]; then
  err "OVERCOMMIT: $PROV GiB provisioned against $SIZE_GIB GiB physical. This host does not overcommit."
  rc=1
elif [ "$FREE_AFTER" -lt "$RESERVE" ]; then
  err "RESERVE BREACH: only $FREE_AFTER GiB would remain, below the $RESERVE GiB reserve."
  err "Either lower a db_gib cap or deliberately redo the math and lower cluster.host.reserve_gib."
  rc=1
else
  ok "no overcommit: every volume can fill to its cap without exhausting the pool"
fi

for pair in "data:$DATA_PCT" "metadata:$META_PCT"; do
  k="${pair%%:*}"; v="${pair##*:}"; vi="${v%%.*}"
  if [ "$vi" -ge "$PC" ]; then alert CRIT "thin pool ${k}_percent at ${v}% (crit >= ${PC}%)"; rc=1
  elif [ "$vi" -ge "$PW" ]; then alert WARN "thin pool ${k}_percent at ${v}% (warn >= ${PW}%)"
  else ok "${k}_percent ${v}% — healthy"; fi
done

[ "$rc" = 0 ] && ok "space check PASSED" || err "space check FAILED"
exit "$rc"
