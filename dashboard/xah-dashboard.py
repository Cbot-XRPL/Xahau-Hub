#!/usr/bin/env python3
"""
xah-dashboard.py — read-only monitoring dashboard for the Xahau node cluster.

Runs INSIDE a node VM (see cluster.monitoring.node in inventory.yml) and serves
a single page at http://<node>:<port>/ plus a JSON feed at /api/state.

It deliberately does NOT run on the Proxmox host. pve2 is a shared hypervisor
that this repo does not own: no resident agent of ours belongs on it, so the
collector refuses to start if it detects a PVE host, and it never contacts the
host at all. Everything it reports is observed from inside the VMs.

It is READ ONLY by construction:
  * only GET/HEAD are answered; every other method is 405
  * every probe is a fixed read-only command, never user input
  * its own node is read locally; peer nodes over ssh, through the same
    forbidden-target guard the shell scripts use, so the UNL validator host
    can never be contacted

A background collector refreshes on an interval so page loads never block on
ssh, and a dead peer degrades to a stale card instead of hanging the server.

Usage:
  xah-dashboard.py [--bind 0.0.0.0] [--port 8088] [--refresh 20]
                   [--node NAME] [--once] [--allow-any-host]

  --node            which inventory node this is (default: hostname)
  --once            collect one cycle, print the JSON, exit (cron / debugging)
  --allow-any-host  skip the "not a PVE host" assertion (testing only)
"""
import argparse
import base64
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
STATIC = os.path.join(HERE, "static")
sys.path.insert(0, os.path.join(REPO, "lib"))

import inventory  # noqa: E402  — lib/inventory.py, same source of truth

SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=6",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "LogLevel=ERROR",
]

# ── provisioning stages, in order. The dashboard doubles as a build tracker. ──
#  Every stage here is observable from inside a guest. "VM created" and "powered
#  on" used to be read off the hypervisor with `qm list`; they are gone on
#  purpose — if a guest answers at all it is created and running, and asking the
#  host would mean reaching outside our own VMs.
STAGES = [
    ("reachable", "Guest reachable"),
    ("disk",      "DB disk present"),
    ("fs",        "DB volume mounted"),
    ("binary",    "xahaud installed"),
    ("config",    "Config in place"),
    ("service",   "Service running"),
    ("synced",    "Synced to network"),
]

SYNCED_STATES = {"full", "proposing", "validating"}


# ── guard ─────────────────────────────────────────────────────────────────────
class Guard:
    """Mirror of lib/guard.sh: nothing here may ever reach the UNL validator."""

    def __init__(self, doc):
        f = (doc.get("cluster") or {}).get("forbidden") or {}
        self.hosts = [str(h).lower() for h in (f.get("hosts") or []) if h]
        self.addresses = [str(a) for a in (f.get("host_addresses") or []) if a]
        self.vmids = [int(v) for v in (f.get("vmids") or []) if v is not None]

    def reject(self, *targets):
        for t in targets:
            if not t:
                continue
            low = str(t).lower()
            for h in self.hosts:
                if low == h or low.startswith(h + ".") or low.endswith("@" + h):
                    raise PermissionError("GUARD: refusing to target %r (%s is the UNL validator host)" % (t, h))
            for a in self.addresses:
                if a in low:
                    raise PermissionError("GUARD: refusing to target %r (%s is the validator host address)" % (t, a))
            if re.search(r"ct-?200|validator|unl", low):
                raise PermissionError("GUARD: refusing to target %r — the name references the UNL validator" % (t,))
        return True


def assert_not_pve_host(doc):
    """Containment: this must never become a resident service on the hypervisor."""
    host_name = ((doc.get("cluster") or {}).get("host") or {}).get("name")
    me = os.uname().nodename.split(".")[0]
    reasons = []
    if os.path.isdir("/etc/pve"):
        reasons.append("/etc/pve exists")
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.path.exists(os.path.join(d, "qm")):
            reasons.append("the `qm` command is present")
            break
    if host_name and me == host_name:
        reasons.append("this machine is %s, the Proxmox host" % host_name)
    if reasons:
        raise SystemExit(
            "xah-dashboard: refusing to run here — %s.\n"
            "This dashboard runs INSIDE a node VM, not on the hypervisor. pve2 is a\n"
            "shared host this repo does not own. Install it with dashboard/install.sh,\n"
            "which targets cluster.monitoring.node. (--allow-any-host overrides.)\n"
            % "; ".join(reasons)
        )


# ── shelling out ──────────────────────────────────────────────────────────────
def run(argv, timeout=20, stdin=None):
    """Run a command, return (rc, stdout). Never raises on a non-zero exit."""
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (subprocess.TimeoutExpired, OSError):
        return 124, ""


def kv(text):
    """Parse the KEY=VALUE output of the probe below."""
    out = {}
    for line in text.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def as_int(d, key, default=None):
    try:
        return int(float(d[key]))
    except (KeyError, TypeError, ValueError):
        return default


def gib(n_bytes):
    try:
        return round(float(n_bytes) / (1024 ** 3), 1)
    except (TypeError, ValueError):
        return None


def pct(part, whole):
    try:
        if not whole:
            return None
        return round(float(part) / float(whole) * 100, 1)
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def b64text(s):
    if not s:
        return ""
    try:
        return base64.b64decode(s).decode("utf-8", "replace")
    except Exception:
        return ""


# ── the one probe ─────────────────────────────────────────────────────────────
#  Runs locally for this node, over ssh for a peer. Identical either way, so a
#  peer card and a self card always mean the same thing.
GUEST_PROBE_TMPL = r"""
set -u
MOUNT=%(mount)s
BIN=%(bin)s
CFG=%(cfg)s
SVC=%(svc)s
LABEL=%(label)s
RPCPORT=%(rpc)s
echo "hostname=$(hostname -s)"
echo "os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
echo "kernel=$(uname -r)"
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
echo "loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "cpus=$(nproc)"
awk '/^MemTotal:/{print "mem_total_kb="$2} /^MemAvailable:/{print "mem_avail_kb="$2}' /proc/meminfo
echo "root_b64=$(df -B1 --output=size,used,avail,pcent / 2>/dev/null | tail -1 | base64 -w0)"
echo "db_blockdev=$(lsblk -ndo NAME,SIZE 2>/dev/null | awk '$1=="sdb"{print $2}')"
echo "db_labelled=$(blkid -L "$LABEL" 2>/dev/null || true)"
if findmnt -nbo SOURCE,FSTYPE,SIZE,USED,AVAIL "$MOUNT" >/dev/null 2>&1; then
  findmnt -nbo SOURCE,FSTYPE,SIZE,USED,AVAIL "$MOUNT" | awk '{print "db_source="$1"\ndb_fs="$2"\ndb_size_b="$3"\ndb_used_b="$4"\ndb_avail_b="$5}'
fi
echo "fstab=$(grep -c "$LABEL" /etc/fstab 2>/dev/null || echo 0)"
if [ -x "$BIN" ]; then
  echo "bin=1"
  echo "bin_version=$("$BIN" --version 2>/dev/null | head -1)"
else
  echo "bin=0"
fi
[ -f "$CFG" ] && echo "cfg=1" || echo "cfg=0"
echo "cfg_seed=$(grep -c '^\[node_seed\]' "$CFG" 2>/dev/null || echo 0)"
echo "svc_active=$(systemctl is-active "$SVC" 2>/dev/null || true)"
echo "svc_enabled=$(systemctl is-enabled "$SVC" 2>/dev/null || true)"
echo "crons=$(ls /etc/cron.d/xahau-hub >/dev/null 2>&1 && echo 1 || echo 0)"
echo "rpc_b64=$(curl -fsS --max-time 8 -H 'content-type: application/json' --data '{"method":"server_info","params":[{}]}' "http://127.0.0.1:${RPCPORT}/" 2>/dev/null | base64 -w0)"
"""


# ── collector ─────────────────────────────────────────────────────────────────
class Collector:
    def __init__(self, refresh=20.0, self_node=None):
        self.refresh = refresh
        self.doc = inventory.load()
        self.guard = Guard(self.doc)
        self.lock = threading.Lock()
        self.state = {"generated_at": 0, "collecting": True, "nodes": [], "cluster": {}}
        self._stop = threading.Event()
        me = os.uname().nodename.split(".")[0]
        names = [n["name"] for n in (self.doc.get("nodes") or [])]
        self.self_node = self_node or (me if me in names else None)
        self.hostname = me

    # -- command routing: local for this node, guarded ssh for a peer --------
    def probe(self, node, script, timeout=30):
        if node["name"] == self.self_node:
            return run(["bash", "-s"], timeout=timeout, stdin=script)
        addr = node["address"]
        self.guard.reject(node["name"], addr, str(node.get("vmid")))
        argv = ["ssh", *SSH_OPTS, "%s@%s" % (node.get("ssh_user", "root"), addr), "bash -s"]
        try:
            p = subprocess.run(argv, input=script, capture_output=True, text=True, timeout=timeout)
            return p.returncode, p.stdout
        except (subprocess.TimeoutExpired, OSError):
            return 124, ""

    # -- one node -----------------------------------------------------------
    def collect_node(self, n):
        c = self.doc["cluster"]
        dflt = c["defaults"]
        th = c["thresholds"]
        name, addr = n["name"], n["address"]
        self.guard.reject(name, addr, str(n["vmid"]))

        is_self = name == self.self_node
        node = {
            "name": name, "vmid": n["vmid"], "role": n["role"], "address": addr,
            "enabled": bool(n.get("enabled")), "phase": n.get("phase"),
            "public": bool(n.get("public")), "notes": n.get("notes"),
            "is_self": is_self,
            "probe": "local" if is_self else "ssh",
            "spec": {"vcpu": n.get("vcpu"), "ram_mb": n.get("ram_mb"),
                     "root_gib": n.get("root_gib"), "db_gib": n.get("db_gib"),
                     "db_storage": n.get("db_storage")},
            "done": {k: False for k, _ in STAGES},
            "errors": [],
        }

        # A node that is not enabled yet is planned, not broken. Do not probe it
        # and do not colour it as a failure.
        if not node["enabled"]:
            node["planned"] = True
            node["reachable"] = False
            node["stage"] = self._stage(node)
            return node

        probe = GUEST_PROBE_TMPL % {
            "mount": shlex.quote(dflt["db_mount"]),
            "bin": shlex.quote(dflt["xahaud_bin"]),
            "cfg": shlex.quote(dflt["xahaud_cfg"]),
            "svc": shlex.quote(dflt["xahaud_service"]),
            "label": shlex.quote(dflt["db_label"]),
            "rpc": shlex.quote(str(c["ports"]["rpc_admin"])),
        }
        rc, out = self.probe(n, probe)
        node["reachable"] = rc == 0
        if rc != 0:
            node["errors"].append(
                "local probe failed (rc=%s)" % rc if is_self
                else "ssh probe failed (rc=%s) — no route, no key, or the guest is down" % rc)
            node["stage"] = self._stage(node)
            return node
        node["done"]["reachable"] = True
        d = kv(out)

        node["hostname"] = d.get("hostname")
        node["os"] = d.get("os")
        node["kernel"] = d.get("kernel")
        node["uptime_s"] = as_int(d, "uptime_s")
        node["cpus"] = as_int(d, "cpus")
        node["crons"] = d.get("crons") == "1"
        try:
            node["load"] = [float(x) for x in (d.get("loadavg") or "").split()]
        except ValueError:
            node["load"] = []
        tk, ak = as_int(d, "mem_total_kb"), as_int(d, "mem_avail_kb")
        if tk and ak is not None:
            node["mem"] = {"total_gib": gib(tk * 1024), "used_gib": gib((tk - ak) * 1024),
                           "pct": pct(tk - ak, tk)}
        rootf = b64text(d.get("root_b64")).split()
        if len(rootf) >= 4:
            node["root"] = {"total_gib": gib(rootf[0]), "used_gib": gib(rootf[1]),
                            "avail_gib": gib(rootf[2]), "pct": pct(rootf[1], rootf[0])}

        # hostname drift is worth surfacing: the ops scripts resolve a node from it
        if node["hostname"] and node["hostname"] != name:
            node["errors"].append("guest hostname is %r, inventory calls this node %r"
                                  % (node["hostname"], name))

        node["done"]["disk"] = bool(d.get("db_blockdev"))
        db = {
            "mount": dflt["db_mount"],
            "label": dflt["db_label"],
            "want_fs": dflt["db_fs"],
            "cap_gib": n.get("db_gib"),
            "blockdev": d.get("db_blockdev") or None,
            "labelled": bool(d.get("db_labelled")),
            "in_fstab": (as_int(d, "fstab", 0) or 0) > 0,
            "warn_pct": th["db_warn_pct"],
            "crit_pct": th["db_crit_pct"],
        }
        if d.get("db_size_b"):
            db.update({
                "fs": d.get("db_fs"),
                "source": d.get("db_source"),
                "total_gib": gib(d["db_size_b"]),
                "used_gib": gib(d.get("db_used_b")),
                "avail_gib": gib(d.get("db_avail_b")),
                "pct": pct(as_int(d, "db_used_b", 0), as_int(d, "db_size_b", 0)),
                "mounted": True,
            })
            node["done"]["fs"] = True
            if db.get("fs") and db["fs"] != dflt["db_fs"]:
                node["errors"].append("DB volume is %s, spec requires %s" % (db["fs"], dflt["db_fs"]))
            if not db["in_fstab"]:
                node["errors"].append("DB volume is mounted but not in /etc/fstab — it will not survive a reboot")
        else:
            db["mounted"] = False
        node["db"] = db

        node["done"]["binary"] = d.get("bin") == "1"
        node["done"]["config"] = d.get("cfg") == "1"
        has_seed = (as_int(d, "cfg_seed", 0) or 0) > 0
        node["xahaud"] = {
            "installed": node["done"]["binary"],
            "version": (d.get("bin_version") or "").strip() or None,
            "config": node["done"]["config"],
            "permanent_identity": has_seed,
            "service": d.get("svc_active") or "unknown",
            "enabled": d.get("svc_enabled") or "unknown",
        }
        node["done"]["service"] = d.get("svc_active") == "active"
        if node["done"]["config"] and not has_seed:
            node["errors"].append("running a BOOTSTRAP config with no [node_seed] — throwaway identity. "
                                  "Mint one (make seed NODE=%s) then redeploy." % name)

        info = {}
        raw = b64text(d.get("rpc_b64"))
        if raw:
            try:
                info = (json.loads(raw).get("result") or {}).get("info") or {}
            except (ValueError, AttributeError):
                node["errors"].append("server_info returned unparseable JSON")
        if info:
            vl = info.get("validated_ledger") or {}
            cl = info.get("complete_ledgers") or ""
            low = high = count = None
            m = re.findall(r"(\d+)-(\d+)", cl)
            if m:
                low, high = int(m[0][0]), int(m[-1][1])
                count = sum(int(b) - int(a) + 1 for a, b in m)
            node["ledger"] = {
                "server_state": info.get("server_state"),
                "complete_ledgers": cl or None,
                "low": low, "high": high, "count": count,
                "validated_seq": vl.get("seq"),
                "validated_age_s": vl.get("age"),
                "peers": info.get("peers"),
                "uptime_s": info.get("uptime"),
                "io_latency_ms": info.get("io_latency_ms"),
                "load_factor": info.get("load_factor"),
                "build_version": info.get("build_version"),
                "pubkey_node": info.get("pubkey_node"),
                "network_id": info.get("network_id"),
                "amendment_blocked": info.get("amendment_blocked", False),
            }
            node["done"]["synced"] = (info.get("server_state") or "") in SYNCED_STATES
            if node["ledger"]["amendment_blocked"]:
                node["errors"].append("AMENDMENT BLOCKED — this node cannot follow the network")
            if node["ledger"]["network_id"] not in (None, c["network_id"]):
                node["errors"].append("network_id is %s, inventory says %s"
                                      % (node["ledger"]["network_id"], c["network_id"]))
        elif node["done"]["service"]:
            node["errors"].append("service is active but admin RPC did not answer on 127.0.0.1:%s"
                                  % c["ports"]["rpc_admin"])

        node["stage"] = self._stage(node)
        return node

    @staticmethod
    def _stage(node):
        steps = [{"key": k, "label": lbl, "done": bool(node["done"].get(k))} for k, lbl in STAGES]
        reached = 0
        for s in steps:
            if not s["done"]:
                break
            reached += 1
        return {
            "steps": steps,
            "reached": reached,
            "total": len(steps),
            "label": steps[reached]["label"] if reached < len(steps) else "Operational",
            "complete": reached == len(steps),
        }

    # -- cycle --------------------------------------------------------------
    def cycle(self):
        t0 = time.time()
        try:
            self.doc = inventory.load()
            self.guard = Guard(self.doc)
        except Exception as e:  # a bad edit to inventory.yml must not kill the server
            with self.lock:
                self.state = dict(self.state, error="inventory.yml unreadable: %s" % e,
                                  generated_at=time.time(), collecting=False)
            return

        nodes, threads, results = [], [], {}

        def worker(i, n):
            try:
                results[i] = self.collect_node(n)
            except PermissionError as e:
                results[i] = {"name": n.get("name"), "vmid": n.get("vmid"), "guard_blocked": str(e),
                              "errors": [str(e)], "done": {}, "stage": {"steps": [], "reached": 0,
                                                                        "total": len(STAGES), "label": "blocked"}}
            except Exception as e:
                results[i] = {"name": n.get("name"), "vmid": n.get("vmid"), "errors": ["collector: %s" % e],
                              "done": {}, "stage": {"steps": [], "reached": 0, "total": len(STAGES),
                                                    "label": "error"}}

        for i, n in enumerate(self.doc.get("nodes") or []):
            t = threading.Thread(target=worker, args=(i, n), daemon=True)
            t.start()
            threads.append(t)
        for t in threads:
            t.join(timeout=40)
        for i in sorted(results):
            nodes.append(results[i])

        c = self.doc["cluster"]
        live = [n for n in nodes if n.get("enabled")]
        db_cap = sum((n.get("spec", {}).get("db_gib") or 0) for n in live)
        db_used = sum((n.get("db", {}).get("used_gib") or 0) for n in live)
        state = {
            "generated_at": time.time(),
            "collect_ms": int((time.time() - t0) * 1000),
            "refresh_s": self.refresh,
            "collecting": False,
            "cluster": {
                "name": c["name"], "network": c["network"], "network_id": c["network_id"],
                "phase": c["phase"],
                "ports": c["ports"],
                "proxy": c.get("proxy", {}),
                "nodes_enabled": len(live),
                "nodes_total": len(nodes),
                "db_cap_gib": db_cap or None,
                "db_used_gib": round(db_used, 1) if db_used else None,
            },
            # Where this dashboard is running. Named so it is obvious on the page
            # that the answer is "in a VM", not "on the hypervisor".
            "collector": {
                "in_guest": True,
                "node": self.self_node,
                "hostname": self.hostname,
                "reads_hypervisor": False,
            },
            "nodes": nodes,
            "guard": {
                "hosts": self.guard.hosts,
                "addresses": self.guard.addresses,
                "vmids": self.guard.vmids,
                "reason": (c.get("forbidden") or {}).get("reason"),
            },
        }
        with self.lock:
            self.state = state

    def snapshot(self):
        with self.lock:
            s = dict(self.state)
        s["age_s"] = round(max(0.0, time.time() - (s.get("generated_at") or 0)), 1)
        return s

    def run_forever(self):
        while not self._stop.is_set():
            try:
                self.cycle()
            except Exception as e:
                sys.stderr.write("collector cycle failed: %s\n" % e)
            self._stop.wait(self.refresh)

    def stop(self):
        self._stop.set()


# ── http ──────────────────────────────────────────────────────────────────────
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "xah-dashboard"
    sys_version = ""
    collector = None

    def log_message(self, fmt, *args):  # quiet: journald gets the important lines
        pass

    def _send(self, code, body, ctype, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            s = self.collector.snapshot()
            return self._send(200, json.dumps(s, default=str), "application/json; charset=utf-8",
                              {"Cache-Control": "no-store"})
        if path == "/healthz":
            s = self.collector.snapshot()
            ok = not s.get("collecting") and s.get("age_s", 1e9) < max(60, self.collector.refresh * 3)
            return self._send(200 if ok else 503, json.dumps({"ok": ok, "age_s": s.get("age_s")}),
                              "application/json; charset=utf-8", {"Cache-Control": "no-store"})
        if path == "/":
            path = "/index.html"
        # static, sandboxed to STATIC/
        safe = os.path.normpath(os.path.join(STATIC, path.lstrip("/")))
        if not safe.startswith(STATIC + os.sep) or not os.path.isfile(safe):
            return self._send(404, "not found\n", "text/plain; charset=utf-8")
        with open(safe, "rb") as fh:
            body = fh.read()
        ctype = CONTENT_TYPES.get(os.path.splitext(safe)[1], "application/octet-stream")
        return self._send(200, body, ctype, {"Cache-Control": "no-cache"})

    do_HEAD = do_GET

    def _deny(self):
        self._send(405, "this dashboard is read-only\n", "text/plain; charset=utf-8", {"Allow": "GET, HEAD"})

    do_POST = do_PUT = do_DELETE = do_PATCH = _deny


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default=os.environ.get("XAH_DASH_BIND", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("XAH_DASH_PORT", "8088")))
    ap.add_argument("--refresh", type=float, default=float(os.environ.get("XAH_DASH_REFRESH", "20")))
    ap.add_argument("--node", default=os.environ.get("XAH_NODE") or None)
    ap.add_argument("--once", action="store_true", help="collect once, print JSON, exit")
    ap.add_argument("--allow-any-host", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args(argv[1:])

    doc = inventory.load()
    if not args.allow_any_host:
        assert_not_pve_host(doc)

    col = Collector(refresh=args.refresh, self_node=args.node)
    if col.self_node is None:
        sys.stderr.write(
            "xah-dashboard: WARNING — hostname %r is not a node in inventory.yml, so every\n"
            "node will be probed over ssh instead of locally. Pass --node NAME.\n" % col.hostname)

    if args.once:
        col.cycle()
        print(json.dumps(col.snapshot(), indent=2, default=str))
        return 0

    threading.Thread(target=col.run_forever, daemon=True).start()
    Handler.collector = col
    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    httpd.daemon_threads = True
    sys.stderr.write("xah-dashboard listening on http://%s:%d/  (refresh %gs, in guest %s)\n"
                     % (args.bind, args.port, args.refresh, col.self_node or col.hostname))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        col.stop()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
