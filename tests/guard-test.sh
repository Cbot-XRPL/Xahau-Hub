#!/usr/bin/env bash
# tests/guard-test.sh — prove the safety rails still refuse what they must.
#
# The most important property of this repo is negative: it CANNOT reach CT 200
# on the R730xd. That is a live UNL validator with its own RAID and its own
# keys. These tests fail the build if a guard stops refusing.
#
# Run: make guards
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export XAH_REPO_ROOT="$REPO_ROOT"
# shellcheck source=../lib/common.sh
. "$REPO_ROOT/lib/common.sh"

PASS=0; FAIL=0
_run() { ( "$@" ) >/dev/null 2>&1; }

refuses() {  # refuses "desc" cmd...
  local d="$1"; shift
  if _run "$@"; then printf '  \033[31mFAIL\033[0m  %s was ALLOWED and must be refused\n' "$d"; FAIL=$((FAIL+1))
  else printf '  \033[32mok\033[0m    refuses %s\n' "$d"; PASS=$((PASS+1)); fi
}
allows() {
  local d="$1"; shift
  if _run "$@"; then printf '  \033[32mok\033[0m    allows %s\n' "$d"; PASS=$((PASS+1))
  else printf '  \033[31mFAIL\033[0m  %s was REFUSED and must be allowed\n' "$d"; FAIL=$((FAIL+1)); fi
}

printf '\n── validator host is unreachable ───────────────────────────────\n'
refuses "root@pve"                    guard_reject_target root@pve
refuses "bare hostname pve"           guard_reject_target pve
refuses "pve.local"                   guard_reject_target pve.local
refuses "the R730xd address"          guard_reject_target "$("$INV" get cluster.forbidden.host_addresses | tr -d '[]" ' | cut -d, -f1)"
refuses "a URL pointing at pve"       guard_reject_target "https://pve:8006"
refuses "anything named ct200"        guard_reject_target ct200
refuses "anything named validator"    guard_reject_target validator-backup
refuses "anything named unl"          guard_reject_target unl-node

printf '\n── forbidden VMIDs ─────────────────────────────────────────────\n'
refuses "vmid 200 (UNL validator)"    guard_vmid 200
refuses "vmid 100 (NPM on pve / ai-hub on pve2)" guard_vmid 100

# The tripwire list is deliberately narrower than the forbidden list. VMID 100
# exists legitimately on pve2 (ai-hub), so treating its presence as proof of
# being on the validator host is a false positive that blocks all provisioning.
allows  "tripwire list excludes 100"  bash -c '! "$XAH_REPO_ROOT/lib/inventory.py" get cluster.forbidden.tripwire_vmids | grep -q 100'
allows  "tripwire list includes 200"  bash -c '"$XAH_REPO_ROOT/lib/inventory.py" get cluster.forbidden.tripwire_vmids | grep -q 200'
allows  "forbidden list still has 100" bash -c '"$XAH_REPO_ROOT/lib/inventory.py" get cluster.forbidden.vmids | grep -q 100' 
refuses "an undeclared vmid"          guard_vmid 999
refuses "a non-numeric vmid"          guard_vmid abc

printf '\n── our own nodes are reachable ─────────────────────────────────\n'
allows  "xah-node-1 by name"          guard_reject_target xah-node-1
allows  "xah-node-1 by address"       guard_reject_target root@192.168.1.110
allows  "pve2 (the build host)"       guard_reject_target pve2
allows  "vmid 110"                    guard_vmid 110
allows  "vmid 111"                    guard_vmid 111
allows  "vmid 112 (phase 2)"          guard_vmid 112

printf '\n── seed hygiene ────────────────────────────────────────────────\n'
refuses "a malformed seed"            guard_seed_unique "not-a-seed"
refuses "an empty seed"               guard_seed_unique ""
allows  "a well-formed seed"          guard_seed_unique "snoPBrXtMeMyMHUVTgbuqAfg1SUTb"

SEEDFILE="$(mktemp)"; printf 'A=snoPBrXtMeMyMHUVTgbuqAfg1SUTb\nB=snoPBrXtMeMyMHUVTgbuqAfg1SUTb\n' > "$SEEDFILE"
refuses "the same seed twice in one file" guard_seed_unique "snoPBrXtMeMyMHUVTgbuqAfg1SUTb" "$SEEDFILE"
rm -f "$SEEDFILE"

LEAK="$(mktemp)"; printf '[node_seed]\nsnoPBrXtMeMyMHUVTgbuqAfg1SUTb\n' > "$LEAK"
refuses "a file containing a real seed" guard_no_seed_in "$LEAK"
rm -f "$LEAK"
CLEAN="$(mktemp)"; printf '[node_seed]\nREPLACE_ME_UNIQUE_SEED_PER_NODE\n' > "$CLEAN"
allows  "a file with only a placeholder" guard_no_seed_in "$CLEAN"
rm -f "$CLEAN"

printf '\n── config invariants ───────────────────────────────────────────\n'
refuses "ledger_history >= online_delete" bash -c '
  set -e; cd "$XAH_REPO_ROOT"
  cp config/roles/deep.yml /tmp/deep.bak
  sed -i "s/^ledger_history_initial: .*/ledger_history_initial: 9000000/" config/roles/deep.yml
  ./config/render-config.sh xah-node-1 --no-seed --out /tmp/badrender
  rc=$?; cp /tmp/deep.bak config/roles/deep.yml; exit $rc'
cp /tmp/deep.bak "$REPO_ROOT/config/roles/deep.yml" 2>/dev/null || true
rm -rf /tmp/badrender /tmp/deep.bak

refuses "admin RPC bound to 0.0.0.0" bash -c '
  set -e; cd "$XAH_REPO_ROOT"
  cp config/xahaud.cfg.j2 /tmp/tpl.bak
  python3 - <<PY
import re
p="config/xahaud.cfg.j2"; s=open(p).read()
s=s.replace("""[port_rpc_admin_local]
port = {{ port_rpc_admin }}
ip = 127.0.0.1""","""[port_rpc_admin_local]
port = {{ port_rpc_admin }}
ip = 0.0.0.0""")
open(p,"w").write(s)
PY
  ./config/render-config.sh xah-node-1 --no-seed --out /tmp/badrender2
  rc=$?; cp /tmp/tpl.bak config/xahaud.cfg.j2; exit $rc'
cp /tmp/tpl.bak "$REPO_ROOT/config/xahaud.cfg.j2" 2>/dev/null || true
rm -rf /tmp/badrender2 /tmp/tpl.bak

allows "a correct render" bash -c 'cd "$XAH_REPO_ROOT" && ./config/render-config.sh xah-node-1 --no-seed --out /tmp/goodrender'
if [ -f /tmp/goodrender/xahaud.cfg ]; then
  allows "advisory_delete=1 in the rendered config" grep -q '^advisory_delete=1$' /tmp/goodrender/xahaud.cfg
  allows "admin pinned to 127.0.0.1"                grep -q '^admin = 127\.0\.0\.1$' /tmp/goodrender/xahaud.cfg
  refuses "any 0.0.0.0 admin binding"               grep -q 'admin = 0\.0\.0\.0' /tmp/goodrender/xahaud.cfg
  allows "use_tx_tables present"                    grep -q '^\[use_tx_tables\]' /tmp/goodrender/xahaud.cfg
fi
rm -rf /tmp/goodrender

printf '\n── the dashboard does not live on the Proxmox host ─────────────\n'
BADINV="$(mktemp)"
sed -E 's/^(    host: )ai-hub/\1pve2/; s/^(    host_address: )192\.168\.1\.66/\1192.168.1.120/' \
  "$XAH_REPO_ROOT/inventory.yml" > "$BADINV"
refuses "installing the dashboard on pve2" \
  env XAH_INVENTORY="$BADINV" "$XAH_REPO_ROOT/dashboard/install.sh" --status
allows  "monitoring.host is a VM, not the host" bash -c '
  h=$("$XAH_REPO_ROOT/lib/inventory.py" get cluster.monitoring.host)
  p=$("$XAH_REPO_ROOT/lib/inventory.py" get cluster.host.name)
  [ "$h" != "$p" ]'
rm -f "$BADINV"

printf '\n── host-side scripts refuse to run off-host ────────────────────\n'
if [ "$(hostname -s)" != "$("$INV" get cluster.host.name)" ]; then
  refuses "01-space-check.sh off-host"  "$REPO_ROOT/provision/01-space-check.sh"
  refuses "05-host-prep.sh off-host"    "$REPO_ROOT/provision/05-host-prep.sh"
else
  printf '  ..    skipped (running on the target host)\n'
fi

printf '\n── git will not commit secrets ─────────────────────────────────\n'
# A deployed copy (rsynced to a host or a node) has no .git, so check-ignore
# cannot run there. That is not a guard failure — skip rather than fail red.
if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '  ..    skipped (not a git work tree — deployed copy)\n'
else
mkdir -p "$REPO_ROOT/secrets"
printf 'X=1\n' > "$REPO_ROOT/secrets/.gitignore-probe"
allows "git ignores secrets/"        git -C "$REPO_ROOT" check-ignore -q "$REPO_ROOT/secrets/.gitignore-probe"
rm -f "$REPO_ROOT/secrets/.gitignore-probe"
mkdir -p "$REPO_ROOT/out/probe"; printf 'X\n' > "$REPO_ROOT/out/probe/xahaud.cfg"
allows "git ignores out/"            git -C "$REPO_ROOT" check-ignore -q "$REPO_ROOT/out/probe/xahaud.cfg"
rm -rf "$REPO_ROOT/out/probe"
fi

printf '\n%s\n' "$(printf '─%.0s' $(seq 1 64))"
printf '%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
