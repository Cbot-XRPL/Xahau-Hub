# Public endpoint — Nginx Proxy Manager (CT 100)

The reverse proxy already exists: **Nginx Proxy Manager in CT 100 on the
R730xd (`pve`)**, already terminating TLS.

> **This repo does not provision, modify or connect to CT 100.** It lives on
> the same host as CT 200, the UNL validator, and `lib/guard.sh` refuses to
> reach that host at all. Everything below is done **by hand in the NPM UI**.
> These are the settings, not an automation.

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
