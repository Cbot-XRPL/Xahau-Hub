# Backups and disaster recovery

Established 2026-10-01. Before this date neither host had any backup job at all.

## What exists

**Proxmox Backup Server** runs as CT 113 (`pbs`) on pve2 (R740), at
`192.168.1.30:8007`, datastore `main` on a 98 GB mount at `/datastore`.

It is an LXC container, not a VM. Three attempts at a Debian cloud-image VM
failed first (`genericcloud` never started sshd; `generic` booted and then lost
networking to cloud-init `package_upgrade: true`, leaving a `pbs login:` prompt
on a host with no route). The container was up and serving in under a minute.

### Why PBS lives on the 740 and not the 730

The stated recovery goal is that the R730's guests can be respun on the R740 if
the R730 fails. Backups therefore have to be resident on the machine that would
do the respinning. The 730 pushes to PBS; nothing is installed on the 730 beyond
a storage entry, and in particular no agent runs on the validator host.

## Jobs on pve2

| job | guests | target | schedule | retention |
| --- | --- | --- | --- | --- |
| `backup-nightly` | 100, 110, 111 | `pbs-main` | 03:00 | 7 daily, 4 weekly, 3 monthly |
| `backup-pbs-self` | 113 | `local` | 02:30 | last 2 |

`backup-pbs-self` deliberately targets `local` and not PBS. A backup server
whose only backup is inside itself is not a backup.

Inside PBS: garbage collection daily at 04:30, verify job `v-main` Saturdays at
05:00 (`ignore-verified`, `outdated-after 30`). Without the GC schedule, pruned
snapshots never release their chunks and the datastore fills even though the
snapshot list looks short.

## What is NOT backed up, on purpose

Both nodes' database volumes carry `backup=0`:

    scsi1: local-lvm:vm-110-disk-1,backup=0,...,size=700G
    scsi1: local-lvm:vm-111-disk-1,backup=0,...,size=300G

Ledger data is re-syncable from the network and a rolling window is discarded
every rotation anyway; there is no value in a 700 GiB snapshot of it. What
cannot be re-fetched is the OS disk: `/etc/opt/xahaud/xahaud.cfg` and the
`node_seed` inside it. That is on `scsi0`, which is backed up.

Measured first run: 496 GiB of guest disks reduced to 14 GB on the datastore
(ai-hub 400 GiB reused 92%, each node 48 GiB reused ~88%).

## Adding the R730

Run on pve (R730) — these do not touch CT 200's configuration:

    pvesm add pbs pbs-740 \
      --server 192.168.1.30 --datastore main \
      --username 'backup@pbs!pve730' \
      --password '<token secret, see pve2:/root/.xahau-hub/pbs-pve730-token.json>' \
      --fingerprint 92:cf:12:76:ba:8c:c2:fc:49:5e:08:e7:48:27:cd:d7:90:7c:22:b4:b4:4f:40:c9:f6:eb:47:db:2d:a8:32:99 \
      --content backup

The 730 uses its own API token (`backup@pbs!pve730`), separate from the 740's
password credential, so either host can be revoked without affecting the other.
Both are scoped to `DatastoreBackup` on `/datastore/main` only.

One consequence worth stating explicitly: a backup of CT 200 places the
validator's `node_seed` in the datastore on the 740. That is the price of being
able to respin it there, but it means the PBS datastore is now key material and
should be treated as such.

## Address allocation: a trap worth recording

PBS was first assigned 192.168.1.115. It installed fine and could reach the
internet, but pve2 could not connect to it: `Connection refused` on 8007, and
ping failing and then succeeding depending on ARP state.

The service never restarted and never stopped listening on `*:8007`. The
address was simply already in use. With the container's `eth0` taken down,
192.168.1.115 still ARP-resolved — to `ac:27:6e:4a:90:24`, a physical device in
the router's DHCP pool that drops ICMP but answers TCP with a reset. Hence
"refused" rather than a timeout, which is the detail that gives it away.

An ARP sweep from inside the container showed .113, .117, .118 and .119 equally
occupied: the DHCP pool is the .100 range, and every static address this project
has handed out (.110, .111, .112, .120, .176) sits inside it. They have worked
so far on luck. .20-.30 and .240-.248 answered nothing on any probe, so PBS was
moved to .30 and verified with five silent probes before assignment.

Probe with ARP, not ping. The device that caused this was invisible to ping.

## Measured capacity, both hosts (2026-10-01)

### R730 (pve) — the machine with the disk

| storage | type | physical | used |
| --- | --- | --- | --- |
| `local-lvm` | lvmthin | 21.7 TiB | 324 GiB (1.5%) |
| `ssd` | lvmthin | 7.25 TiB | 959 GiB (12.9%) |
| `backup` | dir | 7.22 TiB | 135 GiB |
| `local` | dir | 94 GiB | 72 GiB — **77% full** |

Nine guests: VMs 101-107 (1000 GiB each except 107 at 500) on `local-lvm`,
CT 100 (NPM, 4 GiB) and CT 200 (the validator, 7500 GiB rootfs) on `ssd`.

Provisioned vs physical:

- `local-lvm`: 6500 of 21.7 TiB. Comfortable.
- `ssd`: 7504 GiB provisioned against 7419 GiB physical. **Overcommitted by
  ~85 GiB (1.1%)**, entirely because CT 200's rootfs is provisioned at 7500 GiB.
  At 12.9% used this is nowhere near biting, and a validator will never need
  7.5 TB. But it is worth knowing: if that rootfs ever did fill, the thin pool
  would exhaust physical space before the filesystem reported full, and the
  validator's writes would block. Nothing to do today beyond not growing it.

### R740 (pve2) — the machine that is full

`local-lvm` is 1752 GiB physical with **1688 GiB provisioned**, leaving 64 GiB.
No overcommit, but no room either.

## The DR goal does not currently fit, and backups are not the reason

The stated goal is respinning the 730's guests on the 740. The 730 holds about
**1.28 TiB of real data** (324 GiB across the seven VMs, ~955 GiB in CT 200).
The 740 has 64 GiB of unprovisioned pool.

So even with perfect backups, there is nowhere on the 740 to restore them. The
blocker is the 740's capacity, not the backup chain. Roughly 2 TB of additional
NVMe in the 740 is what turns this from a plan into a capability, and that is
the concrete number behind the storage upgrade discussion.

### What is achievable now

1. **Full nightly vzdump on the 730 to its own `backup` dir** (7.2 TiB, 6.9 free).
   This covers the likely failure - one guest lost or corrupted - and costs
   nothing. If that volume is the external drive, it is also physically
   relocatable to the 740, which is a cheap form of real DR.
2. **The respin-critical subset to PBS on the 740.** Not the bulk data: the
   configs and keys that cannot be re-fetched. CT 200's `node_seed` is the
   crown jewel and is a few KiB.
3. **Disk in the 740** before the respin story is true.

The PBS datastore was grown 100 -> 160 GiB on 2026-10-01 to hold subset 2. That
took the pool to 1688/1752 and put the `reserve_gib: 256` target out of reach,
which `inventory.py check` now reports as a WARN rather than silently passing.

## A note on the overcommit check itself

`lib/inventory.py check` used to hardcode ai-hub's 400 GiB as the only
allocation it did not own. Once PBS was built, its 192 GiB was invisible to the
math and the check reported 256 GiB of headroom on a host that had 64. Foreign
volumes are now declared in `cluster.host.existing_allocations` and counted.
Three tests in `tests/guard-test.sh` hold the line: every declared volume must
appear in the ledger, the printed total must equal allocations plus nodes, and
an allocation that overcommits the pool must still be fatal.
