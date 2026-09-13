# Public endpoint — Cloudflare Tunnel → Nginx Proxy Manager

## The actual path a request takes

```
client ──https──▶ Cloudflare edge          TLS terminates HERE
                       │                    DNS: <name> = Tunnel → onexah
                       ▼
                  cloudflared               tunnel 058ff9ba-0a47-4c80-b117-b404dad8c438
                       ▼
                  NPM  192.168.1.176        proxy host per hostname
                       ▼
                  xah-node-2  192.168.1.111 :5007 rpc · :6006 ws
```

**There is no port forwarding and no published WAN IP.** The tunnel dials
out. Two things follow, and both matter more than they look:

1. **The "is the WAN IP static?" question is moot.** It is never published, so
   it can change freely. That blocker is resolved.
2. **By the time a request reaches xahaud, its source address has been
   rewritten twice** — once by Cloudflare, once by cloudflared/NPM. xahaud
   sees NPM. NPM sees cloudflared. Only Cloudflare ever saw the real client.

> **This repo does not provision, modify or connect to NPM or the tunnel.**
> NPM lives in CT 100 on the R730xd, the same host as the UNL validator, and
> `lib/guard.sh` refuses that host. Everything below is done **by hand** in the
> Cloudflare and NPM UIs. These are the settings, not an automation.

---

## Adding `cluster.cbotlabs.xyz`

The tunnel is **file-managed, not dashboard-managed**. It lives in the private
repo `Cbot-XRPL/cloudflare-tunnel`, cloned on the NPM host, and `hosts.txt` is
the source of truth. `tunnel-host.sh` regenerates `config.yml`, creates the DNS
route and restarts cloudflared in one step.

> Do **not** add CNAMEs by hand in the Cloudflare DNS UI. `tunnel-host.sh apply`
> runs `cloudflared tunnel route dns --overwrite-dns` for every host in
> `hosts.txt`. A hand-made record is either redundant or silently fighting it.

### 1. NPM first — two proxy hosts

Do this **before** routing the hostname, so the tunnel never delivers a request
NPM does not yet recognise.

Every tunnel host arrives at NPM as `https://localhost:443` with SNI and Host
set to the public name, so NPM fans out by Host exactly as it does for every
other site. Internal IPs live **only** in NPM, never in the tunnel config.

**Host A — JSON-RPC**

| field | value |
|---|---|
| Domain Names | `cluster.cbotlabs.xyz` |
| Scheme | `http` |
| Forward Hostname / IP | `192.168.1.111` ← **xah-node-2**, the api node |
| Forward Port | `5007` |
| Websockets Support | off |
| Access List | Publicly Accessible |

**Host B — WebSocket**

| field | value |
|---|---|
| Domain Names | `ws.cluster.cbotlabs.xyz` |
| Scheme | `http` |
| Forward Hostname / IP | `192.168.1.111` |
| Forward Port | **`6006`** |
| **Websockets Support** | **ON** |
| Access List | Publicly Accessible |

Two hosts rather than one, because NPM generates its own `location /` — a
`location` block pasted into **Advanced** is a duplicate-location error that
fails the reload and takes down *every* proxy host, not just the new one.

### 2. Then route them — on the NPM host

```bash
cd ~/cloudflare-tunnel          # wherever the repo is cloned
bash tunnel-host.sh add cluster.cbotlabs.xyz
bash tunnel-host.sh add ws.cluster.cbotlabs.xyz
bash tunnel-host.sh list        # confirm
```

`add` appends to `hosts.txt` and auto-applies: regenerates `config.yml` with
`noTLSVerify: true` and `originServerName: <host>`, creates each DNS route, and
restarts cloudflared.

### Optional hardening, on both NPM hosts (Advanced box)

Server-level directives only — no `location` wrapper:

```nginx
# Cloudflare is the only hop that saw the real client. Set, do not append:
# otherwise xahaud faithfully rate-limits cloudflared.
proxy_set_header X-Real-IP         $http_cf_connecting_ip;
proxy_set_header X-Forwarded-For   $http_cf_connecting_ip;
proxy_set_header X-Forwarded-Proto https;

# A subscribe is long-lived and idle; without this it dies at 60s and clients
# see disconnects they cannot explain. Harmless on the RPC host.
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
```

Do **not** add `proxy_set_header Connection $connection_upgrade` — that comes
from an http-level `map` NPM does not always define, and an undefined variable
there fails the reload. NPM's Websockets Support toggle already sets it.

### 3. Point `secure_gateway` at NPM — already done

`inventory.yml` sets `cluster.proxy.address: 192.168.1.176`, rendered into both
public port stanzas. That is what makes xahaud read the forwarded address
rather than accounting every request against NPM.

The chain only works end to end if **every** hop preserves it, which is why
the nginx block above sets `X-Forwarded-For` from `CF-Connecting-IP` rather
than appending to whatever arrived.

---

## Two failures that cost real time here

### 1. Hostnames must be ONE label deep

Cloudflare **Universal SSL** issues exactly:

```
X509v3 Subject Alternative Name:
    DNS:cbotlabs.xyz, DNS:*.cbotlabs.xyz
```

One wildcard level. `ws.cluster.cbotlabs.xyz` is two, so the edge has no
certificate for it and the connection dies at the TLS handshake:

```
TLSv1.3 (IN), TLS alert, handshake failure (552)
curl: (35) TLS connect error
```

It never reaches the tunnel, so nothing in cloudflared, NPM or xahaud can be
at fault and nothing in their logs shows anything. Use `ws-cluster.<zone>`,
not `ws.cluster.<zone>`. Multi-level wildcards require Advanced Certificate
Manager, which is paid.

### 2. `cloudflared tunnel route dns` only works for the cert's own zone

`~/.cloudflared/cert.pem` is scoped to the single zone chosen during
`cloudflared tunnel login` — here, **onexah.io**. `route dns` treats the
hostname as *relative to that zone*, so:

```
$ cloudflared tunnel route dns --overwrite-dns onexah cluster.cbotlabs.xyz
INF cluster.cbotlabs.xyz.onexah.io is already configured to route to your tunnel
```

It created `cluster.cbotlabs.xyz.onexah.io` — a real record, in the wrong
zone, and **exited 0**. `tunnel-host.sh` pipes that to `/dev/null` and prints
`DNS → tunnel: <host>`, so every host reads as routed. Confirmed junk records
now in the onexah.io zone:

```
cluster.cbotlabs.xyz.onexah.io       ws.cluster.cbotlabs.xyz.onexah.io
xahauval.cbotlabs.xyz.onexah.io      webserver.cbotlabs.xyz.onexah.io
cbotlabs.xyz.onexah.io               xahauvault.com.onexah.io
odinseyes.io.onexah.io               newterraconstruction.com.onexah.io
```

**Consequence:** for any zone other than the cert's, create the CNAME by hand:

| Type | Name | Target | Proxy |
|---|---|---|---|
| CNAME | `cluster` | `<TUNNEL_ID>.cfargotunnel.com` | Proxied |

(That is exactly how the working hostnames were already set up — which is why
they work and the "automated" ones never did.)

### 3. NPM needs a cert or the hostname does not exist to it

Symptom: the request arrives and you get the **"Default Page of NPMplus"** —
`GET` returns 200, `POST` returns 405. That is not the backend. It means SNI
matched no server block and fell through to the default.

NPMplus only builds an SSL server block for a hostname once it has a
certificate. Requesting one while DNS is still NXDOMAIN fails, leaving the
proxy host listed but unserved. **Order matters: DNS first, then the cert.**

## Rate limiting belongs at Cloudflare

Measured on this cluster: **60 rapid JSON-RPC requests from one address all
returned 200, with `load_factor` pinned at 1.** xahaud does not rate limit a
public endpoint at any rate a real client would produce. Do not rely on it.

NPM can limit too, but behind a tunnel it is working from a header rather than
a socket address. Cloudflare is the only hop that sees the client directly.

Cloudflare → Security → WAF → Rate limiting rules:

| rule | expression | action |
|---|---|---|
| RPC flood | `http.host eq "cluster.cbotlabs.xyz"` | 20 req / 10s per IP → block 60s |
| WS churn | same host, `http.request.headers["upgrade"][0] eq "websocket"` | 10 req / 60s per IP |

Then in xahaud, `[cluster_nodes]` shares abuse accounting between the nodes, so
a client cannot hop backends to reset its budget — but only once
`secure_gateway` is in place, or every client looks like one client and there
is nothing to share.

### Two Cloudflare behaviours to know before going public

- **The ~100s proxy timeout applies to HTTP, not WebSockets.** A deep
  historical `account_tx` can exceed it and return a 524 while the node is
  still working perfectly. That is one more reason deep queries get their own
  hostname pointed at node 1, rather than sharing this one.
- **Caching does not apply to POST**, which is all JSON-RPC is. Nothing to
  configure, but do not add a cache rule "to be safe" — a cached ledger
  response is a wrong answer served fast.

---

---

## What is exposed, and what is not

| port | protocol | proxied? |
|---|---|---|
| 5005 | admin RPC | **NO. 127.0.0.1 only. Never proxied.** |
| 21337 | peer | no — nodes peer outbound |
| 6006 | WebSocket | yes |
| 5007 | JSON-RPC | yes |

`ops/healthcheck.sh` probes 5005 from the network on every run and raises a
CRIT if anything answers. If that fires, the config is wrong and the node is
exposed — fix it before anything else.

Only a hub-role peer port would ever need forwarding at the router. API nodes
peer outbound only, so no inbound rule for 21337.

---

## Upstreams

| node | address | role | use |
|---|---|---|---|
| xah-node-2 | 192.168.1.111 | api | primary for general traffic |
| xah-node-1 | 192.168.1.110 | deep | deep queries only — see below |
| xah-node-3 | 192.168.1.112 | api | phase 2 |

**Weight toward node 2 for general traffic.** Keep node 1 out of the public
pool entirely until its latency is characterised, or route deep queries to it
explicitly. A deep node under backfill, or mid-rotation, is not something to
put in front of ordinary `account_info` traffic.

NPM's UI does not expose upstream pools directly — use a **Custom Nginx
Configuration** block on the proxy host for anything beyond a single upstream.

```nginx
# ── general traffic: the shallow api nodes ──────────────────────────────────
upstream xahau_rpc {
    least_conn;
    server 192.168.1.111:5007 max_fails=2 fail_timeout=20s;   # xah-node-2
    # server 192.168.1.112:5007 max_fails=2 fail_timeout=20s; # xah-node-3, phase 2
    keepalive 32;
}

# ── WebSocket: MUST be sticky. A subscribe is stateful. ─────────────────────
upstream xahau_ws {
    ip_hash;                       # source-IP stickiness
    server 192.168.1.111:6006 max_fails=2 fail_timeout=20s;
    # server 192.168.1.112:6006 max_fails=2 fail_timeout=20s;
    keepalive 32;
}

# ── deep history: node 1 only ───────────────────────────────────────────────
upstream xahau_deep {
    server 192.168.1.110:5007 max_fails=2 fail_timeout=30s;
    keepalive 8;
}
```

### WebSocket stickiness is not optional

A `subscribe` is stateful: the server holds the subscription for that
connection. Round-robin across an established WS connection breaks it — the
client subscribes on one backend and then gets messages from none.

Use **source-IP hash** (`ip_hash`, above) or a session cookie. Plain JSON-RPC
is stateless and can round-robin freely.

```nginx
location / {
    proxy_pass http://xahau_ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;

    # A subscription is a long-lived idle connection. Without these it is
    # dropped after 60s and clients see phantom disconnects.
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

### Routing deep queries

Deep requests go to node 1. There is no clean way to route on JSON-RPC method
in nginx without `mirror`/Lua, so expose it as a separate hostname or path and
document it:

```nginx
# https://xahau-deep.example.com/  -> node 1 only
location / {
    proxy_pass http://xahau_deep;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 120s;      # historical account_tx is slow
}
```

---

## Rate limiting — at the proxy, not only in xahaud

TLS terminates at NPM, so NPM is where the client is actually identifiable.
xahaud's own abuse accounting still matters (and is shared across the cluster
via `[cluster_nodes]`, which is one reason the nodes are clustered), but the
first line is here.

```nginx
# in the http{} context
limit_req_zone  $binary_remote_addr zone=xahau_rpc:10m rate=20r/s;
limit_conn_zone $binary_remote_addr zone=xahau_ws_conn:10m;

# in the RPC location
limit_req  zone=xahau_rpc burst=40 nodelay;
limit_req_status 429;

# in the WS location — connections, not requests
limit_conn xahau_ws_conn 10;
limit_conn_status 429;
```

Clustering means a client cannot hop backends to dodge xahaud's accounting.
Behind a load balancer that is the main operational reason to cluster at all.

---

## Health checks

Open-source nginx has no active upstream health checks, so `max_fails` /
`fail_timeout` (passive) is what you get. That is adequate for a hard failure
and inadequate for the case that actually matters: **a node that is up and
answering but has a broken `complete_ledgers` range**, or one mid-rotation and
not responsive.

`ops/healthcheck.sh` covers that from outside. If a node needs to come out of
the pool, comment it out of the upstream and reload.

Passive checks to set on every upstream: `max_fails=2 fail_timeout=20s`.

---

## Before telling anyone to use this

Two facts belong in `README.md`, and both are still unanswered:

1. **Upload bandwidth.** A public WS endpoint serving subscriptions is
   upload-heavy, and this is a home/office connection.
2. **Is the WAN IP static?** If not, this is a private endpoint that happens to
   be well built — not a community one people can put in app configs.

Until those are answered, treat this as an internal endpoint.
