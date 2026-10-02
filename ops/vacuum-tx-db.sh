#!/usr/bin/env bash
# ops/vacuum-tx-db.sh — reclaim SQLite free pages on a node, safely.
#
# WHY THIS EXISTS
#   online_delete prunes rows from transaction.db and ledger.db, but SQLite
#   never returns the emptied pages to the filesystem. On xah-node-1 the file
#   reached 192.6 GiB holding 40.8 GiB of live data — 78% dead weight, and more
#   disk than the entire NuDB. A VACUUM took it to 40 GiB.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID
#   The role configs set sqlite_temp_store=file. With no SQLITE_TMPDIR, SQLite
#   writes its rebuild to /var/tmp — the 46 GiB ROOT disk, not the 700 GiB data
#   volume. It came within ~1 GiB of filling / before being killed. This script
#   always points the temp store at the data volume and refuses to start if
#   there is not room for it.
#
#   Also: VACUUM writes the rebuild TWICE (temp copy, then back through the WAL
#   into the original), so budget ~2x the live size, and expect the file to stay
#   at its old size until the very last moment.
#
# Usage: ops/vacuum-tx-db.sh NODE [--db transaction|ledger|both] [--dry-run]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODE=""; WHICH="transaction"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --db)      WHICH="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -*)        die "unknown flag: $1" ;;
    *)         NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE [--db transaction|ledger|both] [--dry-run]"

DBDIR=/var/lib/xahaud/db
TMPDIR_REMOTE=/var/lib/xahaud/sqlite-tmp
case "$WHICH" in
  transaction) DBS="transaction.db" ;;
  ledger)      DBS="ledger.db" ;;
  both)        DBS="transaction.db ledger.db" ;;
  *)           die "--db must be transaction, ledger or both" ;;
esac

# node_ssh resolves the address from inventory and runs the guard itself.
remote() { node_ssh "$NODE" "$@"; }

hdr "bloat on $NODE"
for db in $DBS; do
  remote "sqlite3 $DBDIR/$db \"select printf('  %-16s live %.1f GiB of %.1f GiB (%.0f%% free pages)', '$db',
      (page_count-freelist_count)*page_size/1073741824.0,
      page_count*page_size/1073741824.0,
      100.0*freelist_count/page_count)
    from pragma_page_count, pragma_freelist_count, pragma_page_size;\"" || true
done

if [ "$DRY" = 1 ]; then log "dry run — nothing stopped, nothing vacuumed"; exit 0; fi

# Refuse if the data volume cannot hold two copies of the rebuild.
for db in $DBS; do
  NEED=$(remote "sqlite3 $DBDIR/$db \"select (page_count-freelist_count)*page_size*2 from pragma_page_count, pragma_freelist_count, pragma_page_size;\"")
  FREE=$(remote "df --output=avail -B1 $DBDIR | tail -1 | tr -d ' '")
  [ "$FREE" -gt "$NEED" ] || die "$db: needs ~$((NEED/1073741824)) GiB free (2x live size) and the volume has $((FREE/1073741824)) GiB"
  log "OK   $db: $((NEED/1073741824)) GiB needed, $((FREE/1073741824)) GiB free"
done

hdr "stopping xahaud on $NODE"
warn "this node leaves the cluster until the vacuum finishes — minutes to hours"
remote "systemctl stop xahaud"
remote "mkdir -p $TMPDIR_REMOTE"

hdr "vacuum (temp store forced onto the data volume)"
for db in $DBS; do
  log "$db — writes the rebuild twice; the file stays at its old size until the end"
  remote "cd $DBDIR && SQLITE_TMPDIR=$TMPDIR_REMOTE TMPDIR=$TMPDIR_REMOTE sqlite3 $db 'VACUUM;'"
  remote "ls -lh $DBDIR/$db | awk '{print \"  now: \" \$5}'"
done

hdr "starting xahaud"
remote "systemctl start xahaud"
log "waiting for server_state=full"
for _ in $(seq 1 60); do
  sleep 10
  S="$(remote "curl -s --max-time 8 --data '{\"method\":\"server_info\",\"params\":[{}]}' http://127.0.0.1:5005/ | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"result\"][\"info\"][\"server_state\"])'" 2>/dev/null || true)"
  log "  server_state=$S"
  [ "$S" = "full" ] && break
done
remote "df -h /var/lib/xahaud | tail -1"
log "done — confirm the window with ops/healthcheck.sh $NODE"
