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
# Edit a COPY of inventory.yml, not the role file. A node entry can override
# ledger_history (xah-node-2 and xah-node-1 both carry temporary shed
# overrides), and node fields beat role fields — so raising the value in
# deep.yml silently changed nothing and the test passed a config it should
# have refused. Test the effective value, which is what the guard reads.
BADINV2="$(mktemp)"
python3 - "$XAH_REPO_ROOT/inventory.yml" > "$BADINV2" <<'PYEOF'
import re, sys
out, in_node = [], False
for line in open(sys.argv[1]):
    if re.match(r"^  - name: xah-node-1\s*$", line): in_node = True
    elif re.match(r"^  - name: ", line): in_node = False
    # INSERT the override rather than editing an existing one. Editing assumed
    # a node-level ledger_history line exists, which is only true while a
    # temporary shed override is in place — so the test silently stopped
    # testing anything the moment those were removed. Inserting works either
    # way, because node fields beat role fields regardless.
    out.append(line)
    if in_node and re.match(r"^    name: |^  - name: xah-node-1", line):
        out.append("    ledger_history: 9000000\n")
        out.append("    ledger_history_initial: 9000000\n")
        in_node = False
sys.stdout.write("".join(out))
PYEOF
refuses "ledger_history >= online_delete" \
  env XAH_INVENTORY="$BADINV2" "$XAH_REPO_ROOT/config/render-config.sh" xah-node-1 --no-seed --out /tmp/badrender
allows "the real inventory still renders" \
  "$XAH_REPO_ROOT/config/render-config.sh" xah-node-1 --no-seed --out /tmp/okrender
rm -rf "$BADINV2" /tmp/badrender /tmp/okrender

echo
echo "── the pool math counts volumes this repo did not create ────────"

# The check used to hardcode ai-hub's 400 GiB as the only foreign allocation,
# so building PBS (CT 113, 192 GiB) left it reporting headroom that was not
# there. Every foreign volume must appear in the ledger and in the total.
allows "every existing_allocation shows in the ledger" bash -c '
  set -e; cd "$XAH_REPO_ROOT"
  out="$(python3 lib/inventory.py check)"
  for v in $(python3 lib/inventory.py get cluster.host.existing_allocations \
             | grep -oE "vm-[0-9]+-disk-[0-9]+"); do
    echo "$out" | grep -q "$v" || { echo "missing $v from the ledger"; exit 1; }
  done'

allows "provisioned total includes the existing allocations" bash -c '
  set -e; cd "$XAH_REPO_ROOT"
  python3 - <<PYMATH
import sys, re, subprocess
sys.path.insert(0, "lib")
import inventory
d = inventory.load()
ex = sum(int(a["gib"]) for a in inventory.dig(d, "cluster.host.existing_allocations"))
nodes = [n for n in inventory.dig(d, "nodes") if n.get("enabled")]
pool = inventory.dig(d, "cluster.host.storage")
nd = sum(int(n["root_gib"]) for n in nodes if n.get("storage") == pool) \
   + sum(int(n["db_gib"]) for n in nodes if n.get("db_storage") == pool)
out = subprocess.run([sys.executable, "lib/inventory.py", "check"],
                     capture_output=True, text=True).stdout
m = re.search(r"(\d+) GiB\s+TOTAL PROVISIONED", out)
assert m, "no TOTAL PROVISIONED line"
got, want = int(m.group(1)), ex + nd
assert got == want, "check says %d GiB, allocations + nodes = %d GiB" % (got, want)
PYMATH'

# Overcommit is the operator's hard rule and stays fatal, unlike the softer
# reserve target which only warns.
refuses "an existing allocation that overcommits the pool" bash -c '
  cd "$XAH_REPO_ROOT"
  BAD="$(mktemp)"
  python3 - "$BAD" <<PYBAD
import sys
src = open("inventory.yml").read()
src = src.replace(
    "    existing_allocations:\n",
    "    existing_allocations:\n      - { volume: vm-999-disk-0, gib: 9000, owner: \"probe\" }\n",
    1)
open(sys.argv[1], "w").write(src)
PYBAD
  XAH_INVENTORY="$BAD" python3 lib/inventory.py check >/dev/null 2>&1
  rc=$?; rm -f "$BAD"; exit $rc'

echo
echo "── the pool math respects the 2x rotation peak ───────────────────"

# online_delete is a rotation INTERVAL: NuDB keeps a writable AND an archive
# backend, so disk peaks at 2x it. ledger_history was checked against the
# volume from the start; online_delete was not, and that peak is what filled
# xah-node-1 to 94%.
refuses "an online_delete whose 2x peak exceeds the volume" bash -c '
  cd "$XAH_REPO_ROOT"
  BAK="$(mktemp)"; cp config/roles/deep.yml "$BAK"
  sed -i "s/^online_delete: [0-9]*$/online_delete: 400000/" config/roles/deep.yml
  python3 lib/inventory.py check >/dev/null 2>&1
  rc=$?; cp "$BAK" config/roles/deep.yml; rm -f "$BAK"; exit $rc'

allows "the shipped online_delete fits with room to spare" bash -c '
  cd "$XAH_REPO_ROOT"
  out="$(python3 lib/inventory.py check 2>&1)" || exit 1
  echo "$out" | grep -q "online_delete.*peaks at" && { echo "shipped value already warns"; exit 1; }
  exit 0'

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
# Point the monitoring node's ADDRESS at the Proxmox host and confirm
# install.sh refuses. Testing by setting monitoring.node to "pve2" would pass
# for the wrong reason — resolve_node rejects any name that is not a declared
# node, so it would never reach the containment guard being tested.
PVE_ADDR="$("$INV" get cluster.host.address)"
BADINV="$(mktemp)"
python3 - "$XAH_REPO_ROOT/inventory.yml" "$PVE_ADDR" > "$BADINV" <<'PYEOF'
import re, sys
src, pve = sys.argv[1], sys.argv[2]
out, in_node = [], False
for line in open(src):
    if re.match(r"^  - name: xah-node-1\s*$", line):
        in_node = True
    elif re.match(r"^  - name: ", line):
        in_node = False
    if in_node and re.match(r"^    address: ", line):
        line = "    address: %s\n" % pve
    out.append(line)
sys.stdout.write("".join(out))
PYEOF
refuses "installing the dashboard on a node whose address IS the hypervisor" \
  env XAH_INVENTORY="$BADINV" "$XAH_REPO_ROOT/dashboard/install.sh" --status
rm -f "$BADINV"

# And the configured target must be a real, declared node — not the host.
allows "monitoring.node names a declared node" bash -c '
  n=$("$XAH_REPO_ROOT/lib/inventory.py" get cluster.monitoring.node)
  [ -n "$n" ] && "$XAH_REPO_ROOT/lib/inventory.py" nodes --field name | grep -qx "$n"'
allows "monitoring.node is not the Proxmox host" bash -c '
  n=$("$XAH_REPO_ROOT/lib/inventory.py" get cluster.monitoring.node)
  h=$("$XAH_REPO_ROOT/lib/inventory.py" get cluster.host.name)
  [ -n "$n" ] && [ "$n" != "$h" ]'

printf '\n── secure_gateway hygiene ──────────────────────────────────────\n'
"$XAH_REPO_ROOT/config/render-config.sh" xah-node-1 --no-seed --out /tmp/sgrender >/dev/null 2>&1
if [ -f /tmp/sgrender/xahaud.cfg ]; then
  allows  "secure_gateway on the public RPC port" bash -c '
    awk "/^\\[port_rpc_public\\]/{f=1;next} /^\\[/{f=0} f && /secure_gateway/{found=1} END{exit !found}" /tmp/sgrender/xahaud.cfg'
  allows  "secure_gateway on the public WS port" bash -c '
    awk "/^\\[port_ws_public\\]/{f=1;next} /^\\[/{f=0} f && /secure_gateway/{found=1} END{exit !found}" /tmp/sgrender/xahaud.cfg'
  refuses "secure_gateway on the ADMIN port" bash -c '
    awk "/^\\[port_rpc_admin_local\\]/{f=1;next} /^\\[/{f=0} f && /secure_gateway/{found=1} END{exit !found}" /tmp/sgrender/xahaud.cfg'
  refuses "admin directive on any public port" bash -c '
    awk "/^\\[port_(ws|rpc)_public\\]/{f=1;next} /^\\[/{f=0} f && /^admin *=/{found=1} END{exit !found}" /tmp/sgrender/xahaud.cfg'
fi
rm -rf /tmp/sgrender

printf '\n── host-side scripts refuse to run off-host ────────────────────\n'
if [ "$(hostname -s)" != "$("$INV" get cluster.host.name)" ]; then
  # Assert the script EXISTS first. A refuses() on a missing path passes for the
  # wrong reason — "command not found" is also a non-zero exit — so a renamed or
  # deleted script would silently turn this into a test of nothing.
  for s in provision/01-space-check.sh provision/05-host-check.sh \
           provision/10-create-vm.sh provision/11-attach-db-disk.sh; do
    if [ -x "$REPO_ROOT/$s" ]; then
      refuses "$(basename "$s") off-host" "$REPO_ROOT/$s"
    else
      printf '  \033[31mFAIL\033[0m  %s is missing or not executable — the off-host guard is untested\n' "$s"
      FAIL=$((FAIL+1))
    fi
  done
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
