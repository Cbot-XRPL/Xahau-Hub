# shellcheck shell=bash
# lib/common.sh — bootstrap every script in this repo identically.
#   set -Eeuo pipefail, REPO_ROOT, log.sh, guard.sh, INV, secrets loading.

set -Eeuo pipefail

_self="$(readlink -f "${BASH_SOURCE[1]:-$0}")"

# Walk up from the sourcing script until the repo marker is found, so scripts
# work from any subdirectory depth and from any cwd. XAH_REPO_ROOT overrides.
_find_repo_root() {
  local d="${1:-$PWD}"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -f "$d/inventory.yml" ] && [ -x "$d/lib/inventory.py" ]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

if [ -n "${XAH_REPO_ROOT:-}" ]; then
  REPO_ROOT="$XAH_REPO_ROOT"
else
  REPO_ROOT="$(_find_repo_root "$(dirname "$_self")" || _find_repo_root "$PWD" || true)"
fi
[ -n "${REPO_ROOT:-}" ] && [ -f "$REPO_ROOT/inventory.yml" ] || {
  echo "common.sh: cannot locate repo root from $_self — set XAH_REPO_ROOT" >&2; exit 1; }
export REPO_ROOT

INV="$REPO_ROOT/lib/inventory.py"
export INV

# shellcheck source=lib/log.sh
. "$REPO_ROOT/lib/log.sh"
# shellcheck source=lib/guard.sh
. "$REPO_ROOT/lib/guard.sh"

trap 'err "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"' ERR

# ── secrets ──────────────────────────────────────────────────────────────────
# Never committed. seeds.env holds node_seed values; alerts.env holds webhook
# and telegram credentials. Both optional at load time; scripts that need a
# seed call require_seed and fail loudly.
load_secrets() {
  local f
  for f in "$REPO_ROOT/secrets/alerts.env" "$REPO_ROOT/secrets/seeds.env"; do
    if [ -f "$f" ]; then
      local mode; mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
      case "$mode" in 600|400) : ;; *) warn "$f is mode ${mode:-?} — chmod 600 it" ;; esac
      set -a; # shellcheck disable=SC1090
      . "$f"; set +a
    fi
  done
}

require_seed() {
  local var="${1:?require_seed needs a var name}"
  load_secrets
  local val="${!var:-}"
  [ -n "$val" ] || die "$var is not set. Mint a seed with ops/gen-seed.sh and store it in secrets/seeds.env (gitignored). Never reuse a seed, and never derive one from the validator's key."
  guard_seed_unique "$val"
  printf '%s' "$val"
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage_if_help() {
  case "${1:-}" in
    -h|--help|help)
      sed -n '2,/^$/p' "$_self" | sed 's/^# \{0,1\}//'
      exit 0 ;;
  esac
}

# ── resolve_node [explicit] ──────────────────────────────────────────────────
#  Which node am I / which node was asked for? Order: explicit arg, $XAH_NODE,
#  hostname. Dies with something actionable rather than guessing — a guest
#  script that silently picks the wrong node would render the wrong config or
#  prune the wrong window.
resolve_node() {
  local want="${1:-${XAH_NODE:-$(hostname -s)}}"
  guard_reject_target "$want"
  if "$INV" nodes --field name | grep -qx "$want"; then printf '%s' "$want"; return 0; fi
  if "$INV" nodes --field vmid | grep -qx "$want"; then printf '%s' "$want"; return 0; fi
  die "'$want' is not a node in inventory.yml (known: $("$INV" nodes --field name | tr '\n' ' ')).
Pass the node explicitly, or set XAH_NODE, or fix this machine's hostname to match its inventory entry."
}

# node_env NODE — export every N_* value for a node into the caller's shell.
node_env() { eval "$("$INV" node "$(resolve_node "${1:-}")")"; }
