#!/usr/bin/env bash
# ops/deploy-node.sh — push a rendered config (and the ops tooling) to a node.
#
# Order matters. The config must be in place BEFORE the first start, because
# SQLite page_size only applies to a fresh database and fixing it later means
# `xahaud --vacuum` running for days on a history server.
#
#   1. render (unless --no-render)
#   2. pre-flight the rendered file: admin on 127.0.0.1, advisory_delete=1,
#      ledger_history < online_delete, a seed that is not any other node's
#   3. rsync lib/ ops/ config/ + inventory.yml to /opt/xahau-hub on the node
#   4. install xahaud.cfg mode 0600 owned by the xahaud user
#   5. restart and wait for the node to answer server_info again
#
# Usage: ops/deploy-node.sh NODE [--restart] [--wait] [--no-render]
#                                [--history initial|final] [--dry-run]
#                                [--tooling-only]
#
#   --bootstrap      deploy a TEMPORARY config with no [node_seed], so the node
#                    starts with a throwaway identity and can answer
#                    validation_create (which needs a running server). Re-deploy
#                    without it as soon as the real seed exists.
#   --tooling-only   sync lib/ ops/ config/ provision/ + inventory.yml only.
#                    Use this BEFORE the node has a seed — there is no config
#                    to render yet, and provision/20-guest-bootstrap.sh needs
#                    the tooling in place to run.
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"
load_secrets

NODE=""; RESTART=0; WAIT=0; RENDER=1; DRY=0; HISTORY=initial; TOOLING_ONLY=0; BOOTSTRAP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --restart)   RESTART=1; shift ;;
    --tooling-only) TOOLING_ONLY=1; RENDER=0; shift ;;
    --bootstrap)    BOOTSTRAP=1; shift ;;
    --wait)      WAIT=1; shift ;;
    --no-render) RENDER=0; shift ;;
    --history)   HISTORY="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE [--restart] [--wait]"
NODE="$(resolve_node "$NODE")"
node_env "$NODE"
guard_reject_target "$NODE" "$N_ADDRESS"

CFG_LOCAL="$REPO_ROOT/out/$NODE/xahaud.cfg"
VAL_LOCAL="$REPO_ROOT/out/$NODE/validators.txt"

hdr "deploy $NODE ($N_ADDRESS, role $N_ROLE)"

# ── 1. render ───────────────────────────────────────────────────────────────
if [ "$RENDER" = 1 ]; then
  if [ "$BOOTSTRAP" = 1 ]; then
    "$REPO_ROOT/config/render-config.sh" "$NODE" --history "$HISTORY" --bootstrap
  else
    "$REPO_ROOT/config/render-config.sh" "$NODE" --history "$HISTORY"
  fi
fi
if [ "$TOOLING_ONLY" = 0 ]; then
  [ -f "$CFG_LOCAL" ] || die "no rendered config at $CFG_LOCAL — run: make render NODE=$NODE
(If this node has no seed yet, sync the tooling first: ops/deploy-node.sh $NODE --tooling-only)"
fi

# ── 2. pre-flight the artefact ──────────────────────────────────────────────
if [ "$TOOLING_ONLY" = 1 ]; then
  hdr "tooling only — no config, no restart"
  node_ssh "$NODE" true || die "cannot ssh to $NODE ($N_ADDRESS)"
  node_ssh "$NODE" "mkdir -p $N_OPS_DIR/.state && chmod 700 $N_OPS_DIR"
  xrsync -a --delete \
    --exclude '.git' --exclude 'secrets' --exclude 'out' --exclude '.state' \
    --exclude 'cluster/rendered' --exclude 'docs' \
    "$REPO_ROOT/lib" "$REPO_ROOT/ops" "$REPO_ROOT/config" "$REPO_ROOT/provision" \
    "$REPO_ROOT/inventory.yml" \
    "${N_SSH_USER}@${N_ADDRESS}:$N_OPS_DIR/" >/dev/null
  node_ssh "$NODE" "chmod -R go-rwx $N_OPS_DIR"
  ok "synced lib/ ops/ config/ provision/ inventory.yml to $N_OPS_DIR"
  info "next: ops/remote.sh $NODE -- provision/20-guest-bootstrap.sh"
  exit 0
fi

hdr "pre-flight"
grep -qE '^\s*admin = 127\.0\.0\.1\s*$' "$CFG_LOCAL" || die "admin is not pinned to 127.0.0.1"
awk '/^\[port_rpc_admin_local\]/{f=1;next} /^\[/{f=0} f && /ip *= *0\.0\.0\.0/{exit 1}' "$CFG_LOCAL" \
  || die "admin RPC bound to 0.0.0.0 — refusing to deploy. Admin must never leave localhost."
grep -q '^advisory_delete=1$' "$CFG_LOCAL" || die "advisory_delete is not 1 — prune-guard.sh would never control pruning"
LH="$(awk '/^\[ledger_history\]/{getline; print; exit}' "$CFG_LOCAL")"
OD="$(awk -F= '/^online_delete=/{print $2; exit}' "$CFG_LOCAL")"
[ "$LH" -lt "$OD" ] || die "ledger_history ($LH) >= online_delete ($OD)"
ok "admin localhost-only, advisory_delete=1, ledger_history $LH < online_delete $OD"

# the seed in this file must be THIS node's and no one else's
if [ "$BOOTSTRAP" = 1 ]; then
  grep -q '^\[node_seed\]' "$CFG_LOCAL" && die "--bootstrap but the config carries a [node_seed]"
  warn "BOOTSTRAP DEPLOY: $NODE will run on a THROWAWAY identity from wallet.db."
  warn "Mint its real seed and redeploy before clustering it, seeding from it, or exposing it:"
  warn "  ops/gen-seed.sh --for $NODE --via $NODE --append && ops/deploy-node.sh $NODE --restart --wait"
  SKIP_SEED_CHECKS=1
fi
SEED_IN_CFG="$(awk '/^\[node_seed\]/{getline; print; exit}' "$CFG_LOCAL")"
[ -n "$SEED_IN_CFG" ] || [ "${SKIP_SEED_CHECKS:-0}" = 1 ] || die "rendered config has no seed"
[ "$SEED_IN_CFG" != "REPLACE_ME_UNIQUE_SEED_PER_NODE" ] || die "config was rendered with --no-seed. Mint one: ops/gen-seed.sh --for $NODE --append"
while read -r other; do
  [ "${SKIP_SEED_CHECKS:-0}" = 1 ] && break
  [ "$other" = "$NODE" ] && continue
  ov="$("$INV" node "$other" seed_var)"
  [ "$SEED_IN_CFG" = "${!ov:-__none__}" ] \
    && die "GUARD: the config for $NODE carries ${other}'s seed. Two nodes with one identity. Re-mint and re-render."
done < <("$INV" nodes --field name)
[ "${SKIP_SEED_CHECKS:-0}" = 1 ] && warn "seed checks SKIPPED (bootstrap config)" || ok "seed is unique to $NODE"

if [ "$DRY" = 1 ]; then
  info "--dry-run: would install $CFG_LOCAL -> $N_ADDRESS:$N_XAHAUD_CFG"
  sed 's/^s[1-9A-HJ-NP-Za-km-z]\{20,\}$/<<REDACTED>>/' "$CFG_LOCAL" | grep -vE '^\s*#|^\s*$' >&2
  exit 0
fi

node_ssh "$NODE" true || die "cannot ssh to $NODE ($N_ADDRESS)"

# ── 3. ops tooling ──────────────────────────────────────────────────────────
hdr "ops tooling -> $N_OPS_DIR"
node_ssh "$NODE" "mkdir -p $N_OPS_DIR/.state && chmod 700 $N_OPS_DIR"
xrsync -a --delete \
  --exclude '.git' --exclude 'secrets' --exclude 'out' --exclude '.state' \
  --exclude 'cluster/rendered' --exclude 'docs' \
  "$REPO_ROOT/lib" "$REPO_ROOT/ops" "$REPO_ROOT/config" "$REPO_ROOT/provision" \
  "$REPO_ROOT/inventory.yml" \
  "${N_SSH_USER}@${N_ADDRESS}:$N_OPS_DIR/" >/dev/null
node_ssh "$NODE" "chmod -R go-rwx $N_OPS_DIR"
ok "synced lib/ ops/ config/ provision/ inventory.yml"

# ── 4. the config ───────────────────────────────────────────────────────────
hdr "config -> $N_XAHAUD_CFG"
STAGE="/root/.xahau-hub-stage"
node_ssh "$NODE" "mkdir -p $STAGE && chmod 700 $STAGE"
xscp "$CFG_LOCAL" "${N_SSH_USER}@${N_ADDRESS}:$STAGE/xahaud.cfg" >/dev/null
xscp "$VAL_LOCAL" "${N_SSH_USER}@${N_ADDRESS}:$STAGE/validators.txt" >/dev/null
node_ssh "$NODE" "bash -s" <<REMOTE
set -Eeuo pipefail
id -u $N_XAHAUD_USER >/dev/null 2>&1 || { echo "user $N_XAHAUD_USER missing — run provision/20-guest-bootstrap.sh first" >&2; exit 1; }
mkdir -p $N_XAHAUD_CFG_DIR
# root owns it so the daemon cannot rewrite its own config; the xahaud group
# needs r-x to traverse in and read the file.
chown root:$N_XAHAUD_USER $N_XAHAUD_CFG_DIR
chmod 750 $N_XAHAUD_CFG_DIR
if [ -f $N_XAHAUD_CFG ]; then
  cp -a $N_XAHAUD_CFG ${N_XAHAUD_CFG}.bak.\$(date -u +%Y%m%d%H%M%S)
  ls -1t ${N_XAHAUD_CFG}.bak.* 2>/dev/null | tail -n +11 | xargs -r rm -f
fi
install -o $N_XAHAUD_USER -g $N_XAHAUD_USER -m 600 $STAGE/xahaud.cfg $N_XAHAUD_CFG
install -o $N_XAHAUD_USER -g $N_XAHAUD_USER -m 644 $STAGE/validators.txt $N_XAHAUD_CFG_DIR/validators.txt
rm -rf $STAGE
grep -q '^advisory_delete=1\$' $N_XAHAUD_CFG || { echo "deployed config lost advisory_delete=1" >&2; exit 1; }
# The daemon runs as $N_XAHAUD_USER, so prove THAT user can actually read it.
# Checking as root proves nothing: root can read a config the daemon cannot,
# and the failure mode is a crash loop with a misleading "cannot create db".
runuser -u $N_XAHAUD_USER -- test -r $N_XAHAUD_CFG \
  || { echo "user $N_XAHAUD_USER CANNOT read $N_XAHAUD_CFG — check the mode on $N_XAHAUD_CFG_DIR" >&2; exit 1; }
echo "installed \$(stat -c '%U:%G %a' $N_XAHAUD_CFG) $N_XAHAUD_CFG (readable by $N_XAHAUD_USER)"
REMOTE
ok "config installed (previous version kept as .bak.*)"

# ── 5. restart ──────────────────────────────────────────────────────────────
if [ "$RESTART" = 1 ]; then
  hdr "restart"
  WAS_RUNNING=0
  node_ssh "$NODE" "systemctl is-active --quiet $N_XAHAUD_SERVICE" && WAS_RUNNING=1 || true
  if [ "$WAS_RUNNING" = 1 ]; then
    info "stopping (NuDB flushes on shutdown — TimeoutStopSec is 600)"
    node_ssh "$NODE" "systemctl stop $N_XAHAUD_SERVICE"
  fi
  node_ssh "$NODE" "systemctl enable --now $N_XAHAUD_SERVICE"
  ok "$N_XAHAUD_SERVICE started"

  if [ "$WAIT" = 1 ]; then
    info "waiting for server_info to answer"
    for i in $(seq 1 60); do
      if si="$(node_info "$NODE")" && [ -n "$si" ]; then
        st="$(rpc_field "$si" info.server_state || echo '?')"
        cl="$(rpc_field "$si" info.complete_ledgers || echo '?')"
        ok "$NODE is answering: server_state=$st complete_ledgers=$cl"
        break
      fi
      sleep 5
      [ "$i" = 60 ] && { err "$NODE did not answer server_info within 5 minutes"
        node_ssh "$NODE" "journalctl -u $N_XAHAUD_SERVICE -n 40 --no-pager" >&2 || true
        die "deploy to $NODE failed to come back up"; }
    done
  fi
fi

hdr "done"
info "verify:  ops/healthcheck.sh $NODE"
info "prune:   ops/remote.sh $NODE -- ops/prune-guard.sh --status"
