# Original build spec

Preserved verbatim as the source of record for every decision in this repo.
Where this document and the code disagree, the code has moved on — check
`docs/DECISIONS.md` for what changed and why.

---

# Xahau Deep + Public Node Cluster — Build Spec

Build a repo that provisions and manages a Xahau node cluster on the R740 (pve2). Phase 1 is two nodes. Phase 2 adds a third after a RAM upgrade. Everything must be written so node 3 is a config addition, not a rebuild.

## Hard constraints — do not violate

- Never touch CT 200 on the R730xd (pve). That is a live UNL validator with its own RAID and its own keys. Nothing in this repo references it, connects to it, clusters with it, or copies its node_seed. If any script could plausibly reach it, add a guard.
- Every node gets a unique node_seed. Never reuse one. Never derive one from the validator's key. Generate with `validation_create` and store outside the repo (see Secrets).
- The deep node's database filesystem is capped at 700 GiB in Phase 1. This is a containment boundary while growth is unknown, and it sits on the same thin pool as the other VMs — a runaway database there can exhaust the pool and LVM will suspend volumes rather than degrade gracefully. The filesystem size is the enforcement mechanism: xahaud must hit ENOSPC on its own volume and stop. Total provisioning must never exceed pool physical capacity. No overcommit on this host.
- Pruning is a rolling window, active from day one. `online_delete` is set and `advisory_delete=1`, with `prune-guard.sh` firing `can_delete` on disk pressure. The node must never hit ENOSPC in normal operation — the filesystem cap is the backstop, not the mechanism.
- Admin RPC/WS bind to 127.0.0.1 only. Never exposed through the proxy.

## Hardware context

Host: R740, pve2, Proxmox VE 9.2-1, 192.168.1.120, iDRAC 192.168.1.105

- 2x Xeon Gold 6154 — 36C / 72T
- 128 GB DDR4 ECC now; 384 GB planned (12x 32 GB, all channels)
- PERC H740P (SAS3508, slot 6), RAID 10, VD0 = 1905.5 GB — VM OS disks only
- 8x 512 GB SATA SSD, all bays full, no hot spare, no expansion path
- X520 dual 10GbE SFP+ ; I350 dual 1GbE on rNDC
- PCIe: 8 slots, all Length: Long. x16 electrical = 1, 4, 8. x8 = 2, 3, 5, 7. Slot 6 in use (H740P).

Hardware NOT YET PRESENT — on order, arriving together:

- 4 TB M.2 NVMe (DRAM cache, 2000+ TBW) on a single-drive PCIe x4 adapter. Install in slot 2, 3, 5, or 7. Leave the x16 slots (1, 4, 8) free for a future GPU. Single-drive adapter means no bifurcation config needed.
- 12x 32 GB DDR4-2666 ECC RDIMM → 384 GB

Phase 1 builds on the R740 now, on the RAID 10. 128 GB RAM is enough for two nodes at 60 GB. The RAID 10 has roughly 1.3 TB free (VERIFY — see below), which is enough for a capped deep node plus an API node. The NVMe is a later migration, not a prerequisite.

Verified on pve2 (measured, not estimated):

```
local-lvm   lvmthin   1837621248 KiB total   18192450 used   1819428797 available   0.99%
data        pve  twi-aotz--  1.71t   Data% 0.99   Meta% 0.12
vm-100-disk-0    Vwi-aotz--  400.00g  data   Data% 4.34
local       dir        98497780 KiB total   7200284 used    7.31%
```

The array is effectively empty: ~1.69 TiB available, one guest on it consuming ~17 GB real. Metadata usage is negligible at 0.12%.

Disk is not the binding constraint on this host. See Storage layout for the full allocation: 1496 GiB provisioned against 1752 GiB physical, leaving a ~256 GiB unprovisioned reserve. The 700 GiB deep cap is a deliberate observation boundary while growth is unknown, not a hardware limit — raise it with `lvextend` + `xfs_growfs` whenever measured data justifies it, though only into the reserve and only with the no-overcommit math redone.

Do not touch the R730xd (pve). CT 200 there is the UNL validator.

Network: 192.168.1.0/24 flat. Reverse proxy is Nginx Proxy Manager in CT 100 on the R730xd (pve), already terminating TLS.

## Storage layout

### Phase 1 — thin pool local-lvm on pve2

Every node gets a separate database disk, never the root disk. The database disk's size is the containment boundary.

Allocation — no overcommit. Pool physical ≈ 1752 GiB.

```
local-lvm (thin, 1752 GiB physical)
├── vm-100-disk-0    400 GiB   EXISTING — local Claude repo builder. DO NOT TOUCH.
├── vm-110-disk-0     48 GiB   xah-node-1 root
├── vm-110-disk-1    700 GiB   xah-node-1 DB   XFS   ← deep, capped
├── vm-111-disk-0     48 GiB   xah-node-2 root
└── vm-111-disk-1    300 GiB   xah-node-2 DB   XFS   ← api
                    ─────────
   total provisioned 1496 GiB
   unprovisioned      ~256 GiB   ← reserve, stays free
```

The reserve is the real safety mechanism. Because total provisioning sits below pool physical capacity, every volume can fill to its cap without exhausting the pool. Do not provision into the reserve, and do not overcommit — if a node needs more, either raise a cap into the reserve deliberately with the math redone, or wait for the NVMe.

Thin provisioning warning. A pool that exhausts causes LVM to suspend volumes, not degrade gracefully. Watch `metadata_percent` as well as `data_percent` — metadata exhaustion kills a pool just as dead and is the failure people do not see coming. Set `thin_pool_autoextend_threshold` in `/etc/lvm/lvm.conf` and alert well before it matters.

A bigger cap means more runway before the filesystem stops the node, which makes the monitoring more important, not less. 700 GiB without `growth-watch.sh` running is worse than 500 GiB with it.

### Phase 1.5 — migrate to NVMe when it arrives

```
/dev/nvme0n1  (4 TB)
└── nvme-vg (LVM)
    ├── lv-xah1-db   1000G+  → xah-node-1  (deep)   XFS
    ├── lv-xah2-db    400G   → xah-node-2  (api)    XFS
    └── [remainder unallocated — node 3, and headroom to raise caps]
```

Migration per node: stop xahaud, `qm move-disk` or rsync the DB volume to the new LV, remount, start. One node at a time so the endpoint stays up. Faster disk, bigger cap, and the RAID 10 goes back to holding only OS disks.

LVM rather than raw partitions throughout so caps can be raised with `lvextend` + `xfs_growfs` online, without downtime, once growth is understood.

XFS is mandatory on the database volumes. Full history hits single-file size limits on other filesystems, and converting later means a full resync. Format XFS now even though phase 1 is not full history.

Attach the database disk AFTER the OS install, not at `qm create` time. Create each VM with its root disk only, install Ubuntu, then hot-add:

```bash
qm set 110 --scsi1 local-lvm:700,iothread=1,discard=on
```

Proxmox hot-plugs it and the guest sees `/dev/sdb` without a reboot (force a rescan with `echo "- - -" > /sys/class/scsi_host/host0/scan` if it does not appear). Doing it in this order means the Ubuntu installer never sees the database disk and cannot pull it into the root LVM layout or offer to partition it — a failure that is annoying to unwind after the fact.

Then, inside the guest:

```bash
mkfs.xfs -L xahdb /dev/sdb
mkdir -p /var/lib/xahaud
echo 'LABEL=xahdb /var/lib/xahaud xfs defaults,nofail 0 2' >> /etc/fstab
mount -a
```

`nofail` is non-negotiable. A missing database disk must not wedge boot.

Mount by `LABEL=`, never `/dev/sdb` — device ordering can change if disks are added or moved later.

Each VM therefore has exactly two disks: root and database. Two VMs in Phase 1, not four.

## VM sizing

### Phase 1 — two nodes, 128 GB host

| | xah-node-1 (deep) | xah-node-2 (api) |
|---|---|---|
| VMID | 110 | 111 |
| vCPU | 8 | 6 |
| RAM | 32 GB | 28 GB |
| Root disk | 48 GiB on local-lvm | 48 GiB on local-lvm |
| DB disk | 700 GiB on local-lvm | 300 GiB on local-lvm |
| node_size | huge | large |
| peers_max | 40 | 30 |
| Public? | yes | yes |

60 GB total. Leaves roughly 60 GB after host overhead and a PBS VM — enough that the Qwen 32B agent VM (48 GB minimum) still fits. That headroom is the reason phase 1 is two nodes and not three.

### Phase 2 — third node, after the 384 GB upgrade

| | xah-node-3 |
|---|---|
| VMID | 112 |
| vCPU | 8 |
| RAM | 32 GB |
| DB disk | new LV from NVMe free space |

~92 GB total. Also bump nodes 1 and 2 as appropriate once RAM is plentiful.

## Proxmox VM settings that matter

- `--cpu host` — the default kvm64 hides AES/SHA/AVX from the guest and signature verification takes a real hit.
- `--balloon 0` — fixed RAM. xahaud does not tolerate memory being reclaimed out from under it.
- `--scsihw virtio-scsi-single`, disks with `iothread=1,discard=on`
- `--onboot 1`
- Ubuntu 24.04 LTS guest.

## Repo structure

```
xahau-cluster/
├── README.md                     # quickstart, current phase, node inventory
├── Makefile                      # or justfile — thin wrappers over scripts
├── inventory.yml                 # single source of truth: nodes, IPs, ports, sizes
├── provision/
│   ├── 00-nvme-setup.sh          # host: pvcreate/vgcreate/lvcreate on nvme0n1
│   ├── 10-create-vm.sh           # host: qm create from inventory entry
│   └── 20-guest-bootstrap.sh     # guest: deps, user, XFS mount, dirs
├── config/
│   ├── xahaud.cfg.j2             # templated — one template, all roles
│   ├── validators.txt            # Xahau UNL config (published list, not ours)
│   └── roles/
│       ├── deep.yml              # ledger_history, node_size, peers_max
│       └── api.yml
├── cluster/
│   ├── render-cluster-nodes.sh   # builds [cluster_nodes] + [ips_fixed] for all
│   └── README.md                 # how to add node 3
├── ops/
│   ├── growth-watch.sh           # cron: db size, pool data%/meta%, alerts
│   ├── prune-guard.sh            # cron: can_delete on disk pressure
│   ├── measure.sh                # du + ledger range → GB per million ledgers
│   ├── seed-node.sh              # rsync a synced node's db to a new one
│   ├── healthcheck.sh            # server_info, complete_ledgers, peer count
│   └── backup-config.sh          # tar configs + seeds inventory (not seeds)
├── proxy/
│   └── npm-notes.md              # NPM upstream config, sticky WS, rate limits
└── docs/
    ├── RUNBOOK.md
    ├── PHASE-2.md                # exact steps to add node 3
    └── DECISIONS.md              # why XFS, why advisory_delete, why NVMe
```

`inventory.yml` drives everything. Adding node 3 should mean adding one entry and re-running two scripts.

## xahaud config

One Jinja template, role-driven. Xahau mainnet, NetworkID 21337.

### Common to all nodes

```ini
[network_id]
21337

[server]
port_rpc_admin_local
port_peer
port_ws_public
port_rpc_public

[port_rpc_admin_local]
port = 5005
ip = 127.0.0.1
admin = 127.0.0.1
protocol = http

[port_peer]
port = 21337
ip = 0.0.0.0
protocol = peer

[port_ws_public]
port = 6006
ip = 0.0.0.0
protocol = ws

[port_rpc_public]
port = 5007
ip = 0.0.0.0
protocol = http

[node_db]
type=NuDB
path=/var/lib/xahaud/db/nudb
advisory_delete=1
# online_delete is role-specific — see roles below

[database_path]
/var/lib/xahaud/db

[debug_logfile]
/var/log/xahaud/debug.log

[node_seed]
{{ node_seed }}            # from secrets, never committed

[ssl_verify]
1
```

`use_tx_tables` must stay on (default). `account_tx` depends on it, and `account_tx` is the entire point of a public history endpoint.

### Role: deep (xah-node-1)

```ini
[node_size]
huge

[peers_max]
40

[node_db]
online_delete=4000000

[ledger_history]
3500000
```

`ledger_history` must stay below `online_delete`, or the node fetches history only to delete it again.

Start the first backfill lower — `ledger_history=2000000` — purely to get a measurement in a reasonable window, then raise toward 3.5M once GB-per-million-ledgers is known and it is clear the window fits under 700 GiB.

### Role: api (xah-node-2)

```ini
[node_size]
large

[peers_max]
30

[node_db]
online_delete=600000

[ledger_history]
500000
```

Covers the overwhelming majority of real queries. Deep requests route to node 1.

### SQLite page size — do this at install, not later

With SQLite's default 4096 page size, a history server can exhaust its transaction database even with free disk, and the fix requires running `xahaud --vacuum` before restart, which can take multiple days. Set a larger page size at first start. Bake this into `20-guest-bootstrap.sh` and document it in DECISIONS.md so it is never quietly dropped.

## Cluster configuration

Phase 1 clusters two nodes; the mechanism is identical for three.

Each node's config gets every other node listed:

```ini
[cluster_nodes]
n9XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX  xah-node-2

[ips_fixed]
192.168.1.111 21337
```

Public keys come from `server_info` → `pubkey_node` on each running node. `render-cluster-nodes.sh` should read `inventory.yml`, query each node's `pubkey_node`, and regenerate every node's `[cluster_nodes]` and `[ips_fixed]` blocks. Adding node 3 = add to inventory, re-run, rolling restart.

What clustering buys here: shared load and fee escalation state, shared client abuse accounting, and transactions relayed between members skip redundant signature verification. Behind a load balancer that matters — a client cannot hop backends to dodge rate limiting. It has no effect on consensus or trust; that is the UNL, and these are stock nodes.

Peering note: all nodes share one public IP. xahaud limits inbound connections per source IP, so multiple instances behind one address is not recommended upstream. Keep `peers_max` modest as specified and let them peer outbound. Do not set all three to aggressive peer counts dialing the same hubs.

## The cap and growth monitoring

Phase 1 cap is 700 GiB, rising further once the database lives on NVMe. Enforced in three layers, deliberately redundant:

1. **Filesystem** — the DB volume is 700 GiB. Hard ceiling. xahaud stops rather than growing into the array that holds the other VMs.
2. **growth-watch.sh** — cron every 6h. Reports `df` on the DB volume, `du -sh` on the NuDB path, and thin-pool `data_percent` / `metadata_percent` on the host. Alert at 60%, loud alert at 80%, on either.
3. **ledger_history** — start at 2M, raise only after measuring.

### prune-guard.sh — the rolling window

`online_delete` is count-based, not size-based. There is no setting that says "prune at 80% disk." So disk pressure drives pruning explicitly: `advisory_delete=1` means nothing prunes until `can_delete` is called, and a cron job calls it when the volume crosses a threshold.

```bash
#!/usr/bin/env bash
# ops/prune-guard.sh — cron every 2h, inside each node VM
USE=$(df --output=pcent /var/lib/xahaud | tail -1 | tr -dc '0-9')
THRESHOLD=70
if [ "$USE" -ge "$THRESHOLD" ]; then
  logger -t xah-prune "DB volume at ${USE}% — firing can_delete now"
  /opt/xahaud/bin/xahaud --conf /etc/opt/xahaud/xahaud.cfg can_delete now
fi
```

Why 70% and not 90%. Online delete works by rotation: xahaud keeps a writable backend and an archive backend, and reclaims space by dropping the old archive when it rotates. Transient space for both is needed during rotation. Waiting until the volume is nearly full can leave no room to perform the prune that would free the room. Trigger early.

This is the behaviour that keeps deep history without breaking: the window rolls, oldest ledgers fall off, the node keeps serving, and ENOSPC never happens in normal operation. When the NVMe lands, `lvextend` + `xfs_growfs`, raise `online_delete`, and the window deepens with no resync.

Verify on first rotation — do not take these from the spec:

1. How much transient space rotation actually consumes. That number sets the real threshold; adjust THRESHOLD from observation.
2. Whether online delete also trims `transaction.db` and `ledger.db`, or whether the SQLite side needs separate attention.
3. How long a rotation takes and whether the node stays responsive through it.

Record all three in `docs/DECISIONS.md`.

### measure.sh

After node 1 reports a stable `complete_ledgers` range covering the full requested history:

```bash
du -sh /var/lib/xahaud/db/nudb
du -sh /var/lib/xahaud/db/*.db        # SQLite: transaction.db, ledger.db
# divide by (ledger range / 1e6) → GB per million ledgers
```

Write the result to `docs/DECISIONS.md`. Every subsequent sizing decision — whether full history fits, whether node 3 needs a bigger LV, whether the cap rises — depends on this number, and nobody currently knows it.

### Tuning the window once GB/million is known

- Raise `ledger_history` toward the deepest window that lands the database comfortably under the cap, keeping `online_delete` above it.
- Keep `advisory_delete=1` and let `prune-guard.sh` drive pruning from disk pressure. Switching to `advisory_delete=0` hands the timing to xahaud's internal schedule, which is count-driven and blind to the volume — only do that once the window is known to fit with room to spare.
- Raising the cap: `lvextend` + `xfs_growfs` online, no downtime. In Phase 1 only into the ~256 GiB reserve, with the no-overcommit math redone; on NVMe freely from the unallocated remainder.

## Seeding node 2 (and later node 3)

Do not backfill each node from the network independently. It is slow, unreliable on Xahau where the set of deep peers is small, and rude to the peers serving it.

`seed-node.sh` should:

1. Stop xahaud on the source node.
2. `rsync -aHAX --info=progress2` the NuDB directory plus `transaction.db` and `ledger.db` to the target.
3. Replace the target's `node_seed` with its own unique value. Guard this explicitly — a copied seed means two nodes with one identity on the network.
4. Start both.

## Public endpoint

Upstreams go into the existing Nginx Proxy Manager (CT 100). Document in `proxy/npm-notes.md`:

- TLS terminates at NPM. Rate limit there, not only in xahaud.
- WebSocket sessions must be sticky. A `subscribe` is stateful; round-robin across an established WS connection breaks it. Source-IP hash or session cookie. Plain JSON-RPC can round-robin freely.
- Weight toward node 2 for general traffic; route deep queries to node 1, or keep node 1 out of the public pool entirely until its latency is characterized.
- Only 6006 (WS) and 5007 (RPC) are proxied. 5005 stays on localhost.

Before going public, two facts need pinning down and recording in the README: upload bandwidth, and whether the WAN IP is static. Those decide whether this is a community endpoint people can put in app configs or a private one that happens to be well built. Also: only the hub-role peer port (if a hub is added later) needs forwarding at the router — API nodes peer outbound only.

`healthcheck.sh` should verify `complete_ledgers` on each node and alert if the lower bound advances unexpectedly — that is a node pruning when it should not be.

## Phase ordering

### Now — no new hardware required

1. Space check done — see Storage layout. 1496 GiB provisioned against 1752 GiB physical, ~256 GiB reserve held back. No overcommit.
2. Set `thin_pool_autoextend_threshold` and stand up `growth-watch.sh` before the node exists, not after. The monitoring is the safety net for running a growing database on the same array as everything else.
3. Build node 1 first — 700 GiB XFS DB volume, `ledger_history=2000000`, `advisory_delete=1`. Let it backfill. Not public yet.
4. `measure.sh`. Record GB-per-million-ledgers in `docs/DECISIONS.md`. This unblocks every later decision and nobody currently knows the number.
5. Build node 2, seed it from node 1 via `seed-node.sh`.
6. `render-cluster-nodes.sh`, rolling restart.
7. NPM upstreams, healthchecks, growth cron.
8. Set pruning bounds from measured data.

### When the NVMe arrives

1. Install in slot 2/3/5/7. Verify `/dev/nvme0n1`.
2. `00-nvme-setup.sh` — LVM, per-node LVs at their new larger caps.
3. Migrate DB volumes one node at a time; endpoint stays up throughout.
4. Raise `ledger_history` toward the real target now that disk is cheap.

### When the RAM arrives

384 GB. Node 3 per `docs/PHASE-2.md`; bump nodes 1 and 2 if useful.

## Secrets

`node_seed` values never enter the repo. Store in a gitignored `secrets/seeds.env` or a password manager, referenced by the template at render time. `backup-config.sh` backs up configs and an inventory of which seed belongs to which node — not the seeds themselves.

Add a `.gitignore` covering `secrets/`, `*.env`, `*.log`, and any rendered `xahaud.cfg` containing a real seed.
