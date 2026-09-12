#!/usr/bin/env bash
# ops/seed-node.sh — copy a synced node's database to a new node.
#
# Do NOT backfill each node from the network independently. It is slow,
# unreliable on Xahau where the set of deep peers is small, and rude to the
# peers serving it.
#
# Sequence:
#   1. stop xahaud on BOTH nodes (a live NuDB copy is a corrupt NuDB copy)
#   2. rsync -aHAX the NuDB directory plus transaction.db and ledger.db
#   3. make sure the target keeps its OWN unique node_seed
#   4. start both, verify they have DIFFERENT pubkey_node values
#
# THE SEED GUARD IS THE POINT OF THIS SCRIPT. A copied identity means two
# nodes presenting one identity on the network. Two things can leak it:
#   - the config's [node_seed] (we render the target's own, and verify)
#   - wallet.db inside the database directory, which holds the node identity
#     when no node_seed is configured — so it is EXCLUDED from the rsync.
#
# Usage: ops/seed-node.sh --from xah-node-1 --to xah-node-2 [--dry-run] [--keep-running]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

FROM=""; TO=""; DRY=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --keep-running) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$FROM" ] && [ -n "$TO" ] || die "usage: $0 --from NODE --to NODE"
FROM="$(resolve_node "$FROM")"; TO="$(resolve_node "$TO")"
[ "$FROM" != "$TO" ] || die "source and target are the same node"
guard_reject_target "$FROM" "$TO"

# ── gather both nodes' settings ─────────────────────────────────────────────
eval "$("$INV" node "$FROM" | sed 's/^N_/SRC_/')"
eval "$("$INV" node "$TO"   | sed 's/^N_/DST_/')"
SVC="$SRC_XAHAUD_SERVICE"

hdr "seed $TO from $FROM"
printf '  %-14s %s (%s, role %s, cap %s GiB)\n' source "$FROM" "$SRC_ADDRESS" "$SRC_ROLE" "$SRC_DB_GIB"
printf '  %-14s %s (%s, role %s, cap %s GiB)\n' target "$TO"   "$DST_ADDRESS" "$DST_ROLE" "$DST_DB_GIB"

# ── seed guard, BEFORE anything is copied ───────────────────────────────────
hdr "seed guard"
SRC_SEED="$(require_seed "$SRC_SEED_VAR")"
DST_SEED="$(require_seed "$DST_SEED_VAR")"
[ "$SRC_SEED" != "$DST_SEED" ] \
  || die "GUARD: $FROM and $TO have the SAME node_seed in secrets/seeds.env. That is one identity on two nodes. Mint a fresh one: ops/gen-seed.sh --for $TO --append"
ok "$FROM and $TO have distinct seeds in secrets/seeds.env"

info "source pubkey_node: $(node_pubkey "$FROM" || echo unknown)"

# ── capacity check: will it even fit? ───────────────────────────────────────
hdr "capacity"
SRC_USED_K="$(node_ssh "$FROM" "du -sk $SRC_DB_MOUNT/db 2>/dev/null | cut -f1" || echo 0)"
DST_AVAIL_K="$(node_ssh "$TO" "df --output=avail -k $DST_DB_MOUNT | tail -1 | tr -dc '0-9'" || echo 0)"
printf '  %-18s %s GiB\n' "source db/"      "$(( SRC_USED_K / 1024 / 1024 ))"
printf '  %-18s %s GiB\n' "target free"     "$(( DST_AVAIL_K / 1024 / 1024 ))"
if [ "$SRC_USED_K" -gt "$DST_AVAIL_K" ]; then
  die "$TO does not have room: needs $(( SRC_USED_K/1024/1024 )) GiB, has $(( DST_AVAIL_K/1024/1024 )) GiB free. $TO is a $DST_ROLE node with a ${DST_DB_GIB} GiB cap and a shallower window — a deep node's database will not fit. Let $TO backfill its own shallow window instead, or raise its cap into the reserve deliberately."
fi
if [ "$SRC_ROLE" = deep ] && [ "$DST_ROLE" = api ]; then
  warn "$FROM is a deep node and $TO is a shallow api node. Copying deep history onto an api node fills it up and the first prune-guard rotation throws most of it away."
  warn "Usually you want: let $TO sync its own $DST_LEDGER_HISTORY_INITIAL-ledger window, or seed it and then immediately fire ops/prune-guard.sh --force."
  confirm "Continue seeding $TO from $FROM?"
fi

if [ "$DRY" = 1 ]; then
  hdr "--dry-run: rsync plan"
  node_ssh "$FROM" "ls -la $SRC_DB_MOUNT/db" || true
  info "would rsync $FROM:$SRC_DB_MOUNT/db/ -> $TO:$DST_DB_MOUNT/db/  (excluding wallet.db)"
  exit 0
fi

confirm "Stop xahaud on BOTH $FROM and $TO and copy the database?"

# ── 1. stop both ────────────────────────────────────────────────────────────
hdr "1. stopping xahaud"
for n in "$FROM" "$TO"; do
  info "stopping $SVC on $n (NuDB flushes on shutdown; this can take minutes)"
  node_ssh "$n" "systemctl stop $SVC" || warn "$n: stop reported an error"
done
for n in "$FROM" "$TO"; do
  node_ssh "$n" "systemctl is-active --quiet $SVC" && die "$n: $SVC is still running. Refusing to copy a live NuDB — that produces a corrupt copy."
  ok "$n: stopped"
done

restart_both() {
  hdr "restarting"
  for n in "$FROM" "$TO"; do
    node_ssh "$n" "systemctl start $SVC" && ok "$n: started" || err "$n: failed to start"
  done
}
[ "$KEEP" = 0 ] && trap 'restart_both' EXIT

# ── 2. rsync ────────────────────────────────────────────────────────────────
hdr "2. rsync"
# -aHAX preserves hardlinks, ACLs and xattrs. wallet.db is EXCLUDED: it holds
# the node identity when no node_seed is configured, and copying it is exactly
# the mistake this script exists to prevent.
RSYNC_ARGS=(-aHAX --info=progress2 --human-readable --delete
  --exclude 'wallet.db' --exclude 'wallet.db-*'
  --exclude '*.lock' --exclude 'lost+found')

SRC_USER="${SRC_SSH_USER}@${SRC_ADDRESS}"
DST_USER="${DST_SSH_USER}@${DST_ADDRESS}"
guard_reject_target "$SRC_USER" "$DST_USER"

# Pull to here then push? No — that doubles the transfer. Drive it from the
# source over ssh so the data goes node->node on the 10GbE path.
info "running rsync on $FROM, pushing to $TO"
node_ssh "$FROM" "rsync ${RSYNC_ARGS[*]} -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' $SRC_DB_MOUNT/db/ ${DST_USER}:$DST_DB_MOUNT/db/" \
  || die "rsync failed. The target database is now incomplete — do not start it expecting a good copy. Re-run, or wipe $TO:$DST_DB_MOUNT/db and let it sync from the network."
ok "database copied"

node_ssh "$TO" "chown -R $DST_XAHAUD_USER:$DST_XAHAUD_USER $DST_DB_MOUNT && du -sh $DST_DB_MOUNT/db"

# ── 3. identity guard on the target ─────────────────────────────────────────
hdr "3. identity"
if node_ssh "$TO" "test -e $DST_DB_MOUNT/db/wallet.db"; then
  warn "$TO has a wallet.db. It was not copied (excluded), but confirm it is the target's own."
fi
CFG_SEED="$(node_ssh "$TO" "awk '/^\\[node_seed\\]/{getline; print; exit}' $DST_XAHAUD_CFG" 2>/dev/null || true)"
[ -n "$CFG_SEED" ] || die "$TO has no [node_seed] in $DST_XAHAUD_CFG. Deploy its config first: make render NODE=$TO && make deploy NODE=$TO"
[ "$CFG_SEED" != "$SRC_SEED" ] \
  || die "GUARD: $TO's deployed config carries $FROM's seed. Two nodes, one identity. Re-render $TO's config and deploy it before starting."
[ "$CFG_SEED" = "$DST_SEED" ] \
  || warn "$TO's deployed [node_seed] does not match $DST_SEED_VAR in secrets/seeds.env. It is at least not the source's — but re-render to be sure."
ok "$TO carries its own node_seed"

# ── 4. start both and verify distinct identities ────────────────────────────
trap - EXIT
restart_both
hdr "4. verify"
sleep 20
declare -A PUBS=()
for n in "$FROM" "$TO"; do
  p="$(node_pubkey "$n" 2>/dev/null || true)"
  PUBS["$n"]="$p"
  printf '  %-14s pubkey_node=%s\n' "$n" "${p:-unavailable}"
done
if [ -n "${PUBS[$FROM]:-}" ] && [ "${PUBS[$FROM]}" = "${PUBS[$TO]:-}" ]; then
  err "BOTH NODES REPORT THE SAME pubkey_node. That is one identity on two nodes."
  err "Stop $TO now, mint a new seed (ops/gen-seed.sh --for $TO --append), re-render and redeploy."
  exit 2
fi
ok "distinct identities confirmed"

info "next: make cluster   # regenerate [cluster_nodes] now that $TO has a stable pubkey_node"
"$REPO_ROOT/ops/healthcheck.sh" "$FROM" "$TO" || true
