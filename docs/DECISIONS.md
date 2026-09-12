# DECISIONS

Why this is built the way it is, and what is still unknown. Anything marked
**VERIFY** is a claim that must be replaced with a measurement before it is
relied on.

> **MEASUREMENT PENDING** — GB per million ledgers has not been measured yet.
> Run `make measure NODE=xah-node-1` once node 1 reports a stable
> `complete_ledgers` range, then `ops/measure.sh --record`. Every sizing
> decision below that says "unknown" resolves the moment that number exists.

---

## The one hard rule

**CT 200 on the R730xd (`pve`) is a live UNL validator.** It has its own RAID
and its own keys. Nothing in this repo references it, connects to it, clusters
with it, or copies its `node_seed`.

That is enforced, not just documented. `lib/guard.sh` refuses any operation
whose target matches the forbidden host names, the forbidden addresses, or the
forbidden VMIDs in `inventory.yml` — and `guard_require_host` trips hard if a
forbidden guest's config file is visible on the local node, which would mean a
script is standing on the validator host. `make guards` (35 assertions) fails
the build if any of that stops refusing.

The published Xahau UNL in `config/validators.txt` is unrelated: it is the
list of validators these nodes *trust*, and the validator's own keys never
appear in this repo.

---

## XFS on the database volumes, mandatory

Full history hits single-file size limits on other filesystems, and converting
later means a full resync — days of backfill to fix a five-second decision.
The volumes are formatted XFS now even though phase 1 is not full history,
because the cost of being wrong later is a resync and the cost of being right
now is nothing.

`provision/20-guest-bootstrap.sh` refuses to continue if the mounted DB volume
is not XFS.

## LVM everywhere, never raw partitions

Caps are raised with `lvextend` and then `xfs_growfs`, online, without
downtime. Raw partitions would mean a maintenance window every time the cap
moves, and the cap is expected to move — once at measurement, again on NVMe.

## `nofail` in fstab, and `LABEL=` not `/dev/sdb`

`nofail` is non-negotiable: a missing database disk must not wedge boot. A node
that boots without its database and reports the problem is recoverable over
ssh; a node that drops to an emergency shell needs console access.

Mounting by `LABEL=xahdb` rather than `/dev/sdb` because device ordering can
change when disks are added or moved — and phase 1.5 adds a disk.

## The database disk is attached AFTER the OS install

`provision/10-create-vm.sh` creates the VM with its root disk only and asserts
`scsi1` is absent. `provision/11-attach-db-disk.sh` hot-adds the database disk
afterwards, and Proxmox hot-plugs it with no reboot.

If the Ubuntu installer can see the database disk it can pull it into the root
LVM layout or offer to partition it. Unwinding that after the fact is
miserable, and the fix is usually a reinstall.

---

## The 700 GiB cap is an observation boundary, not a hardware limit

Disk is not the binding constraint on this host. The array is effectively
empty: ~1.69 TiB available, one guest consuming ~17 GB real.

| volume | size | note |
|---|---|---|
| `vm-100-disk-0` | 400 GiB | EXISTING, local Claude repo builder. DO NOT TOUCH. |
| `vm-110-disk-0` | 48 GiB | xah-node-1 root |
| `vm-110-disk-1` | 700 GiB | xah-node-1 DB, XFS — deep, capped |
| `vm-111-disk-0` | 48 GiB | xah-node-2 root |
| `vm-111-disk-1` | 300 GiB | xah-node-2 DB, XFS — api |
| **total provisioned** | **1496 GiB** | |
| pool physical | 1752 GiB | measured |
| **unprovisioned reserve** | **~256 GiB** | stays free |

The cap exists because growth is unknown and the volume sits on the same thin
pool as the other VMs. A runaway database there can exhaust the pool, and LVM
then **suspends volumes** rather than degrading gracefully. The filesystem size
is the enforcement mechanism: xahaud must hit ENOSPC on its own volume and
stop.

**The reserve is the real safety mechanism.** Because total provisioning sits
below pool physical capacity, every volume can fill to its cap without
exhausting the pool. `provision/01-space-check.sh` re-derives this from the
live `lvs` output and refuses to provision if the math stops working — and it
refuses if `inventory.yml`'s claimed pool size has drifted more than 32 GiB
from reality, so nobody proceeds on a stale number.

Raising the cap in phase 1 means `lvextend` + `xfs_growfs` **into the reserve
only**, with the no-overcommit math redone. On NVMe, freely from the
unallocated remainder.

### Metadata, not just data

`ops/growth-watch.sh --mode host` alerts on `data_percent` **and**
`metadata_percent`, both at 60% / 80%. Metadata exhaustion kills a thin pool
just as dead as data exhaustion and is the failure people do not see coming.

`thin_pool_autoextend_threshold` is set to 80 with
`thin_pool_autoextend_percent = 0` — **alert, do not autoextend**. This host
does not overcommit; growing the pool is a deliberate decision with the math
redone, not something LVM does quietly at 3am.

### A bigger cap makes monitoring more important, not less

More runway before the filesystem stops the node means more time for a problem
to go unnoticed. **700 GiB without `growth-watch.sh` running is worse than
500 GiB with it.** That is why `make host-prep` installs the monitoring before
the first node exists.

---

## `advisory_delete=1` and a cron job, instead of letting xahaud decide

`online_delete` is **count-based, not size-based**. There is no setting that
says "prune at 80% disk". So disk pressure drives pruning explicitly:
`advisory_delete=1` means nothing prunes until `can_delete` is called, and
`ops/prune-guard.sh` calls it from cron when the volume crosses a threshold.

This is the behaviour that keeps deep history without breaking: the window
rolls, the oldest ledgers fall off, the node keeps serving, and ENOSPC never
happens in normal operation. The filesystem cap is the backstop, not the
mechanism.

### Why 70% and not 90%

Online delete works by **rotation**: xahaud keeps a writable backend and an
archive backend, and reclaims space by dropping the old archive when it
rotates. Transient space for both is needed during rotation. Waiting until the
volume is nearly full can leave no room to perform the prune that would free
the room.

Trigger early. `prune-guard.sh` also shouts if fewer than 20 GiB remain when
it fires, because that is the point at which a rotation may not have room to
complete and a human is needed.

### Switching to `advisory_delete=0` later

Only once the window is known to fit with room to spare. Setting it to 0 hands
the timing to xahaud's internal schedule, which is count-driven and blind to
the volume. Until the measurement exists, disk pressure is the better signal.

### VERIFY ON FIRST ROTATION — three numbers, none of them from this document

1. **How much transient space the rotation actually consumes.** That number
   sets the real threshold. Adjust `cluster.thresholds.prune_trigger_pct` in
   `inventory.yml` from observation.
2. **Whether online delete also trims `transaction.db` and `ledger.db`,** or
   whether the SQLite side needs separate attention. If it does not, the
   SQLite files grow unbounded inside a capped volume and the cap gets hit by
   the wrong thing.
3. **How long a rotation takes and whether the node stays responsive
   through it.** If it is not responsive, it must come out of the public pool
   for the duration and the proxy needs a health check that notices.

`ops/prune-guard.sh` records before/after `complete_ledgers`, disk use and
elapsed time into `.state/prune-guard.state` on every run, which is where
those numbers come from. Write the answers here.

---

## SQLite `page_size`, at install and never later

```ini
[sqlite]
page_size=32768
journal_mode=wal
synchronous=normal
temp_store=file
```

With the default 4096 page size a history server can **exhaust its transaction
database even with free disk**, and the fix requires running `xahaud --vacuum`
before restart, which can take multiple days.

This is why `provision/20-guest-bootstrap.sh` deliberately does **not** start
xahaud: page size only applies to a fresh database, so the config has to be in
place before the first start. `ops/deploy-node.sh` installs the config and
then starts the service, in that order.

## `use_tx_tables` stays on

`account_tx` depends on it, and `account_tx` is the entire point of a public
history endpoint. The template renders `[use_tx_tables] 1` explicitly rather
than relying on the default, and both `render-config.sh` and
`deploy-node.sh` refuse to ship a config without it.

## `ledger_history` must stay below `online_delete`

Otherwise the node fetches history only to delete it again — endless backfill
churn that never converges. Checked in three places: `inventory.py check`,
`render-config.sh`, and `deploy-node.sh`.

| role | node_size | peers_max | online_delete | ledger_history | rendered initially |
|---|---|---|---|---|---|
| deep | huge | 40 | 4,000,000 | 3,500,000 | **2,000,000** |
| api | large | 30 | 600,000 | 500,000 | 500,000 |

The deep node starts at 2M purely to get a measurement in a reasonable window.
`make render HISTORY=final` raises it to 3.5M and warns loudly while this file
still says MEASUREMENT PENDING.

---

## Admin RPC never leaves localhost

`port_rpc_admin_local` binds `127.0.0.1` with `admin = 127.0.0.1`, and only
6006 (WS) and 5007 (RPC) are proxied. Three independent checks enforce it:
`render-config.sh` refuses to write a config with admin on `0.0.0.0`,
`deploy-node.sh` refuses to ship one, and `ops/healthcheck.sh` actively probes
port 5005 **from the network** and screams if anything answers.

## Clustering buys operational things, not trust

`[cluster_nodes]` gives shared load and fee-escalation state, shared client
abuse accounting, and relayed transactions that skip redundant signature
verification. Behind a load balancer the abuse accounting matters: a client
cannot hop backends to dodge rate limiting.

It has **no effect on consensus or trust**. That is the UNL, and these are
stock nodes.

`cluster/render-cluster-nodes.sh` reads each node's live `pubkey_node` and
regenerates every node's fragments, and it aborts if two nodes report the same
`pubkey_node` — which is almost always a copied `node_seed`.

## One public IP, so peer counts stay modest

xahaud limits inbound connections per source IP, and multiple instances behind
one address is not recommended upstream. `peers_max` is 40 (deep) and 30 (api),
and the nodes peer **outbound**. Do not set all three to aggressive peer counts
dialing the same hubs.

Only a hub-role peer port would need forwarding at the router. API nodes peer
outbound only.

## Seeding node 2 from node 1, not from the network

Backfilling each node independently is slow, unreliable on Xahau where the set
of deep peers is small, and rude to the peers serving it.

`ops/seed-node.sh` stops xahaud on both nodes first — a live NuDB copy is a
corrupt NuDB copy — and **excludes `wallet.db` from the rsync**, because
`wallet.db` holds the node identity when no `node_seed` is configured. Copying
it is exactly the mistake the script exists to prevent. It then verifies the
two nodes report different `pubkey_node` values before declaring success.

## Seeds

Generated with `validation_create` (`ops/gen-seed.sh`), unique per node, stored
in gitignored `secrets/seeds.env` and a password manager, injected at render
time. Never committed, never reused, never derived from the validator's key.

`ops/backup-config.sh` backs up configuration and a **manifest of which seed
variable belongs to which node** — plus that node's `pubkey_node`, so a
restored seed can be matched back and a swapped identity is detectable. It
redacts `[node_seed]` from every captured config and then greps the staged
archive for seed-shaped strings, aborting rather than shipping one.

---

## Open questions that block going public

Both need answers in `README.md` before anyone is told to put this in an app
config:

- **Upload bandwidth.** A public WS endpoint serving subscriptions is
  upload-heavy.
- **Is the WAN IP static?** If not, this is a private endpoint that happens to
  be well built, not a community one.

## Other things to verify rather than trust

- **The xahaud installer URL** in `inventory.yml`
  (`cluster.defaults.installer_url`) and its layout. Record its SHA256 in
  `XAHAUD_INSTALLER_SHA256` once known, so bootstrap stops running an unpinned
  script from the network.
- **The `validator_list_keys` and site** in `config/validators.txt`, against
  the currently published Xahau values. A stale key means the node never
  reaches `full`.
- **`pve`'s actual IP address** in `cluster.forbidden.host_addresses`. It is
  currently `192.168.1.121`, which is a placeholder. Correct it — never remove
  it.
- **Whether the installer's auto-update timer ever rewrites the config.**
  Bootstrap warns if the timer exists. Binary updates are fine; a config
  rewrite would silently undo everything here.

---

## Measurements

*Appended by `ops/measure.sh --record`. Nothing here yet.*
