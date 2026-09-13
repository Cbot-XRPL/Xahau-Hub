#!/usr/bin/env python3
"""
public-info.py — the PUBLIC face of the cluster: live status + API documentation.

Deliberately NOT the ops dashboard. That one (xah-dashboard.py) shows VM ids,
internal addresses, disk capacities and build progress, and has no auth — it
stays on the LAN.

This one is safe to expose because of how it gets its data: it calls the same
public RPC endpoint anyone else can call, and renders only fields from that
reply. It never reads inventory.yml, never ssh's anywhere, and has no access to
anything a visitor could not obtain themselves by POSTing to the endpoint. The
worst it can leak is a slow answer.

  * GET/HEAD only; everything else is 405
  * no query parameters are read, so there is nothing to inject
  * a node that is down degrades to a stale card, it does not hang the server

Usage:
  public-info.py --rpc http://127.0.0.1:5007 --port 8090
                 [--public-rpc https://cluster.cbotlabs.xyz]
                 [--public-ws wss://ws-cluster.cbotlabs.xyz]
"""
import argparse
import html
import json
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"ts": 0, "nodes": [], "ok": False}
LOCK = threading.Lock()


def rpc(url, method, params=None, timeout=8):
    body = json.dumps({"method": method, "params": [params or {}]}).encode()
    req = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def collect(rpc_urls):
    out = []
    for label, url in rpc_urls:
        card = {"label": label, "reachable": False}
        try:
            info = (rpc(url, "server_info").get("result") or {}).get("info") or {}
            cl = info.get("complete_ledgers") or ""
            low = high = count = None
            if "-" in cl:
                parts = cl.split(",")[-1].split("-")
                try:
                    low, high = int(parts[0]), int(parts[1])
                    count = high - low + 1
                except ValueError:
                    pass
            vl = info.get("validated_ledger") or {}
            card.update({
                "reachable": True,
                "server_state": info.get("server_state"),
                "complete_ledgers": cl or None,
                "low": low, "high": high, "count": count,
                "validated_seq": vl.get("seq"),
                "ledger_age_s": vl.get("age"),
                "peers": info.get("peers"),
                "build": info.get("build_version"),
                "network_id": info.get("network_id"),
                "uptime_s": info.get("uptime"),
                "load_factor": info.get("load_factor"),
                # pubkey_node is already in every public server_info reply
                "pubkey_node": info.get("pubkey_node"),
            })
        except Exception as e:
            card["error"] = type(e).__name__
        out.append(card)
    return out


def poller(rpc_urls, refresh):
    while True:
        try:
            nodes = collect(rpc_urls)
            with LOCK:
                STATE["nodes"] = nodes
                STATE["ts"] = time.time()
                STATE["ok"] = any(n.get("reachable") for n in nodes)
        except Exception:
            pass
        time.sleep(refresh)


CSS = """
:root{--bg:#0d1117;--card:#161b22;--line:#21262d;--tx:#e6edf3;--dim:#8b949e;
--ok:#3fb950;--warn:#d29922;--bad:#f85149;--acc:#58a6ff;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.6 system-ui,-apple-system,Segoe UI,sans-serif}
.wrap{max-width:920px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:26px;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.08em;color:var(--dim);margin:36px 0 12px;font-weight:600}
.sub{color:var(--dim);margin:0 0 28px}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}
.card h3{margin:0 0 10px;font-size:14px;display:flex;justify-content:space-between;align-items:center;gap:8px}
.pill{font:600 11px/1 var(--mono);padding:4px 8px;border-radius:999px;border:1px solid}
.pill.ok{color:var(--ok);border-color:#238636}
.pill.warn{color:var(--warn);border-color:#9e6a03}
.pill.bad{color:var(--bad);border-color:#da3633}
.kv{display:flex;justify-content:space-between;gap:12px;padding:4px 0;border-top:1px solid var(--line);font-size:13px}
.kv:first-of-type{border-top:0}
.kv span:first-child{color:var(--dim)}
.kv span:last-child{font-family:var(--mono);text-align:right;word-break:break-all}
pre{background:#010409;border:1px solid var(--line);border-radius:8px;padding:14px;overflow-x:auto;
font:13px/1.55 var(--mono);margin:0 0 12px}
code{font-family:var(--mono);background:#010409;padding:1px 5px;border-radius:4px;font-size:.92em}
table{width:100%;border-collapse:collapse;font-size:14px}
th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.06em}
td code{font-size:13px}
.note{border-left:3px solid var(--acc);background:#0c2d6b22;padding:10px 14px;border-radius:0 8px 8px 0;
color:#c9d1d9;font-size:14px;margin:0 0 12px}
footer{margin-top:44px;padding-top:18px;border-top:1px solid var(--line);color:var(--dim);font-size:13px}
a{color:var(--acc)}
"""


def dur(s):
    if not s:
        return "—"
    s = int(s); d, s = divmod(s, 86400); h, s = divmod(s, 3600); m = s // 60
    return f"{d}d {h}h" if d else (f"{h}h {m}m" if h else f"{m}m")


def page(pub_rpc, pub_ws):
    with LOCK:
        nodes = list(STATE["nodes"]); ts = STATE["ts"]
    e = html.escape

    cards = []
    for n in nodes:
        if not n.get("reachable"):
            cards.append(f"""<div class="card"><h3>{e(n['label'])}<span class="pill bad">unreachable</span></h3>
<div class="kv"><span>status</span><span>not answering</span></div></div>""")
            continue
        st = n.get("server_state") or "?"
        tone = "ok" if st in ("full", "proposing", "validating") else "warn"
        rng = f"{n['low']:,}–{n['high']:,}" if n.get("low") else (n.get("complete_ledgers") or "—")
        cnt = f"{n['count']:,}" if n.get("count") else "—"
        cards.append(f"""<div class="card"><h3>{e(n['label'])}<span class="pill {tone}">{e(st)}</span></h3>
<div class="kv"><span>validated ledger</span><span>{n.get('validated_seq') or '—'}</span></div>
<div class="kv"><span>ledger age</span><span>{n.get('ledger_age_s','—')}s</span></div>
<div class="kv"><span>history window</span><span>{cnt} ledgers</span></div>
<div class="kv"><span>range</span><span>{rng}</span></div>
<div class="kv"><span>peers</span><span>{n.get('peers','—')}</span></div>
<div class="kv"><span>uptime</span><span>{dur(n.get('uptime_s'))}</span></div>
<div class="kv"><span>build</span><span>{e(str(n.get('build') or '—'))}</span></div>
</div>""")

    age = int(time.time() - ts) if ts else None
    stamp = f"updated {age}s ago" if age is not None else "starting up"

    return f"""<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Xahau public node — {e(pub_rpc)}</title>
<meta name="description" content="Public Xahau mainnet JSON-RPC and WebSocket endpoint. Live status and API documentation.">
<style>{CSS}</style><meta http-equiv="refresh" content="30"></head><body><div class="wrap">

<h1>Xahau public node</h1>
<p class="sub">Mainnet · NetworkID 21337 · community endpoint · {e(stamp)}</p>

<h2>Endpoints</h2>
<table>
<tr><th>Protocol</th><th>URL</th><th>Use</th></tr>
<tr><td>JSON-RPC</td><td><code>{e(pub_rpc)}</code></td><td>Stateless queries. POST only.</td></tr>
<tr><td>WebSocket</td><td><code>{e(pub_ws)}</code></td><td>Subscriptions and streaming.</td></tr>
</table>

<h2>Live status</h2>
<div class="grid">{''.join(cards) or '<div class="card">collecting…</div>'}</div>

<h2>Quick start</h2>
<p class="note"><strong>JSON-RPC is POST-only.</strong> A <code>GET</code> to the RPC URL
returns a parse error — that is the node telling you it expects a JSON body, not an outage.</p>
<pre>curl {e(pub_rpc)} \\
  -H 'content-type: application/json' \\
  -d '{{"method":"server_info","params":[{{}}]}}'</pre>

<pre>curl {e(pub_rpc)} \\
  -H 'content-type: application/json' \\
  -d '{{"method":"account_info","params":[{{
        "account":"rExampleAccountAddressHere",
        "ledger_index":"validated"}}]}}'</pre>

<h2>WebSocket</h2>
<pre>// xahau.js / xrpl.js
const {{ Client }} = require('xahau');
const client = new Client('{e(pub_ws)}');
await client.connect();
console.log(await client.request({{ command: 'server_info' }}));

// live ledger stream
await client.request({{ command: 'subscribe', streams: ['ledger'] }});
client.on('ledgerClosed', l =&gt; console.log(l.ledger_index, l.txn_count));</pre>

<h2>Supported methods</h2>
<table>
<tr><th>Method</th><th>Notes</th></tr>
<tr><td><code>server_info</code></td><td>Node state, history window, peer count.</td></tr>
<tr><td><code>fee</code></td><td>Current transaction cost.</td></tr>
<tr><td><code>ledger</code> / <code>ledger_current</code> / <code>ledger_closed</code></td><td>Ledger data and indexes.</td></tr>
<tr><td><code>account_info</code></td><td>Account balance, sequence, flags.</td></tr>
<tr><td><code>account_tx</code></td><td>Transaction history — <strong>within the window shown above</strong>.</td></tr>
<tr><td><code>account_lines</code>, <code>account_objects</code>, <code>book_offers</code></td><td>Standard read APIs.</td></tr>
<tr><td><code>submit</code></td><td>Signed transaction submission.</td></tr>
<tr><td><code>subscribe</code> / <code>unsubscribe</code></td><td><strong>WebSocket only.</strong></td></tr>
</table>

<h2>Limits and expectations</h2>
<table>
<tr><th>Thing</th><th>Detail</th></tr>
<tr><td>History</td><td>A rolling window, not full history. Requests outside the range above return no data.</td></tr>
<tr><td>Admin methods</td><td>Not exposed. <code>can_delete</code>, <code>stop</code>, <code>peers</code> and friends return <strong>403</strong>.</td></tr>
<tr><td>Rate limiting</td><td>Applied at the edge. Sustained abuse is throttled per client address.</td></tr>
<tr><td>Long queries</td><td>Requests over ~100s are cut off upstream. Page deep <code>account_tx</code> with <code>limit</code> and <code>marker</code>.</td></tr>
<tr><td>Availability</td><td>Best effort, no SLA. Run your own node for anything you cannot afford to have fail.</td></tr>
</table>

<footer>
Stock <code>xahaud</code> nodes. They do not validate — trust comes from the published Xahau UNL.<br>
Status refreshes every 30s. Machine-readable: <a href="/api/status">/api/status</a>
</footer>
</div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "xahau-public-info"
    pub_rpc = pub_ws = ""

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.send_header("x-content-type-options", "nosniff")
        self.send_header("referrer-policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            with LOCK:
                ok, ts = STATE["ok"], STATE["ts"]
            self._send(200 if ok else 503,
                       json.dumps({"ok": ok, "age_s": round(time.time() - ts, 1) if ts else None}),
                       "application/json")
        elif path == "/api/status":
            with LOCK:
                payload = {"ts": STATE["ts"], "nodes": STATE["nodes"]}
            self._send(200, json.dumps(payload, indent=2), "application/json")
        elif path == "/":
            self._send(200, page(self.pub_rpc, self.pub_ws), "text/html; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain")

    # Read-only by construction: anything that could change state is refused
    # before it is parsed.
    def _refuse(self):
        self._send(405, "read-only\n", "text/plain")
    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _refuse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--refresh", type=float, default=15.0)
    ap.add_argument("--rpc", action="append", default=[],
                    help="label=url, repeatable, e.g. 'api node=http://127.0.0.1:5007'")
    ap.add_argument("--public-rpc", default="https://cluster.cbotlabs.xyz")
    ap.add_argument("--public-ws", default="wss://ws-cluster.cbotlabs.xyz")
    a = ap.parse_args()

    pairs = []
    for spec in a.rpc or ["node=http://127.0.0.1:5007"]:
        label, _, url = spec.partition("=")
        pairs.append((label or "node", url or label))

    Handler.pub_rpc, Handler.pub_ws = a.public_rpc, a.public_ws
    threading.Thread(target=poller, args=(pairs, a.refresh), daemon=True).start()
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
