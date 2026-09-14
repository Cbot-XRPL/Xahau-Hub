#!/usr/bin/env python3
"""
inventory.py — read inventory.yml without depending on PyYAML.

Proxmox hosts and freshly-installed Ubuntu guests may not have python3-yaml.
This uses PyYAML when it is importable and otherwise falls back to a parser
for the restricted YAML subset that inventory.yml is deliberately written in:
nested maps, lists of maps, lists of scalars, inline [a, b] flow lists,
'>-' folded block scalars, quoted/unquoted scalars and # comments.

Usage:
  inventory.py get cluster.host.name
  inventory.py get nodes.0.db_gib
  inventory.py node xah-node-1               # KEY=VALUE, shell-eval-safe
  inventory.py node 110                       # by VMID
  inventory.py nodes [--enabled] [--phase N] [--role deep]
  inventory.py json                           # whole document
  inventory.py role deep                      # merged role file + defaults
  inventory.py check                          # structural + no-overcommit math
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY = os.environ.get("XAH_INVENTORY", os.path.join(REPO, "inventory.yml"))


# ── minimal YAML ──────────────────────────────────────────────────────────────
def _scalar(tok):
    tok = tok.strip()
    if tok == "" or tok == "~" or tok.lower() == "null":
        return None
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    if tok.startswith("[") and tok.endswith("]"):
        body = tok[1:-1].strip()
        return [_scalar(p) for p in body.split(",")] if body else []
    low = tok.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    if re.fullmatch(r"-?\d+\.\d+", tok):
        return float(tok)
    return tok


def _strip_comment(line):
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def _mini_parse(text):
    # (indent, is_item, key, value_token) with block scalars pre-folded
    rows, lines = [], text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        i += 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        body = _strip_comment(raw)
        if not body.strip():
            continue
        indent = len(body) - len(body.lstrip(" "))
        s = body.strip()
        is_item = s.startswith("- ") or s == "-"
        if is_item:
            s = s[2:].strip() if s.startswith("- ") else ""
            indent += 2
        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*:\s*(.*)$", s)
        key, val = (m.group(1), m.group(2)) if m else (None, s)
        if val in (">", ">-", "|", "|-", "|+", ">+"):
            chunks = []
            while i < len(lines):
                nxt = lines[i]
                if not nxt.strip():
                    chunks.append("")
                    i += 1
                    continue
                nind = len(nxt) - len(nxt.lstrip(" "))
                if nind <= indent:
                    break
                chunks.append(nxt.strip())
                i += 1
            sep = "\n" if val.startswith("|") else " "
            val = sep.join(c for c in chunks if c != "").strip()
            val = '"%s"' % val.replace('"', "'")
        rows.append((indent, is_item, key, val))

    def build(pos, indent):
        # returns (value, next_pos)
        if pos >= len(rows):
            return None, pos
        if rows[pos][1]:  # list
            seq = []
            while pos < len(rows) and rows[pos][0] == indent and rows[pos][1]:
                ind, _, key, val = rows[pos]
                if key is None:
                    seq.append(_scalar(val))
                    pos += 1
                    continue
                item, pos = build_map_at(pos, ind, first_is_item=True)
                seq.append(item)
            return seq, pos
        return build_map_at(pos, indent)

    def build_map_at(pos, indent, first_is_item=False):
        node = {}
        while pos < len(rows):
            ind, is_item, key, val = rows[pos]
            if ind < indent:
                break
            if ind == indent and is_item and not first_is_item:
                break
            if ind > indent:
                break
            if key is None:
                break
            pos += 1
            first_is_item = False
            if val == "":
                child_indent = rows[pos][0] if pos < len(rows) else indent
                if pos < len(rows) and child_indent > indent:
                    node[key], pos = build(pos, child_indent)
                else:
                    node[key] = None
            else:
                node[key] = _scalar(val)
        return node, pos

    doc, _ = build_map_at(0, 0)
    return doc


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # noqa

        return yaml.safe_load(text)
    except Exception:
        return _mini_parse(text)


def load():
    return load_yaml(INVENTORY)


# ── helpers ───────────────────────────────────────────────────────────────────
def dig(doc, dotted):
    cur = doc
    for part in dotted.split("."):
        if isinstance(cur, list):
            cur = cur[int(part)]
        elif isinstance(cur, dict):
            if part not in cur:
                die("no such key: %s" % dotted)
            cur = cur[part]
        else:
            die("no such key: %s" % dotted)
    return cur


def die(msg, code=2):
    sys.stderr.write("inventory: %s\n" % msg)
    sys.exit(code)


def find_node(doc, ident):
    ident = str(ident)
    for n in doc.get("nodes") or []:
        if n.get("name") == ident or str(n.get("vmid")) == ident:
            return n
    die("unknown node: %s (known: %s)" % (ident, ", ".join(str(n.get("name")) for n in doc.get("nodes") or [])))


def role_config(doc, role):
    path = os.path.join(REPO, "config", "roles", "%s.yml" % role)
    if not os.path.exists(path):
        die("no role file for role '%s' (expected %s)" % (role, path))
    return load_yaml(path) or {}


def emit_shell(mapping, prefix=""):
    out = []
    for k, v in mapping.items():
        if isinstance(v, (dict, list)):
            continue
        if v is None:
            v = ""
        if v is True:
            v = 1
        if v is False:
            v = 0
        out.append("%s%s=%s" % (prefix, str(k).upper(), shquote(str(v))))
    return "\n".join(out)


def shquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ── no-overcommit check ───────────────────────────────────────────────────────
def check(doc):
    problems, warnings = [], []
    host = dig(doc, "cluster.host")
    nodes = doc.get("nodes") or []

    names, vmids, addrs = set(), set(), set()
    for n in nodes:
        for field in ("name", "vmid", "role", "address", "root_gib", "db_gib", "seed_var"):
            if n.get(field) in (None, ""):
                problems.append("node %s is missing '%s'" % (n.get("name", "?"), field))
        for bucket, key, label in ((names, "name", "name"), (vmids, "vmid", "vmid"), (addrs, "address", "address")):
            v = n.get(key)
            if v in bucket:
                problems.append("duplicate %s: %s" % (label, v))
            bucket.add(v)
        if not os.path.exists(os.path.join(REPO, "config", "roles", "%s.yml" % n.get("role"))):
            problems.append("node %s has unknown role '%s'" % (n.get("name"), n.get("role")))

    forbidden_vmids = {int(v) for v in (dig(doc, "cluster.forbidden.vmids") or [])}
    for n in nodes:
        if int(n["vmid"]) in forbidden_vmids:
            problems.append("node %s uses FORBIDDEN vmid %s" % (n["name"], n["vmid"]))

    # ledger_history must stay below online_delete for every role in use
    for role in sorted({n["role"] for n in nodes}):
        rc = role_config(doc, role)
        lh, od = rc.get("ledger_history"), rc.get("online_delete")
        if isinstance(lh, int) and isinstance(od, int) and lh >= od:
            problems.append("role %s: ledger_history (%d) must be < online_delete (%d)" % (role, lh, od))
        lhi = rc.get("ledger_history_initial")
        if isinstance(lhi, int) and isinstance(od, int) and lhi >= od:
            problems.append("role %s: ledger_history_initial (%d) must be < online_delete (%d)" % (role, lhi, od))

    # ── does the requested history physically fit its volume? ────────────────
    #  Every original value was 1.7x to 5.7x too large for its cap. Nothing
    #  broke, because prune-guard silently capped the window — which is exactly
    #  why it went unnoticed: the node just fetched history in order to prune
    #  it, forever. This is the check that makes that impossible to ship again.
    measured = (doc.get("cluster") or {}).get("measured") or {}
    rate = measured.get("gib_per_million")
    if rate:
        warn_pct = int(dig(doc, "cluster.thresholds.db_warn_pct"))
        for n in nodes:
            if not n.get("enabled"):
                continue
            rc = role_config(doc, n["role"])
            cap = int(n["db_gib"])
            for key in ("ledger_history", "ledger_history_initial"):
                ledgers = rc.get(key)
                if not isinstance(ledgers, int):
                    continue
                need = ledgers / 1_000_000 * float(rate)
                if need > cap:
                    problems.append(
                        "%s: %s=%s needs ~%.0f GiB at the measured %s GiB/million, but the volume is %d GiB (%.1fx over)"
                        % (n["name"], key, f"{ledgers:,}", need, rate, cap, need / cap))
                elif need > cap * warn_pct / 100.0:
                    warnings.append(
                        "%s: %s=%s fills %.0f%% of its %d GiB volume — above the %d%% warn line, so it will live in disk-pressure pruning rather than reaching a steady state"
                        % (n["name"], key, f"{ledgers:,}", 100 * need / cap, cap, warn_pct))

    # ── no-overcommit math, phase 1 pool only ────────────────────────────────
    pool = int(host["pool_physical_gib"])
    reserve = int(host["reserve_gib"])
    pool_id = host["storage"]
    existing = 400  # vm-100-disk-0, measured, DO NOT TOUCH
    prov = existing
    ledger = ["  %-18s %6d GiB  EXISTING vm-100-disk-0 (DO NOT TOUCH)" % ("vmid 100", existing)]
    for n in nodes:
        if not n.get("enabled"):
            continue
        if n.get("storage") == pool_id:
            prov += int(n["root_gib"])
            ledger.append("  %-18s %6d GiB  root" % (n["name"], int(n["root_gib"])))
        if n.get("db_storage") == pool_id:
            prov += int(n["db_gib"])
            ledger.append("  %-18s %6d GiB  db (%s)" % (n["name"], int(n["db_gib"]), n["role"]))

    if prov > pool:
        problems.append("OVERCOMMIT: %d GiB provisioned > %d GiB pool physical" % (prov, pool))
    elif prov > pool - reserve:
        problems.append(
            "RESERVE BREACH: %d GiB provisioned leaves %d GiB free, below the %d GiB reserve"
            % (prov, pool - prov, reserve)
        )

    ram = sum(int(n["ram_mb"]) for n in nodes if n.get("enabled"))
    if ram > 96 * 1024:
        warnings.append("enabled nodes request %d MiB RAM — check host headroom (128 GB in phase 1)" % ram)

    print("inventory:            %s" % INVENTORY)
    print("phase:                %s" % dig(doc, "cluster.phase"))
    print("host:                 %s (%s)" % (host["name"], host["address"]))
    print("enabled nodes:        %s" % ", ".join(n["name"] for n in nodes if n.get("enabled")))
    print("")
    print("%s allocation:" % pool_id)
    for line in ledger:
        print(line)
    print("  %-18s %6d GiB  TOTAL PROVISIONED" % ("", prov))
    print("  %-18s %6d GiB  pool physical" % ("", pool))
    print("  %-18s %6d GiB  free after provisioning (reserve target %d)" % ("", pool - prov, reserve))
    print("  %-18s %6d MiB  RAM requested by enabled nodes" % ("", ram))
    print("")
    for w in warnings:
        print("WARN  %s" % w)
    for p in problems:
        print("FAIL  %s" % p)
    if problems:
        print("\ninventory check FAILED (%d problem(s))" % len(problems))
        return 1
    print("inventory check OK — no overcommit, reserve intact")
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    doc = load()

    if cmd == "json":
        print(json.dumps(doc, indent=2, sort_keys=False))
        return 0
    if cmd == "get":
        if not args:
            die("get needs a dotted key")
        v = dig(doc, args[0])
        if v is True:
            v = 1
        elif v is False:
            v = 0
        print(json.dumps(v) if isinstance(v, (dict, list)) else ("" if v is None else v))
        return 0
    if cmd == "node":
        if not args:
            die("node needs a name or vmid")
        n = find_node(doc, args[0])
        merged = dict(dig(doc, "cluster.defaults") or {})
        merged.update(dig(doc, "cluster.ports") or {})
        merged.update({"ports_%s" % k: v for k, v in (dig(doc, "cluster.ports") or {}).items()})
        merged.update(role_config(doc, n["role"]))
        merged.update(n)
        merged["host_name"] = dig(doc, "cluster.host.name")
        merged["host_address"] = dig(doc, "cluster.host.address")
        merged["host_ssh_user"] = dig(doc, "cluster.host.ssh_user")
        merged["network_id"] = dig(doc, "cluster.network_id")
        merged["phase_current"] = dig(doc, "cluster.phase")
        for k, v in (dig(doc, "cluster.thresholds") or {}).items():
            merged.setdefault(k, v)
        if len(args) > 1:
            key = args[1]
            if key not in merged:
                die("node %s has no key '%s'" % (args[0], key))
            v = merged[key]
            if v is True:
                v = 1
            elif v is False:
                v = 0
            print("" if v is None else v)
            return 0
        print(emit_shell(merged, prefix="N_"))
        return 0
    if cmd == "nodes":
        sel = doc.get("nodes") or []
        if "--enabled" in args:
            sel = [n for n in sel if n.get("enabled")]
        if "--public" in args:
            sel = [n for n in sel if n.get("public")]
        for flag, key in (("--phase", "phase"), ("--role", "role")):
            if flag in args:
                want = args[args.index(flag) + 1]
                sel = [n for n in sel if str(n.get(key)) == str(want)]
        field = "name"
        if "--field" in args:
            field = args[args.index("--field") + 1]
        for n in sel:
            print(n.get(field, ""))
        return 0
    if cmd == "role":
        if not args:
            die("role needs a role name")
        print(emit_shell(role_config(doc, args[0]), prefix="R_"))
        return 0
    if cmd == "check":
        return check(doc)
    die("unknown command: %s" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
