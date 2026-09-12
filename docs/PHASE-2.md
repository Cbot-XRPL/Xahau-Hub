# PHASE 2 — adding node 3

**Node 3 is a config addition, not a rebuild.** Everything in this repo is
written so that adding it means editing one inventory entry and re-running two
scripts.

---

## Prerequisites — both, not either

| requirement | why | how to confirm |
|---|---|---|
| 384 GB RAM installed (12x 32 GB, all channels) | phase 1's 60 GB of node RAM plus host overhead, a PBS VM and the 48 GB Qwen agent VM already accounts for 128 GB. A third 32 GB node does not fit. | `ssh root@192.168.1.120 'free -g; dmidecode -t memory \| grep -c "Size: 32 GB"'` |
| the 4 TB NVMe installed and `nvme-vg` created | node 3's DB comes from NVMe free space. Adding a third database to the RAID 10 thin pool would eat the reserve, and the reserve is the thing that stops a pool exhaustion from suspending every VM on the host. | `ssh root@192.168.1.120 'vgs nvme-vg'` |

If only the RAM has arrived, you *can* run node 3 off the thin pool — but only
by deliberately provisioning into the ~256 GiB reserve, which removes the
safety margin for all three nodes. Do the arithmetic in
`provision/01-space-check.sh` first and understand what you are giving up. The
script will refuse until `cluster.host.reserve_gib` is lowered by hand, and
that refusal is the point.

---

## Steps

### 1. Flip the inventory entry

`inventory.yml` already contains node 3. Change one field:

```yaml
  - name: xah-node-3
    vmid: 112
    role: api            # or deep — see "choosing the role" below
    phase: 2
    enabled: true        # <-- this is the change
    address: 192.168.1.112
    vcpu: 8
    ram_mb: 32768
    db_gib: 400          # raise it if the NVMe has room and the role is deep
    db_storage: nvme-vg
```

Also bump `cluster.phase` to `2`, and add the LV to `nvme.volumes` so
`00-nvme-setup.sh` and `migrate-to-nvme.sh` know about it:

```yaml
nvme:
  volumes:
    - node: xah-node-3
      lv: lv-xah3-db
      size_gib: 400
```

Then:

```bash
make check        # re-derives the allocation math with node 3 included
```

### 2. Create the LV and the VM

```bash
make nvme                          # creates lv-xah3-db from the remainder
make create-vm NODE=xah-node-3     # root disk on local-lvm, 48 GiB, no DB disk
# install Ubuntu 24.04, static 192.168.1.112/24
make attach-db NODE=xah-node-3     # attaches the NVMe volume as scsi1
make bootstrap NODE=xah-node-3     # XFS, xahaud, crons
```

### 3. Its own unique seed — no exceptions

```bash
ssh root@192.168.1.112 'systemctl start xahaud'   # so it can answer validation_create
make seed NODE=xah-node-3                          # -> XAH_NODE_3_SEED in secrets/
make deploy NODE=xah-node-3
```

Never copy node 1's or node 2's seed. `ops/seed-node.sh` and
`cluster/render-cluster-nodes.sh` both abort if two nodes end up with one
identity, but the cheapest place to get this right is here.

### 4. Seed its database from a same-role node

```bash
make seed-from FROM=xah-node-2 TO=xah-node-3   # api -> api
```

Do not backfill it from the network. Xahau has few deep peers and
independently backfilling a third node is slow, unreliable, and rude to the
peers serving it.

### 5. Re-cluster — this is the part that must not be skipped

```bash
make cluster-deploy
```

Clustering is symmetric. Until this runs, nodes 1 and 2 do not know node 3
exists, and node 3's own `[cluster_nodes]` is empty. A node that is not in
every other node's list is not clustered at all — it does not share load
state, and a client can hop to it to dodge rate limiting.

The rolling restart goes one node at a time so the public endpoint stays up.

### 6. Proxy and monitoring

Add node 3 as an upstream in NPM (`proxy/npm-notes.md`). WebSocket sessions
must stay sticky — a `subscribe` is stateful and round-robin across an
established connection breaks it.

```bash
make health
make growth
```

---

## Choosing the role

`inventory.yml` has node 3 as `api`, which is the safe default: a second
shallow node doubles general-query capacity and gives the proxy somewhere to
fail over to.

Make it `deep` instead if, and only if, the measurement in
`docs/DECISIONS.md` says two deep windows fit comfortably on the NVMe. Two
deep nodes means deep queries stop being a single point of failure, which is
the main weakness of the phase 1 layout — node 1 is the only thing that can
answer a historical `account_tx`.

Either way, keep `ledger_history` below `online_delete`, and size the LV from
the measured GB-per-million-ledgers rather than from a guess.

---

## Also worth doing once RAM is plentiful

- Raise `ram_mb` on nodes 1 and 2. `node_size: huge` benefits from more than
  32 GB, and at 384 GB total there is room.
- `balloon` stays `0`. xahaud does not tolerate memory being reclaimed out from
  under it, and that does not change because there is more of it.
- Revisit `peers_max`. All nodes still share one public IP and xahaud still
  limits inbound connections per source IP, so more RAM is not a reason to
  dial the same hubs harder. Raise it only if peer counts are genuinely low.
- Re-run `make measure` on node 1. A deeper window changes the GB/million
  figure, because the SQLite share and the NuDB share do not scale identically.

---

## What does NOT change in phase 2

- Nothing gains access to CT 200 on the R730xd. Node 3 is on pve2, clusters
  only with nodes 1 and 2, and `lib/guard.sh` still refuses the validator host
  by name, by address and by VMID.
- Admin RPC stays on 127.0.0.1. Only 6006 and 5007 are proxied.
- `advisory_delete=1` and `prune-guard.sh` still drive pruning from disk
  pressure. A bigger, faster disk makes the window deeper, not the monitoring
  optional.
