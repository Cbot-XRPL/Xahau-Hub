#!/usr/bin/env bash
# ops/host-run.sh — run a host-side script ON pve2 and leave NOTHING behind.
#
# Some operations genuinely require the Proxmox host: creating a VM, attaching
# a disk, reading the thin pool. Those scripts call guard_require_host, so they
# refuse to run from a workstation. The WRONG way to satisfy that is to keep a
# permanent copy of this repo on the host — that is how a provisioning tool
# quietly becomes a resident agent on a hypervisor it does not own.
#
# This runner instead:
#   1. mktemp -d on the host (0700, under /tmp, so a reboot also clears it)
#   2. rsyncs only what a host-side script needs — NEVER secrets/seeds.env
#   3. runs the script there with XAH_REPO_ROOT pointed at the staging dir
#   4. removes the staging dir on ANY exit path, success or failure
#
# The host therefore holds this repo for the duration of one command and not a
# second longer: no /opt install, no cron, no systemd unit, no repo copy.
#
# Usage:
#   ops/host-run.sh provision/10-create-vm.sh xah-node-1 --mode cloudinit
#   ops/host-run.sh provision/01-space-check.sh
#   ops/host-run.sh --keep provision/05-host-prep.sh      # leave the dir for debugging
#   ops/host-run.sh --print                               # show what would be staged
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

KEEP=0; PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)    KEEP=1; shift ;;
    --print)   PRINT=1; shift ;;
    -h|--help) sed -n '2,/^set -E/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)        shift; break ;;
    -*)        die "unknown option: $1" ;;
    *)         break ;;
  esac
done

# Staged, in dependency order. secrets/ is deliberately absent: a node_seed has
# no business on the hypervisor, and host-side scripts never need one.
STAGED=(lib provision config ops cluster inventory.yml)

if [ "$PRINT" = 1 ]; then
  hdr "would stage to a temp dir on the host"
  printf '  %s\n' "${STAGED[@]}"
  info "plus secrets/guest-keys.pub (public keys only) if present"
  warn "NEVER staged: secrets/seeds.env, out/ (rendered configs carry seeds)"
  exit 0
fi

[ $# -gt 0 ] || die "usage: $0 SCRIPT [args...]   (e.g. $0 provision/01-space-check.sh)"

SCRIPT_REL="$1"; shift
case "$SCRIPT_REL" in
  /*) die "give a repo-relative path, not an absolute one: $SCRIPT_REL" ;;
  *..*) die "refusing a path containing '..': $SCRIPT_REL" ;;
esac
[ -f "$REPO_ROOT/$SCRIPT_REL" ] || die "no such script in this repo: $SCRIPT_REL"

HOST_NAME="$("$INV" get cluster.host.name)"
HOST_ADDR="$("$INV" get cluster.host.address)"
HOST_USER="$("$INV" get cluster.host.ssh_user)"
guard_reject_target "$HOST_NAME" "$HOST_ADDR"
TARGET="${HOST_USER}@${HOST_ADDR}"

# Already standing on the host? Then there is nothing to stage.
if [ "$(hostname -s)" = "$HOST_NAME" ]; then
  info "already on $HOST_NAME — running in place, nothing staged"
  exec "$REPO_ROOT/$SCRIPT_REL" "$@"
fi

hdr "$SCRIPT_REL on $HOST_NAME ($HOST_ADDR)"
need rsync

xssh "$TARGET" true || die "cannot ssh to $TARGET"
STAGE="$(xssh "$TARGET" 'd=$(mktemp -d /tmp/xahau-hub.XXXXXXXX) && chmod 700 "$d" && printf %s "$d"')"
case "$STAGE" in
  /tmp/xahau-hub.*) : ;;
  *) die "refusing to use an unexpected staging path: '$STAGE'" ;;
esac

# Removed on success, failure, or Ctrl-C. The one thing this script must never
# do is leave the repo sitting on the hypervisor.
cleanup() {
  local rc=$?
  if [ "$KEEP" = 1 ]; then
    warn "--keep: staging dir left at ${TARGET}:$STAGE — remove it when you are done"
  else
    xssh "$TARGET" "rm -rf -- '$STAGE'" >/dev/null 2>&1 \
      && info "staging dir removed from $HOST_NAME" \
      || err "could NOT remove ${TARGET}:$STAGE — remove it by hand"
  fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT

info "staging ${STAGED[*]} -> ${TARGET}:$STAGE"
xrsync -a --delete \
  --exclude '__pycache__' --exclude '*.pyc' --exclude 'rendered' \
  "${STAGED[@]/#/$REPO_ROOT/}" "${TARGET}:$STAGE/" >/dev/null

# Public keys are not secrets, and 10-create-vm.sh needs them to make a cloud
# image reachable at all. This is the ONLY thing from secrets/ that is staged.
if [ -f "$REPO_ROOT/secrets/guest-keys.pub" ]; then
  xscp "$REPO_ROOT/secrets/guest-keys.pub" "${TARGET}:$STAGE/guest-keys.pub" >/dev/null
  info "staged guest-keys.pub ($(grep -c . "$REPO_ROOT/secrets/guest-keys.pub") key(s))"
fi

hdr "running"
set +e
xssh "$TARGET" \
  "cd '$STAGE' && XAH_REPO_ROOT='$STAGE' XAH_YES='${XAH_YES:-0}' bash '$STAGE/$SCRIPT_REL' $(printf '%q ' "$@")"
RC=$?
set -e
[ "$RC" = 0 ] || err "$SCRIPT_REL exited $RC on $HOST_NAME"
exit "$RC"
