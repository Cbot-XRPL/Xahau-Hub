# Xahau Deep + Public Node Cluster

Provisions and manages a Xahau mainnet node cluster on the **R740 (`pve2`)**.
One deep-history node, one public API node, clustered, behind the existing
reverse proxy. Node 3 is already written into the inventory and disabled — when
the RAM and NVMe arrive it is a config change, not a rebuild.

```
                      ┌──────────────────────────────────────────┐
   internet ──TLS──▶  │  Nginx Proxy Manager — CT 100 on pve     │
                      │  (already exists. NOT managed here.)     │
                      └────────────────┬─────────────────────────┘
                            ws 6006 / rpc 5007   (5005 never leaves localhost)
                      ┌────────────────┴─────────────────────────┐
                      │  R740 · pve2 · 192.168.1.120             │
                      │                                          │
                      │  xah-node-1   vmid 110   deep   700 GiB  │
                      │  xah-node-2   vmid 111   api    300 GiB  │
                      │  xah-node-3   vmid 112   api    (phase 2)│
                      └──────────────────────────────────────────┘
```

---

## The one hard rule

> **CT 200 on the R730xd (`pve`) is a live UNL validator.** It has its own RAID
> and its own keys. Nothing in this repo references it, connects to it,
> clusters with it, or copies its `node_seed`.

This is enforced in code, not just written down. `lib/guard.sh` refuses any
operation whose target matches the forbidden host names, addresses or VMIDs in
`inventory.yml`, and trips hard if a forbidden guest's config is visible on the
local node — which would mean a script is standing on the validator host.

```bash
make guards      # 35 assertions. Fails the build if a guard stops refusing.
```

---

## Current phase and status

| | |
|---|---|
| **Phase** | 1 — two nodes on the RAID 10 thin pool |
| **Host** | R740, `pve2`, PVE 9.2-1, 192.168.1.120 (iDRAC 192.168.1.105) |
| **CPU / RAM** | 2x Xeon Gold 6154, 36C/72T · 128 GB now, 384 GB planned |
| **Storage** | PERC H740P RAID 10, VD0 1905.5 GB · `local-lvm` thin pool, 1752 GiB |
| **Provisioned** | 1496 GiB of 1752 GiB — **~256 GiB unprovisioned reserve, no overcommit** |
| **GB per million ledgers** | **NOT YET MEASURED** — `make measure NODE=xah-node-1` |
| **Public endpoint** | **LIVE** — `https://cluster.cbotlabs.xyz` (RPC) · `wss://ws-cluster.cbotlabs.xyz` (WS) |
| **Public path** | Cloudflare Tunnel `onexah` → nginx rate limiter → xah-node-2. NPM is not in the path. |
| **Rate limit** | **LIVE** — 15 req/s + burst 30 per client, 8 WS connections. Verified: 178 req/s in → 43 served, 157 × 429. |
| **WAN IP static?** | **MOOT** — a tunnel dials out; the WAN IP is never published |
| **Upload bandwidth** | **UNKNOWN — still the open question before going public** |

The tunnel settles the addressing question: there is no port forward and no
published IP, so it does not matter whether the WAN address changes. What it
does not settle is **upload**. A public WS endpoint serving subscriptions is
upload-heavy, and the tunnel carries that traffic over the same home
connection. Measure it before telling anyone to put this in an app config.

Verified end to end 2026-09-13: `server_info`, `fee`, `ledger`, `ledger_current`,
`ledger_closed`, `account_info`, `account_tx` and `ping` all return `success`
over the public name; the WebSocket upgrades to `101` and pushes live
`ledgerClosed` events; `can_delete` and `stop` return **403**, and the admin
port refuses connections from the network.

NPM was removed from the path deliberately — it builds a TLS server block only
once a hostname has a certificate, and an HTTP-01 challenge cannot reach a
hostname that has no server block, so a new tunnel-fronted hostname can never
obtain one. xahaud needs none of NPM's features, so the tunnel routes straight
to the node and Cloudflare terminates TLS.

See `proxy/npm-notes.md` for the full path and the failure modes that cost the
most time.

### Node inventory

| | xah-node-1 | xah-node-2 | xah-node-3 |
|---|---|---|---|
| VMID | 110 | 111 | 112 |
| role | deep | api | api *(phase 2)* |
| address | 192.168.1.110 | 192.168.1.111 | 192.168.1.112 |
| vCPU / RAM | 8 / 32 GB | 6 / 28 GB | 8 / 32 GB |
| root disk | 48 GiB `local-lvm` | 48 GiB `local-lvm` | 48 GiB `local-lvm` |
| DB disk | **700 GiB** XFS | 300 GiB XFS | 400 GiB XFS on NVMe |
| node_size | huge | large | large |
| peers_max | 40 | 30 | 30 |
| online_delete | 4,000,000 | 600,000 | 600,000 |
| ledger_history | 3,500,000 *(starts at 2,000,000)* | 500,000 | 500,000 |
| public | yes — deep queries only | yes — primary | yes |

60 GB of node RAM in phase 1. That leaves roughly 60 GB after host overhead and
a PBS VM, which is enough that the 48 GB Qwen agent VM still fits. **That
headroom is why phase 1 is two nodes and not three.**

---

## Quickstart

```bash
make help                    # every target, plus the live node inventory
make check                   # inventory math, no-overcommit, 35 guard assertions
```

Phase 1 build, in order — full detail in `docs/RUNBOOK.md`:

```bash
make host-check                         # READ-ONLY preflight on pve2. Changes nothing.
make create-vm  NODE=xah-node-1         # root disk only — installer must not see the DB disk
#   ... install Ubuntu 24.04 ...
make attach-db  NODE=xah-node-1         # hot-add the 700 GiB DB disk
make bootstrap  NODE=xah-node-1         # XFS by LABEL, xahaud, crons. Does NOT start it.
make seed       NODE=xah-node-1         # validation_create -> secrets/seeds.env
make deploy     NODE=xah-node-1         # install config, THEN start
make measure    NODE=xah-node-1         # once backfill is stable ← unblocks everything
#   ... then node 2 ...
make seed-from  FROM=xah-node-1 TO=xah-node-2
make cluster-deploy
make health
```

---

## How it is put together

**`inventory.yml` is the single source of truth.** Nodes, addresses, VMIDs,
sizes, ports, thresholds, the forbidden-target list, and the NVMe layout all
live there. Every script reads it. Adding node 3 means adding one entry and
re-running two scripts.

```
inventory.yml           ← nodes, sizes, ports, thresholds, guard list, NVMe plan
├── provision/
│   ├── 00-nvme-setup.sh        host, phase 1.5: pvcreate/vgcreate/lvcreate
│   ├── 01-space-check.sh       host: no-overcommit gate, run this first
│   ├── 05-host-check.sh        host: READ-ONLY preflight — reports, never writes
│   ├── 10-create-vm.sh         host: qm create, ROOT DISK ONLY
│   ├── 11-attach-db-disk.sh    host: hot-add the DB disk AFTER the OS install
│   └── 20-guest-bootstrap.sh   guest: deps, XFS, user, xahaud, systemd, crons
├── config/
│   ├── xahaud.cfg.j2           one template, role-driven
│   ├── render-config.sh        template + role + inventory + seed + cluster blocks
│   ├── validators.txt          published Xahau UNL (not ours — VERIFY the key)
│   └── roles/{deep,api}.yml    node_size, peers_max, online_delete, ledger_history
├── cluster/
│   └── render-cluster-nodes.sh builds [cluster_nodes] + [ips_fixed] from live pubkeys
├── ops/
│   ├── prune-guard.sh          cron 2h: can_delete on disk pressure  ← the rolling window
│   ├── growth-watch.sh         cron 6h: df/du + thin pool data% AND metadata%
│   ├── measure.sh              GB per million ledgers
│   ├── seed-node.sh            rsync a synced DB to a new node, seed guard enforced
│   ├── healthcheck.sh          server_info, complete_ledgers, lower-bound drift
│   ├── deploy-node.sh          push config + ops tooling, restart, wait
│   ├── gen-seed.sh             validation_create, uniqueness enforced
│   ├── migrate-to-nvme.sh      phase 1.5, one node at a time
│   ├── remote.sh               run any of these ON a node, through the guards
│   ├── host-run.sh             stage on pve2 for ONE command, then delete it
│   └── backup-config.sh        configs + seed MANIFEST (never the seeds)
├── dashboard/
│   ├── xah-dashboard.py        read-only monitor, stdlib only, systemd IN a node
│   ├── install.sh              push + unit + start + /healthz gate
│   └── static/                 one page, no build step, no CDN, no webfonts
├── lib/                        inventory parser, renderer, guards, rpc, logging
├── tests/guard-test.sh         35 assertions — `make guards`
├── proxy/npm-notes.md          NPM upstreams, sticky WS, rate limits
└── docs/
    ├── RUNBOOK.md              build order, incidents, manual commands
    ├── DECISIONS.md            why XFS, why advisory_delete, why the cap, what to VERIFY
    ├── PHASE-2.md              exact steps to add node 3
    └── SPEC.md                 the original build spec
```

No external dependencies. `lib/inventory.py` uses PyYAML when it is installed
and falls back to a parser for the subset `inventory.yml` is written in, so
nothing needs installing on a Proxmox host or a fresh Ubuntu guest.

---

## Monitoring dashboard

```sh
make dashboard          # install or restart it inside its node
make dashboard-status   # is it up, and where
```

Then open **http://192.168.1.110:8088/** on the LAN.

It runs **inside a node VM**, never on the Proxmox host. pve2 also runs guests
this repo does not own, so nothing of ours is resident there: no packages, no
systemd unit, no cron, no open port, no copy of this repo. The collector
enforces it too — it refuses to start if it detects `/etc/pve` or `qm`.

One page, refreshed every 20s by a collector thread: overview tiles and a card
per node. Each instance reads **its own node locally** and any peer **over
guarded ssh**, so a card means the same thing either way. While the cluster is
still being built it doubles as the build tracker — each node shows where it is
in the seven provisioning stages, from `Guest reachable` through
`Synced to network`, so the answer to "is node 2 up yet" is a glance rather
than four ssh sessions.

Install one instance per node and each can tell you the other died:

```sh
./dashboard/install.sh --node xah-node-1 --enable-peer-probe
./dashboard/install.sh --node xah-node-2 --enable-peer-probe
```

`--enable-peer-probe` mints a dedicated ed25519 key on the dashboard node and
authorises it on the peers, restricted by `from=` and stripped of pty and
forwarding. It widens node-to-node trust, so it is an explicit flag and never
happens on its own.

It is **read only by construction**:

* only `GET`/`HEAD` are answered — every other method is `405`
* every probe is a fixed command string in the source, never anything derived
  from a request
* every ssh destination goes through the same forbidden-target check the shell
  scripts use, so it can no more reach the validator host than `ops/` can
* static files are sandboxed to `dashboard/static/`

It is **not** proxied and **not** public. It shows operational detail and has
no authentication, so it binds to the LAN only and stays off NPM. Change the
port in `inventory.yml → cluster.monitoring`.

Because it lives in a guest it does **not** report the thin pool — that is a
host fact. `make growth MODE=host` stages itself on pve2 for one command and
deletes itself again.

`--once` prints the whole collected state as JSON and exits, which is the
quickest way to see what the page is working from:

```sh
./dashboard/xah-dashboard.py --once | less
curl -s http://192.168.1.110:8088/api/state | jq .
curl -s http://192.168.1.110:8088/healthz
```


---

## The five things that keep this from breaking

**1. The reserve, not the cap.** 1496 GiB provisioned against 1752 GiB
physical. Because total provisioning sits below pool capacity, every volume can
fill to its cap without exhausting the pool — and an exhausted thin pool
**suspends volumes**, it does not degrade gracefully.
`provision/01-space-check.sh` re-derives this from live `lvs` output and
refuses to provision if the math stops working.

**2. Pruning is active from day one.** `online_delete` is count-based; there is
no "prune at 80% disk" setting. So `advisory_delete=1` holds all pruning until
`can_delete` is called, and `ops/prune-guard.sh` calls it from cron at 70%.
**70%, not 90%**, because rotation needs transient space for both the writable
and the archive backend — waiting until nearly full can leave no room to
perform the prune that would free the room.

**3. The filesystem cap is the backstop, not the mechanism.** The DB volume is
700 GiB so that xahaud hits ENOSPC on *its own volume* and stops, rather than
growing into the array that holds the other VMs. In normal operation it should
never get there.

**4. The monitoring lives in the guests, not on the hypervisor.** A bigger cap
means more runway before the filesystem stops the node, which makes monitoring
*more* important, not less — **700 GiB without growth-watch running is worse
than 500 GiB with it.** So `20-guest-bootstrap.sh` installs the growth, prune
and health crons inside each node, and the dashboard runs there too. pve2 gets
nothing resident: `make host-check` only reports, and `make growth MODE=host`
stages itself for one command and deletes itself. Guest-side growth-watch
alerts on the DB volume; the thin pool's `metadata_percent` — which kills a
pool just as dead as `data_percent` and is the failure people do not see
coming — is checked on demand from `make space` and `make growth MODE=host`.

**5. Admin RPC never leaves localhost.** Enforced three times over:
`render-config.sh` will not write a config with admin on `0.0.0.0`,
`deploy-node.sh` will not ship one, and `healthcheck.sh` actively probes port
5005 from the network and raises a CRIT if anything answers.

---

## Secrets

`node_seed` values never enter the repo. They live in gitignored
`secrets/seeds.env` (mode 0600) and a password manager, and are injected at
render time. One unique seed per node, generated with `validation_create`.

`make seeds` shows which nodes have one stored without printing any values.
`ops/backup-config.sh` backs up configuration and a manifest of which seed
belongs to which node — then greps the staged archive for seed-shaped strings
and aborts rather than shipping one.

---

## What is not measured yet

Read `docs/DECISIONS.md` for the full list. The ones that matter:

- **GB per million ledgers.** Unknown. `make measure NODE=xah-node-1` once the
  first backfill is stable. Every later sizing decision depends on it, which is
  why `ledger_history` starts at 2M rather than 3.5M — to get a measurement in
  a reasonable window.
- **What a rotation actually costs.** Transient space consumed, whether it also
  trims `transaction.db` / `ledger.db`, and whether the node stays responsive
  throughout. `prune-guard.sh` records before/after state on every run, which is
  where those answers come from. The 70% threshold should be adjusted from
  observation, not left at the spec value.
- **`pve`'s real IP address**, currently a placeholder in
  `cluster.forbidden.host_addresses`. Correct it — never remove it.
- **The xahaud installer URL and its SHA256**, and the published Xahau
  `validator_list_keys` in `config/validators.txt`.

---

## Phases

| | what arrives | what changes |
|---|---|---|
| **1** *(now)* | nothing | two nodes on the thin pool, 700 GiB capped deep node, pruning active |
| **1.5** | 4 TB NVMe, x4 adapter in slot 2/3/5/7 | `make nvme`, then `make migrate NODE=...` one at a time; bigger caps, faster disk, RAID 10 back to OS disks only |
| **2** | 12x 32 GB → 384 GB | `enabled: true` on node 3, then create/bootstrap/seed/deploy/cluster. See `docs/PHASE-2.md`. |

Leave the x16 slots (1, 4, 8) free for a future GPU. Slot 6 holds the H740P.
