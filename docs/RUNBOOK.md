# RUNBOOK

Operational procedures. Every command runs from the repo root on your
workstation unless it says otherwise.

> **Before anything else:** nothing in this repo touches CT 200 on the R730xd
> (`pve`). That is a live UNL validator. If a command here appears to be
> reaching it, stop — `lib/guard.sh` should have refused, and a guard that
> failed to refuse is a bug worth fixing before you continue.

---

## 0. Daily / weekly

```bash
make health            # server_info, complete_ledgers, peers, lower-bound drift
make growth            # df + du + thin pool data% and metadata%
make prune-status      # what prune-guard would do on each node right now
make backup            # configs + seed manifest (never the seeds)
```

Cron already runs the first three on the nodes and the host. These are for
looking, not for keeping things alive.

---

## 1. Phase 1 build, in order

### 1.1 Preflight the host — before any node exists

```bash
make check                       # inventory math + guard assertions
make host-check                  # READ-ONLY preflight on pve2
make space                       # no-overcommit check against live lvs
```

Run these from your workstation. You do **not** ssh to pve2 and you do not
install anything there: `ops/host-run.sh` stages this repo into a temp dir on
the host, runs the one command, and deletes it — success or failure. Every
`make` target that needs the hypervisor goes through it.

`host-check` only reports. It tells you whether `thin_pool_autoextend_*`
matches `inventory.yml` and prints the edit to make by hand if you want it,
because that setting is host-global and affects every guest on pve2, not just
this cluster's nodes. It also fails if it finds leftover `xahau-hub` residue on
the host.

The monitoring is the safety net for running a growing database on a shared
array — but it lives in the **guests**. `20-guest-bootstrap.sh` installs the
growth/prune/health crons inside each node, and the dashboard runs there too
(§1.6).

### 1.2 Create node 1

```bash
make create-vm NODE=xah-node-1          # root disk only, 48 GiB
```

Install Ubuntu 24.04 LTS on `scsi0`. Static `192.168.1.110/24`, gateway
`192.168.1.1`. Install `qemu-guest-agent` and your ssh key.

> With `--mode cloudinit` the addressing and key are already configured and you
> just `qm start 110`.

```bash
make attach-db NODE=xah-node-1          # hot-adds the 700 GiB DB disk
```

The disk is attached **after** the install so the installer can never pull it
into the root LVM layout. If the guest does not see `/dev/sdb`:

```bash
echo "- - -" > /sys/class/scsi_host/host0/scan
```

### 1.3 Bootstrap the guest

```bash
make bootstrap NODE=xah-node-1
```

Packages, sysctl, ulimits, the XFS volume (`mkfs.xfs -L xahdb`, fstab with
`nofail`, mounted by LABEL), the `xahaud` user, the binary, a systemd drop-in,
logrotate, and the prune/growth/health crons.

It deliberately does **not** start xahaud. SQLite `page_size` only applies to a
fresh database.

### 1.4 Mint a seed and deploy

xahaud must be running to answer `validation_create`. On a brand-new cluster
there is nothing running yet, so:

```bash
# start it once with no real seed, purely so it can mint one
ssh root@192.168.1.110 'systemctl start xahaud'
make seed NODE=xah-node-1               # validation_create -> secrets/seeds.env
make deploy NODE=xah-node-1             # render + install config + restart
```

`deploy` pre-flights the rendered file (admin on localhost, `advisory_delete=1`,
`ledger_history < online_delete`, a seed that is not any other node's), keeps
the previous config as `.bak.<stamp>`, then restarts and waits for
`server_info` to answer.

### 1.5 Let it backfill, then measure

```bash
make health NODE=xah-node-1
```

Wait for `server_state: full` and a `complete_ledgers` range covering roughly
the full 2,000,000 requested. Then:

```bash
make measure NODE=xah-node-1
# happy with it? record it into docs/DECISIONS.md on the node, then copy back:
make measure NODE=xah-node-1 RECORD=1
```

`ops/remote.sh` is the guarded way to run any of this repo's scripts on a
node — it wires up `XAH_REPO_ROOT` and `XAH_NODE` and routes the ssh through
`guard_reject_target`, so a typo can never become a connection to the
validator host:

```bash
ops/remote.sh xah-node-1 -- ops/prune-guard.sh --status
ops/remote.sh --all      -- ops/growth-watch.sh --mode guest
```

**This unblocks every later decision.** Until GB-per-million-ledgers is in
`docs/DECISIONS.md`, nobody knows whether the window can deepen, whether the
cap can rise, or how big node 3's LV needs to be.

### 1.6 Node 2, seeded from node 1

```bash
make create-vm NODE=xah-node-2
# install Ubuntu, then:
make attach-db NODE=xah-node-2
make bootstrap NODE=xah-node-2
ssh root@192.168.1.111 'systemctl start xahaud'
make seed    NODE=xah-node-2
make deploy  NODE=xah-node-2
```

Node 2 is a shallow api node (500k ledgers) with a 300 GiB cap, so copying a
deep 2M-ledger database onto it usually makes no sense — it would fill the
volume and the first rotation would throw most of it away. `seed-node.sh` says
so and asks. For a same-role copy (node 3 later, or a rebuild):

```bash
make seed-from FROM=xah-node-1 TO=xah-node-2
```

That stops both nodes, rsyncs excluding `wallet.db`, verifies node 2 still
carries its own seed, restarts both, and confirms the two report **different**
`pubkey_node` values.

### 1.7 Cluster them

```bash
make cluster              # read live pubkey_node values, write fragments
make cluster-deploy       # re-render + rolling restart, one node at a time
```

### 1.8 Go public

Add the upstreams to Nginx Proxy Manager in CT 100 — see `proxy/npm-notes.md`.
Only 6006 (WS) and 5007 (RPC). **5005 stays on localhost.**

Before telling anyone to use it, put two facts in `README.md`: upload
bandwidth, and whether the WAN IP is static.

---

## 2. Incidents

### 2.1 "DB volume at 85%"

```bash
make prune-status                       # is prune-guard actually firing?
make prune NODE=xah-node-1              # fire can_delete now
```

Then read `.state/prune-guard.state` on the node. If the last run says
`action=none` while the volume is above the threshold, pruning is **not
rolling** and that is the actual emergency — `growth-watch.sh` escalates this
case to CRIT for exactly that reason.

Things to check, in order:

1. `grep advisory_delete /etc/opt/xahaud/xahaud.cfg` — must be `1`.
2. `grep online_delete /etc/opt/xahaud/xahaud.cfg` — must be above
   `ledger_history`.
3. `journalctl -u xahaud | grep -i delete` — did a rotation start and fail?
4. Free space. A rotation needs transient room for both backends. Under ~20
   GiB it may not be able to complete, and firing `can_delete` again will not
   help.

If it genuinely cannot rotate in the space available, raise the cap into the
reserve — deliberately, with the math redone:

```bash
ssh root@192.168.1.120 'lvextend -L +100G pve/vm-110-disk-1'
ssh root@192.168.1.110 'xfs_growfs /var/lib/xahaud'   # online, no downtime
# then re-derive the no-overcommit math:
make space
```

### 2.2 "Thin pool at 80%"

This is more serious than a single volume filling. A pool that exhausts
**suspends volumes** — including `vm-100-disk-0`, the repo builder VM.

```bash
ssh root@192.168.1.120 'lvs -o lv_name,lv_size,data_percent,metadata_percent'
```

Watch `metadata_percent` as closely as `data_percent`. Metadata exhaustion
kills a pool just as dead.

Do not extend the pool casually — the reserve exists so the pool never needs
extending. If data% is climbing toward 80% with provisioning unchanged, a
database is growing past what was planned for; fix that, do not paper over it.

### 2.3 "The node is pruning when it should not be"

`healthcheck.sh` raises this when the lower bound of `complete_ledgers`
advances while the volume is well below the prune threshold and `prune-guard`
recorded no action. With `advisory_delete=1` that should be impossible.

```bash
ssh root@192.168.1.110 'grep -A1 node_db -A5 /etc/opt/xahaud/xahaud.cfg'
ssh root@192.168.1.110 'cat /opt/xahau-hub/.state/health-xah-node-1.state'
```

Something else is calling `can_delete`, or `advisory_delete` is not actually
1 in the running config (check for a stale `/opt/xahaud/etc/xahaud.cfg` that is
a real file rather than the symlink).

### 2.4 "server_state is stuck at connected or syncing"

Usually the UNL. `config/validators.txt` must carry the *currently published*
Xahau `validator_list_keys` and site; a stale key means the node can never
fetch the UNL and never reaches `full`.

```bash
ssh root@192.168.1.110 'grep -i "validator\|unl" /var/log/xahaud/debug.log | tail -40'
```

Also check peers. All nodes share one public IP and xahaud limits inbound
connections per source IP, so these peer **outbound** — if egress on 21337 is
blocked, nothing connects.

### 2.5 "amendment_blocked: true"

The binary is too old for the current amendment set. Update xahaud, keep the
config, restart. This is the one case where the installer's auto-update timer
is doing you a favour.

### 2.6 A node will not stop

NuDB flushes on shutdown and killing it mid-flush is how databases get
corrupted. The systemd drop-in sets `TimeoutStopSec=600` for that reason. Let
it take the ten minutes. Do not `kill -9`.

### 2.7 Two nodes report the same `pubkey_node`

One identity on two nodes. `cluster/render-cluster-nodes.sh` and
`seed-node.sh` both abort on this.

```bash
ssh root@192.168.1.111 'systemctl stop xahaud'
make seed NODE=xah-node-2          # mint a fresh one; it will ask to confirm
make deploy NODE=xah-node-2
make cluster-deploy                # every other node's fragments are now stale
```

### 2.8 Rebuilding a node from scratch

```bash
make backup                                   # if the node is still reachable
# recreate the VM, install Ubuntu, attach-db, bootstrap
# restore its seed from secrets/seeds.env or the password manager
make deploy NODE=xah-node-N
make seed-from FROM=<a healthy same-role node> TO=xah-node-N
make cluster-deploy
```

The config backup restores configuration, not identity and not ledger data.
You need the seed and a database source as well.

---

## 3. Changing the window

```bash
# 1. edit config/roles/deep.yml — raise ledger_history, keep online_delete above it
# 2. re-render and check what changed
make render NODE=xah-node-1 HISTORY=final
# 3. deploy with a restart
make deploy NODE=xah-node-1 HISTORY=final
# 4. watch it grow into the new window
make growth
```

`render-config.sh` warns and asks for confirmation if `HISTORY=final` is
requested while `docs/DECISIONS.md` still says MEASUREMENT PENDING. That prompt
exists because a deeper window than the cap can hold is how a node fills its
volume and stops.

---

## 4. Phase 1.5 — the NVMe arrives

See `docs/PHASE-2.md` for node 3. For the disk itself:

```bash
# install the x4 adapter in slot 2, 3, 5 or 7 — leave x16 (1, 4, 8) for a GPU
ssh root@192.168.1.120 'lspci | grep -i nvme; nvme list'
make nvme                               # pvcreate/vgcreate/lvcreate, on pve2
make migrate NODE=xah-node-1            # one node at a time
make health
# only once it has been good for a few hours:
ssh root@192.168.1.120 'qm set 110 --delete unused0'
make migrate NODE=xah-node-2
```

`migrate-to-nvme.sh` checks that another node is still serving before it takes
one down, and keeps the original volume as an unused disk until you drop it
yourself.

---

## 5. Manual reference

For when a script is not the right tool.

```bash
# admin RPC, on the node (localhost only, by design)
curl -s -H 'content-type: application/json' \
  --data '{"method":"server_info","params":[{}]}' http://127.0.0.1:5005/ | jq .result.info

# public RPC, from anywhere
curl -s -H 'content-type: application/json' \
  --data '{"method":"server_info","params":[{}]}' http://192.168.1.110:5007/ | jq .result.info.complete_ledgers

# sizes
du -sh /var/lib/xahaud/db/nudb
du -sh /var/lib/xahaud/db/*.db
df -h /var/lib/xahaud

# thin pool, on pve2
lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent

# service
systemctl status xahaud
journalctl -u xahaud -f
tail -f /var/log/xahaud/debug.log
```
