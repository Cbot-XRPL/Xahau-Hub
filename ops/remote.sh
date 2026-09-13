#!/usr/bin/env bash
# ops/remote.sh — run one of this repo's scripts ON a node, through the guards.
#
# The node already has the tooling at /opt/xahau-hub (ops/deploy-node.sh puts
# it there). This wires up XAH_REPO_ROOT and XAH_NODE so the remote script
# resolves the right node, and routes the ssh through guard_reject_target so a
# typo can never become a connection to the validator host.
#
# Usage:
#   ops/remote.sh NODE -- ops/prune-guard.sh --status
#   ops/remote.sh NODE -- provision/20-guest-bootstrap.sh
#   ops/remote.sh --all -- ops/growth-watch.sh --mode guest
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

NODES=(); SEEN_SEP=0; CMD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) SEEN_SEP=1; shift; CMD=("$@"); break ;;
    --all) mapfile -t NODES < <("$INV" nodes --enabled); shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) NODES+=("$1"); shift ;;
  esac
done
[ "$SEEN_SEP" = 1 ] || die "usage: $0 NODE -- SCRIPT [args...]   (the -- is required)"
[ "${#CMD[@]}" -gt 0 ] || die "nothing to run after --"
[ "${#NODES[@]}" -gt 0 ] || die "no node given (use a node name or --all)"

RC=0
for node in "${NODES[@]}"; do
  node="$(resolve_node "$node")"
  node_env "$node"
  [ "${#NODES[@]}" -gt 1 ] && hdr "$node"
  # The remote path is the tooling dir, not this repo's path.
  remote="${CMD[0]}"
  case "$remote" in /*) : ;; *) remote="$N_OPS_DIR/$remote" ;; esac
  rest=("${CMD[@]:1}")
  # printf runs its format once even with no arguments, so `printf '%q ' ` on an
  # empty array yields "'' " — one empty argument the remote script then has to
  # reject. Build the argument string only when there actually are arguments.
  argstr=""
  [ "${#rest[@]}" -gt 0 ] && argstr="$(printf '%q ' "${rest[@]}")"
  node_ssh "$node" \
    "XAH_REPO_ROOT=$N_OPS_DIR XAH_NODE=$node XAH_YES=${XAH_YES:-0} $remote $argstr" \
    || { err "$node: $remote exited non-zero"; RC=1; }
done
exit "$RC"
