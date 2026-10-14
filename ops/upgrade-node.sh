#!/usr/bin/env bash
# ops/upgrade-node.sh — move ONE node to the pinned xahaud release, verifiably.
#
# Why a script and not "run the installer": the official installer pulls
# whatever build.xahau.tech serves, swaps the /opt/xahaud/bin/xahaud symlink,
# checks nothing, and refuses to run while xahaud is up. This instead:
#   1. takes the target from inventory.yml (or --version)
#   2. downloads the binary to /opt/xahaud/downloads WHILE the old build
#      keeps serving, and checks it against the GitHub release sha256 AND
#      the build server's releaseinfo md5 AND its own --version
#   3. only then stops, swaps the symlink, starts - one restart of downtime
#   4. waits for server_state=full and asserts build_version == target;
#      any failure after the stop reverts the symlink and restarts the old build
#
# Releases that carry amendments are a deadline, not a nicety: once an
# amendment this build does not know activates, the old binary exits with
# "XAHAUD STOPPED: UPGRADE REQUIRED". Upgrade the non-public node first, then
# the public one behind ops/public-failover.sh.
#
# Usage: ops/upgrade-node.sh NODE [--version V] [--sha256 S] [--md5 M]
#                                 [--dry-run] [--no-restart]
#   --dry-run     download and VERIFY the binary into /opt/xahaud/downloads,
#                 touch nothing else. The node keeps running the old build and
#                 the symlink is not moved; a later real run reuses the file.
set -Eeuo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
. "$REPO_ROOT/lib/rpc.sh"

NODE=""; VERSION=""; SHA=""; MD5=""; DRY=0; NORESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version)    VERSION="$2"; shift 2 ;;
    --sha256)     SHA="$2"; shift 2 ;;
    --md5)        MD5="$2"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --no-restart) NORESTART=1; shift ;;
    -*)           die "unknown flag: $1" ;;
    *)            NODE="$1"; shift ;;
  esac
done
[ -n "$NODE" ] || die "usage: $0 NODE [--version V] [--sha256 S] [--md5 M] [--dry-run]"
guard_reject_target "$NODE"                                        # say WHY before any lookup can fail
"$INV" node "$NODE" address >/dev/null 2>&1 || die "unknown node: $NODE (see inventory.yml nodes[])"

VERSION="${VERSION:-$("$INV" get cluster.defaults.xahaud_version)}"
SHA="${SHA:-$("$INV" get cluster.defaults.xahaud_sha256 2>/dev/null || true)}"
MD5="${MD5:-$("$INV" get cluster.defaults.xahaud_md5 2>/dev/null || true)}"
[ -n "$VERSION" ] || die "no target version: pass --version or set cluster.defaults.xahaud_version"
ENC="${VERSION//+/%2B}"                         # build.xahau.tech names files with %2B
BUILD_URL="https://build.xahau.tech/"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

remote() { node_ssh "$NODE" "$@"; }
remote_build() {   # build_version|server_state from the node's own admin port
  remote "curl -s --max-time 8 --data '{\"method\":\"server_info\",\"params\":[{}]}' http://127.0.0.1:5005/ \
    | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"result\"][\"info\"];print(d.get(\"build_version\",\"?\")+\"|\"+d.get(\"server_state\",\"?\")+\"|\"+str(d.get(\"complete_ledgers\",\"?\")))'" 2>/dev/null || echo "?|down|?"
}

hdr "upgrade $NODE -> $VERSION"

# ── 1. the target exists on the build server, and what its md5 should be ───
#  (The official installer is NOT used here. It refuses to run while xahaud
#  is up - it resolves /opt/xahaud/bin/xahaud through the symlink and decides
#  the daemon is "in the wrong place" - so using it would mean stopping the
#  node just to download. It is still what provisions a fresh node; for an
#  upgrade the only things it would do are fetch the file and move the
#  symlink, and doing those ourselves lets the download and every check
#  happen while the old build keeps serving.)
LISTING="$(curl -fsSL --max-time 60 "$BUILD_URL")" || die "cannot read $BUILD_URL"
# here-string, not a pipe: with pipefail, grep -q closing early makes echo
# report SIGPIPE and the whole check "fail" on a file that is present.
grep -qF -- "\"$ENC\"" <<<"$LISTING" || die "$VERSION is not on $BUILD_URL (file $ENC absent)"
RI_MD5="$(curl -fsSL --max-time 30 "${BUILD_URL}${ENC}.releaseinfo" | awk '/Build md5/{print $3}' || true)"
if [ -n "$MD5" ] && [ -n "$RI_MD5" ] && [ "$MD5" != "$RI_MD5" ]; then
  die "pinned md5 $MD5 disagrees with releaseinfo md5 $RI_MD5 — resolve before installing"
fi
MD5="${MD5:-$RI_MD5}"
ok "$VERSION present on build server (releaseinfo md5 ${RI_MD5:-unknown})"

# ── 2. where the node is now ───────────────────────────────────────────────
IFS='|' read -r CUR_BUILD CUR_STATE CUR_CL <<<"$(remote_build)"
CUR_LINK="$(remote "readlink /opt/xahaud/bin/xahaud" 2>/dev/null || echo '?')"
info "running: $CUR_BUILD ($CUR_STATE, $CUR_CL) | symlink: $CUR_LINK"
if [ "$CUR_BUILD" = "$VERSION" ]; then ok "$NODE already runs $VERSION"; exit 0; fi

# ── 3. stage the binary while the old one keeps running ────────────────────
BIN="/opt/xahaud/downloads/$ENC"
if remote "[ -s '$BIN' ]"; then
  info "already staged: $BIN"
else
  info "downloading $ENC to $NODE (~160 MB)"
  remote "curl -fsSL --max-time 900 '${BUILD_URL}${ENC}' -o '$BIN.part' && mv -f '$BIN.part' '$BIN'" || die "download failed"
fi
remote "chmod 0755 '$BIN' && chown xahaud:xahaud '$BIN'"

# ── 4. verify it BEFORE anything runs it ───────────────────────────────────
B_SHA="$(remote "sha256sum '$BIN' | cut -d' ' -f1")"
B_MD5="$(remote "md5sum '$BIN' | cut -d' ' -f1")"
if [ -n "$SHA" ]; then
  [ "$B_SHA" = "$SHA" ] || { remote "rm -f '$BIN'"; die "binary sha256 $B_SHA != pinned $SHA — removed, node untouched"; }
  ok "sha256 matches GitHub release"
else
  warn "no sha256 pinned — binary sha256 is $B_SHA (unverified)"
fi
if [ -n "$MD5" ]; then
  [ "$B_MD5" = "$MD5" ] || { remote "rm -f '$BIN'"; die "binary md5 $B_MD5 != releaseinfo $MD5 — removed, node untouched"; }
  ok "md5 matches build server releaseinfo"
fi
B_VER="$(remote "'$BIN' --version 2>/dev/null | head -1")"
case "$B_VER" in *"$VERSION"*) ok "binary reports: $B_VER" ;; *) remote "rm -f '$BIN'"; die "binary --version says '$B_VER', not $VERSION — removed" ;; esac

if [ "$DRY" = 1 ] || [ "$NORESTART" = 1 ]; then
  ok "staged and verified at $BIN. $NODE untouched: still runs $CUR_BUILD, symlink still $CUR_LINK."
  exit 0
fi

# ── 5. the only moment of downtime: stop, swap, start ──────────────────────
hdr "swap $NODE to $VERSION"
revert() { remote "ln -snf '$CUR_LINK' /opt/xahaud/bin/xahaud; systemctl start xahaud" || true; }
remote "systemctl stop xahaud"
remote "ln -snf '$BIN' /opt/xahaud/bin/xahaud" || { revert; die "symlink swap failed — reverted and restarted old build"; }
remote "systemctl start xahaud" || { revert; die "start failed — reverted to $CUR_LINK"; }

# ── 6. restart and prove it ────────────────────────────────────────────────
for i in $(seq 1 90); do
  sleep 10
  IFS='|' read -r B S CL <<<"$(remote_build)"
  [ $((i % 3)) -eq 0 ] && info "  t=$((i*10))s build=$B state=$S ledgers=$CL"
  if [ "$B" != "?" ] && [ "$B" != "$VERSION" ]; then revert; die "node came back on $B, not $VERSION — reverted"; fi
  [ "$S" = "full" ] && { ok "$NODE is full on $VERSION ($CL)"; exit 0; }
done
die "$NODE did not reach full within 15 min (last: build=$B state=$S) — investigate before touching the other node"
