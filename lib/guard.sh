# shellcheck shell=bash
# ══════════════════════════════════════════════════════════════════════════════
#  lib/guard.sh — HARD SAFETY RAILS. Source, do not execute.
#
#  The single most important rule in this repo:
#
#      CT 200 on `pve` (the R730xd) is a LIVE UNL VALIDATOR.
#      It has its own RAID and its own keys. Nothing here may touch it.
#
#  Every host-side and ssh-side operation calls into this file. The guards are
#  deliberately redundant — name check, address check, VMID check, and a
#  tripwire that detects being on the validator host at all by looking for a
#  forbidden guest's config on the local node.
# ══════════════════════════════════════════════════════════════════════════════

[ -n "${_XAH_GUARD_SOURCED:-}" ] && return 0
_XAH_GUARD_SOURCED=1

: "${REPO_ROOT:?guard.sh needs REPO_ROOT}"
# shellcheck source=lib/log.sh
. "$REPO_ROOT/lib/log.sh"

INV="$REPO_ROOT/lib/inventory.py"

_guard_list() { "$INV" get "cluster.forbidden.$1" 2>/dev/null | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true; }

guard_forbidden_hosts()     { _guard_list hosts; }
guard_forbidden_addresses() { _guard_list host_addresses; }
guard_forbidden_vmids()     { _guard_list vmids; }

# ── guard_reject_target <string...> ──────────────────────────────────────────
#  Refuse if any argument names a forbidden host, address, or VMID. Call this
#  with anything that could become an ssh destination, a qm/pct target, an
#  rsync endpoint or a URL.
guard_reject_target() {
  local arg needle
  for arg in "$@"; do
    [ -z "$arg" ] && continue
    local low; low="$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')"
    while read -r needle; do
      [ -z "$needle" ] && continue
      case "$low" in
        "$needle"|"$needle".*|*@"$needle"|*://"$needle"|*://"$needle":*|*@"$needle":*)
          die "GUARD: refusing to target '$arg' — '$needle' is the UNL validator host (R730xd / pve). This repo must never touch it." ;;
      esac
    done <<< "$(guard_forbidden_hosts)"
    while read -r needle; do
      [ -z "$needle" ] && continue
      case "$low" in
        *"$needle"*)
          die "GUARD: refusing to target '$arg' — $needle is the validator host address. This repo must never touch it." ;;
      esac
    done <<< "$(guard_forbidden_addresses)"
    case "$low" in
      *ct200*|*ct-200*|*validator*|*unl*)
        die "GUARD: refusing to target '$arg' — the name references the UNL validator." ;;
    esac
  done
}

# ── guard_vmid <vmid> ────────────────────────────────────────────────────────
#  A VMID is only usable if inventory.yml declares it AND it is not forbidden.
guard_vmid() {
  local vmid="${1:?guard_vmid needs a vmid}" f
  case "$vmid" in ''|*[!0-9]*) die "GUARD: '$vmid' is not a numeric VMID" ;; esac
  while read -r f; do
    [ -z "$f" ] && continue
    [ "$vmid" = "$f" ] && die "GUARD: VMID $vmid is on the forbidden list (UNL validator / NPM / existing builder VM). Refusing."
  done <<< "$(guard_forbidden_vmids)"
  "$INV" nodes --field vmid | grep -qx "$vmid" \
    || die "GUARD: VMID $vmid is not declared in inventory.yml. Add it there first — nothing in this repo provisions an undeclared guest."
  return 0
}

# ── guard_require_host [expected] ────────────────────────────────────────────
#  For scripts that run ON the Proxmox host. Refuses to run anywhere but pve2,
#  and trips hard if a forbidden guest's config is visible locally (which would
#  mean we are standing on the validator host).
guard_require_host() {
  local expect="${1:-$("$INV" get cluster.host.name)}"
  local me; me="$(hostname -s)"
  [ "$me" = "$expect" ] || die "GUARD: this script only runs on '$expect'. This machine is '$me'. Refusing."

  local f
  while read -r f; do
    [ -z "$f" ] && continue
    if [ -e "/etc/pve/lxc/$f.conf" ] || [ -e "/etc/pve/qemu-server/$f.conf" ]; then
      die "GUARD TRIPWIRE: guest $f exists on this node ($me). That should be impossible on '$expect' and strongly suggests this is the validator host. Refusing to continue."
    fi
  done <<< "$(guard_forbidden_vmids)"

  local a
  while read -r a; do
    [ -z "$a" ] && continue
    if ip -4 -o addr show 2>/dev/null | grep -qw "$a"; then
      die "GUARD TRIPWIRE: this machine holds forbidden address $a. Refusing to continue."
    fi
  done <<< "$(guard_forbidden_addresses)"

  command -v qm >/dev/null 2>&1 || die "qm not found — '$expect' should be a Proxmox VE node"
  return 0
}

# ── guard_require_guest ──────────────────────────────────────────────────────
#  For scripts that run INSIDE a node VM.
guard_require_guest() {
  local me; me="$(hostname -s)"
  guard_reject_target "$me"
  if command -v qm >/dev/null 2>&1 || [ -d /etc/pve ]; then
    die "GUARD: this script must run inside a node VM, but this looks like a Proxmox host ($me). Refusing."
  fi
  "$INV" nodes --field name 2>/dev/null | grep -qx "$me" || \
    warn "hostname '$me' is not in inventory.yml — continuing, but check you are on the right box"
  return 0
}

# ── xssh <target> <cmd...> / xscp <src> <dst> ────────────────────────────────
#  Guarded ssh/scp. Never bypass these in a script in this repo.
: "${XAH_SSH_OPTS:=-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}"

xssh() {
  local target="${1:?xssh needs a target}"; shift
  guard_reject_target "$target"
  # shellcheck disable=SC2086
  ssh $XAH_SSH_OPTS "$target" "$@"
}

xscp() {
  local a b
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    b="${a%%:*}"; [ "$b" != "$a" ] && guard_reject_target "$b"
  done
  # shellcheck disable=SC2086
  scp $XAH_SSH_OPTS "$@"
}

xrsync() {
  local a b
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    b="${a%%:*}"; [ "$b" != "$a" ] && guard_reject_target "$b"
  done
  rsync -e "ssh $XAH_SSH_OPTS" "$@"
}

# ── node_ssh <node-name> [cmd...] ────────────────────────────────────────────
node_ssh() {
  local node="${1:?node_ssh needs a node}"; shift
  local addr user
  addr="$("$INV" node "$node" address)"
  user="$("$INV" node "$node" ssh_user)"
  guard_reject_target "$node" "$addr"
  xssh "${user}@${addr}" "$@"
}

host_ssh() {
  local addr user
  addr="$("$INV" get cluster.host.address)"
  user="$("$INV" get cluster.host.ssh_user)"
  guard_reject_target "$addr"
  xssh "${user}@${addr}" "$@"
}

# ── guard_seed_unique <seed> [existing-file] ─────────────────────────────────
#  Two nodes sharing one node_seed is one identity on the network. Refuse.
guard_seed_unique() {
  local seed="${1:?guard_seed_unique needs a seed}"
  local file="${2:-$REPO_ROOT/secrets/seeds.env}"
  case "$seed" in
    s[1-9A-HJ-NP-Za-km-z]*) : ;;
    *) die "GUARD: '$seed' does not look like a family seed (expected s...)" ;;
  esac
  if [ -f "$file" ]; then
    local n
    n="$(grep -c -- "$seed" "$file" 2>/dev/null || true)"
    [ "${n:-0}" -gt 1 ] && die "GUARD: seed already appears $n times in $file — every node needs a UNIQUE node_seed."
  fi
  return 0
}

# ── guard_no_seed_in <file...> ───────────────────────────────────────────────
#  Refuse to commit/back up anything containing a real seed.
guard_no_seed_in() {
  local f hit
  for f in "$@"; do
    [ -f "$f" ] || continue
    hit="$(grep -nE '(^|[^A-Za-z0-9])s[1-9A-HJ-NP-Za-km-z]{25,}([^A-Za-z0-9]|$)' "$f" | grep -v 'EXAMPLE\|REPLACE\|xxxx' || true)"
    [ -n "$hit" ] && die "GUARD: $f appears to contain a real seed:
$hit
Refusing. Seeds live only in secrets/ (gitignored)."
  done
  return 0
}
