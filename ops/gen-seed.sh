#!/usr/bin/env bash
# ops/gen-seed.sh — mint a UNIQUE node_seed with validation_create.
#
# Every node gets its own seed. Never reuse one. Never derive one from the
# validator's key — nothing in this repo has any access to CT 200 on the
# R730xd, and that is deliberate.
#
# validation_create is an RPC, so it needs a running xahaud to answer it. Any
# node in this cluster can mint a seed for any other; the seed it returns is
# unrelated to the node that generated it. If no node is up yet, bootstrap one
# without a seed (it will use a throwaway identity in wallet.db), mint here,
# then render + deploy the real config and restart.
#
# The seed is printed to stdout and, with --append, written to
# secrets/seeds.env — which is gitignored, mode 0600, and never backed up by
# ops/backup-config.sh.
#
# Usage:
#   ops/gen-seed.sh --for xah-node-2 [--via xah-node-1] [--append]
#   ops/gen-seed.sh --local --for xah-node-1 --append     # run on the node
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"

FOR=""; VIA=""; APPEND=0; LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --for)    FOR="$2"; shift 2 ;;
    --via)    VIA="$2"; shift 2 ;;
    --append) APPEND=1; shift ;;
    --local)  LOCAL=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$FOR" ] || die "--for NODE is required"
FOR="$(resolve_node "$FOR")"
node_env "$FOR"
SEED_VAR="$N_SEED_VAR"
SEEDS="$REPO_ROOT/secrets/seeds.env"

# already set? refuse to silently replace a live identity
load_secrets
if [ -n "${!SEED_VAR:-}" ]; then
  err "$SEED_VAR is already set in secrets/seeds.env."
  err "Replacing a node's seed changes its identity on the network: its pubkey_node changes,"
  err "every other node's [cluster_nodes] block goes stale, and you must re-run 'make cluster'."
  confirm "Mint a NEW seed for $FOR anyway?"
fi

hdr "minting a node_seed for $FOR"
if [ "$LOCAL" = 1 ]; then
  guard_require_guest
  OUT="$(rpc_local validation_create || true)"
else
  VIA="$(resolve_node "${VIA:-$FOR}")"
  guard_reject_target "$VIA"
  info "asking $VIA to run validation_create (admin RPC is localhost-only, so over ssh)"
  ADMIN_PORT="$("$INV" get cluster.ports.rpc_admin)"
  OUT="$(node_ssh "$VIA" "curl -fsS --max-time 20 -H 'content-type: application/json' --data '{\"method\":\"validation_create\",\"params\":[{}]}' http://127.0.0.1:${ADMIN_PORT}/" || true)"
fi

[ -n "$OUT" ] || die "validation_create returned nothing. Is xahaud running on ${VIA:-this node}, and is the admin port answering on 127.0.0.1?"

SEED="$(rpc_field "$OUT" validation_seed || true)"
PUB="$(rpc_field "$OUT" validation_public_key || true)"
[ -n "$SEED" ] || { printf '%s\n' "$OUT" | head -20 >&2; die "could not read validation_seed from the reply"; }

guard_seed_unique "$SEED" "$SEEDS"
if [ -f "$SEEDS" ] && grep -qF -- "$SEED" "$SEEDS"; then
  die "GUARD: that seed is already in secrets/seeds.env. Every node needs a UNIQUE node_seed — two nodes with one identity is one identity on the network. Re-run to get a different one."
fi

hdr "result"
printf '  node        %s\n' "$FOR"
printf '  variable    %s\n' "$SEED_VAR"
printf '  seed        %s\n' "$SEED"
printf '  derived key %s\n' "${PUB:-?}"
cat >&2 <<'NOTE'

  This is secret material. It is the node's identity on the network.
  Store it in a password manager as well as secrets/seeds.env — if it is lost
  the node simply gets a new identity, but a LEAKED seed lets someone else
  impersonate this node to its cluster peers.
NOTE

if [ "$APPEND" = 1 ]; then
  mkdir -p "$REPO_ROOT/secrets"; chmod 700 "$REPO_ROOT/secrets"
  if [ ! -f "$SEEDS" ]; then
    { echo "# xahau-hub node seeds — NEVER COMMIT. One unique seed per node."
      echo "# Generated with validation_create. See ops/gen-seed.sh."; } > "$SEEDS"
  fi
  # replace an existing line for this var rather than appending a duplicate
  if grep -qE "^${SEED_VAR}=" "$SEEDS"; then
    sed -i -E "s|^${SEED_VAR}=.*|${SEED_VAR}=${SEED}|" "$SEEDS"
  else
    printf '%s=%s\n' "$SEED_VAR" "$SEED" >> "$SEEDS"
  fi
  chmod 600 "$SEEDS"
  ok "wrote $SEED_VAR to secrets/seeds.env (mode 600, gitignored)"

  # paranoia: make sure git will not pick it up
  if git -C "$REPO_ROOT" check-ignore -q "$SEEDS" 2>/dev/null; then
    ok "git confirms secrets/seeds.env is ignored"
  else
    die "GIT IS NOT IGNORING secrets/seeds.env. Fix .gitignore before doing anything else."
  fi
  info "next: make render NODE=$FOR && make deploy NODE=$FOR"
else
  info "re-run with --append to write it to secrets/seeds.env"
fi
