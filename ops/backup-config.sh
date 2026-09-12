#!/usr/bin/env bash
# ops/backup-config.sh — back up configuration and an INVENTORY OF SEEDS.
#                        Never the seeds themselves.
#
# What goes in:  inventory.yml, the template, role files, validators.txt, the
#                cluster fragments + pubkeys.tsv, each node's DEPLOYED
#                xahaud.cfg with its [node_seed] REDACTED, crontabs, fstab,
#                lvm/VM layout, and a manifest saying WHICH seed variable
#                belongs to which node and what its pubkey_node is.
#
# What stays out: every seed value. Seeds live in secrets/seeds.env and in a
#                 password manager. A backup that contains them turns one lost
#                 laptop into a cluster-wide identity compromise.
#
# The archive is scanned before it is written, and the script aborts if
# anything that looks like a family seed survived the redaction.
#
# Usage: ops/backup-config.sh [--out DIR] [--local] [--keep N]
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

OUTDIR="$REPO_ROOT/backups"; LOCAL=0; KEEP=14
while [ $# -gt 0 ]; do
  case "$1" in
    --out)  OUTDIR="$2"; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --keep) KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BASE="$WORK/xahau-hub-config-$STAMP"
mkdir -p "$BASE"/{repo,nodes,host}
mkdir -p "$OUTDIR"

REDACT='s/^s[1-9A-HJ-NP-Za-km-z]\{20,\}[[:space:]]*$/<<REDACTED NODE SEED — see secrets\/seeds.env>>/'

hdr "backup $STAMP"

# ── repo-side configuration ─────────────────────────────────────────────────
install -m 644 "$REPO_ROOT/inventory.yml"            "$BASE/repo/inventory.yml"
install -m 644 "$REPO_ROOT/config/xahaud.cfg.j2"     "$BASE/repo/xahaud.cfg.j2"
install -m 644 "$REPO_ROOT/config/validators.txt"    "$BASE/repo/validators.txt"
mkdir -p "$BASE/repo/roles"; cp -a "$REPO_ROOT/config/roles/." "$BASE/repo/roles/"
if [ -d "$REPO_ROOT/cluster/rendered" ]; then
  mkdir -p "$BASE/repo/cluster"; cp -a "$REPO_ROOT/cluster/rendered/." "$BASE/repo/cluster/" 2>/dev/null || true
fi
ok "repo configuration captured"

# ── the seed MANIFEST — which variable belongs to which node. No values. ────
{
  echo "# xahau-hub seed manifest — $STAMP"
  echo "#"
  echo "# THIS FILE DELIBERATELY CONTAINS NO SEEDS."
  echo "# It records which seed variable belongs to which node, and the"
  echo "# resulting pubkey_node, so a seed restored from the password manager"
  echo "# can be matched back to the right node — and so a swapped or"
  echo "# duplicated identity is detectable after the fact."
  echo "#"
  printf '%-14s %-10s %-18s %-22s %s\n' node role address seed_variable pubkey_node
  while read -r n; do
    r="$("$INV" node "$n" role)"; a="$("$INV" node "$n" address)"; v="$("$INV" node "$n" seed_var)"
    if [ -n "${!v:-}" ]; then present="stored"; else present="MISSING-from-secrets.env"; fi
    pk="$(node_pubkey "$n" 2>/dev/null || echo unavailable)"
    printf '%-14s %-10s %-18s %-22s %s\n' "$n" "$r" "$a" "$v" "$pk"
    printf '%-14s %-10s %-18s %-22s %s\n' "" "" "" "  seed:$present" ""
  done < <("$INV" nodes --field name)
  echo ""
  echo "# Seeds are stored in: secrets/seeds.env (gitignored, mode 600) AND a"
  echo "# password manager. Generate with ops/gen-seed.sh (validation_create)."
  echo "# Every node's seed is unique. None is derived from any validator key."
} > "$BASE/SEED-MANIFEST.txt"
ok "seed manifest written (no seed values)"

# ── per-node live state ─────────────────────────────────────────────────────
grab() {   # grab NODE REMOTE_PATH LOCAL_NAME
  local n="$1" p="$2" name="$3" d="$BASE/nodes/$1"
  mkdir -p "$d"
  if [ "$LOCAL" = 1 ]; then
    [ -r "$p" ] && sed "$REDACT" "$p" > "$d/$name" || true
  else
    node_ssh "$n" "cat $p 2>/dev/null" 2>/dev/null | sed "$REDACT" > "$d/$name" || true
  fi
  [ -s "$d/$name" ] || rm -f "$d/$name"
}
grabcmd() { local n="$1" cmd="$2" name="$3" d="$BASE/nodes/$1"; mkdir -p "$d"
  if [ "$LOCAL" = 1 ]; then bash -c "$cmd" > "$d/$name" 2>/dev/null || true
  else node_ssh "$n" "$cmd" > "$d/$name" 2>/dev/null || true; fi
  [ -s "$d/$name" ] || rm -f "$d/$name"; }

while read -r n; do
  eval "$("$INV" node "$n")"
  info "collecting from $n"
  grab "$n" "$N_XAHAUD_CFG"                         xahaud.cfg.redacted
  grab "$n" "$N_XAHAUD_CFG_DIR/validators.txt"      validators.txt
  grab "$n" /etc/fstab                              fstab
  grab "$n" /etc/cron.d/xahau-hub                   cron.d-xahau-hub
  grab "$n" /etc/logrotate.d/xahaud                 logrotate-xahaud
  grab "$n" /etc/sysctl.d/60-xahaud.conf            sysctl-60-xahaud.conf
  grab "$n" "/etc/systemd/system/$N_XAHAUD_SERVICE.service.d/10-xahau-hub.conf" systemd-dropin.conf
  grabcmd "$n" "df -h $N_DB_MOUNT; echo; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT" disk-layout.txt
  grabcmd "$n" "curl -fsS --max-time 10 -H 'content-type: application/json' --data '{\"method\":\"server_info\",\"params\":[{}]}' http://127.0.0.1:$N_RPC_ADMIN/" server_info.json
  grabcmd "$n" "$N_XAHAUD_BIN --version 2>/dev/null | head -1" xahaud-version.txt
done < <("$INV" nodes --enabled)

# ── host-side layout ────────────────────────────────────────────────────────
info "collecting host layout from $("$INV" get cluster.host.name)"
hostgrab() { local cmd="$1" name="$2"
  if [ "$LOCAL" = 1 ] && [ -d /etc/pve ]; then bash -c "$cmd" > "$BASE/host/$name" 2>/dev/null || true
  else host_ssh "$cmd" > "$BASE/host/$name" 2>/dev/null || true; fi
  [ -s "$BASE/host/$name" ] || rm -f "$BASE/host/$name"; }
hostgrab "pvesm status" pvesm-status.txt
hostgrab "lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent,pool_lv" lvs.txt
hostgrab "vgs; pvs" vgs-pvs.txt
hostgrab "grep -E 'thin_pool_autoextend' /etc/lvm/lvm.conf" lvm-autoextend.txt
hostgrab "cat /etc/cron.d/xahau-hub-growth" cron.d-xahau-hub-growth.txt
while read -r v; do hostgrab "qm config $v" "qm-config-$v.txt"; done < <("$INV" nodes --field vmid)

# ── SCRUB CHECK — abort rather than ship a seed ─────────────────────────────
hdr "scrub check"
HITS="$(grep -rInE '(^|[^A-Za-z0-9/])s[1-9A-HJ-NP-Za-km-z]{25,}([^A-Za-z0-9]|$)' "$BASE" 2>/dev/null \
        | grep -vi 'REDACTED\|REPLACE\|EXAMPLE' || true)"
if [ -n "$HITS" ]; then
  err "something that looks like a seed survived redaction:"
  printf '%s\n' "$HITS" | head -10 >&2
  die "refusing to write the archive. Fix the redaction before backing up."
fi
grep -rIl 'REDACTED NODE SEED' "$BASE" >/dev/null 2>&1 && ok "node_seed values redacted in captured configs"
ok "no seed-shaped strings in the archive"

# ── write it ────────────────────────────────────────────────────────────────
TAR="$OUTDIR/xahau-hub-config-$STAMP.tar.gz"
tar -C "$WORK" -czf "$TAR" "$(basename "$BASE")"
chmod 600 "$TAR"
ok "wrote $TAR ($(du -h "$TAR" | cut -f1))"
tar -tzf "$TAR" | sed 's|^|  |' | head -40 >&2
[ "$(tar -tzf "$TAR" | wc -l)" -gt 40 ] && info "... $(tar -tzf "$TAR" | wc -l) entries total"

# ── retention ───────────────────────────────────────────────────────────────
mapfile -t OLD < <(ls -1t "$OUTDIR"/xahau-hub-config-*.tar.gz 2>/dev/null | tail -n +$(( KEEP + 1 )) || true)
if [ "${#OLD[@]}" -gt 0 ]; then rm -f "${OLD[@]}"; info "pruned ${#OLD[@]} archive(s), keeping $KEEP"; fi

cat >&2 <<NOTE

  This archive restores CONFIGURATION, not identity and not ledger data.
  To rebuild a node you also need:
    - its seed, from secrets/seeds.env or the password manager
    - its database, either from a peer (ops/seed-node.sh) or from the network
  backups/ is gitignored. Copy this archive somewhere off this host.
NOTE
