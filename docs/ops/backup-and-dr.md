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

## The R730, measured directly (2026-10-01)

Three disks, all behind the PERC H730 Mini:

| device | size | role |
| --- | --- | --- |
| `sda` | 21.8 TB | VG `pve` — root, and the `local-lvm` thin pool (VMs 101-107) |
| `sdb` | 7.3 TB | VG `ssd` — the `ssd` thin pool (CT 100, CT 200) |
| `sdc1` | 7.3 TB | ext4 at `/mnt/backup` — the IronWolf, the `backup` dir storage |

The IronWolf is **internal**, mounted from `/etc/fstab` by UUID with `nofail`.
It is not the removable drive. No Sabrent was attached at the time of writing,
and there is no trace of an offsite flow anywhere on the host: no root crontab,
no systemd timer, no script beyond `/root/evernode_destroy.sh`. Whatever ran
before was a hand-run `vzdump`, and there is nothing here to collide with.

## CT 200 was already protected before this repo touched it

The nightly 21:00 job had been backing up the validator in `snapshot` mode
since at least 2026-09-28. The 09-30 run:

    status = running
    backup mode: snapshot
    ionice priority: 7
    Total bytes written: 18004285440 (17GiB, 123MiB/s)
    archive file size: 5.84GB
    Finished Backup of VM 200 (00:02:26)

`xahaud` has been PID 2344149 since 2026-09-29 09:59:41 — it predates two of
those backups and never restarted through either. A thin snapshot of a running
LXC costs the container nothing; the proof is the process start time.

Adding the offsite copy on 2026-10-01 behaved identically:

    root.pxar: had to backup 15.857 GiB of 16.167 GiB (compressed 6.04 GiB) in 143.74 s
    Finished Backup of VM 200 (00:02:29)

with `--bwlimit 80000 --ionice 7`, and `xahaud` still PID 2344149, same start
time, same RSS, `etimes` advanced by exactly the backup's duration.

**The rule for this container: `mode snapshot`, always.** `suspend` and `stop`
both take the validator off the network. Nothing else about backing it up is
delicate.

## A correction: thin `data_percent` is not live data

Earlier in this file the 730's real data was put at ~1.28 TiB and the 740 was
said to need ~2 TB of disk before DR was possible. That was measured from thin
pool allocation, and it was wrong.

`ssd/vm-200-disk-0` reports 12.74% of 7500 GiB allocated — 955 GiB. CT 200's
filesystem holds **16.17 GiB**. The other ~939 GiB is blocks that ledger
rotations wrote and freed, and which were never returned to the pool. The thin
pool has `Discards: passdown`, so an `fstrim` inside CT 200 would hand all of it
back. That is the same pathology that was costing the 740's nodes 166 GiB.

What the 730 actually holds, from one real backup run:

| guest | archive |
| --- | --- |
| CT 100 (NPM) | 0.73 GiB |
| CT 200 (validator) | 5.84 GiB |
| VM 101 WebsiteServer | 16.86 GiB |
| VM 102 One-Xah | 9.30 GiB |
| VM 104 NewTerra | 8.22 GiB |
| VM 105 XahauVault | 11.96 GiB |
| VM 106 cbot-labs | 8.16 GiB |
| **total (7 of 9)** | **61.07 GiB** |

With VM 103 and VM 107 added, a full run is roughly 100 GiB compressed.

### So the revised DR position

**Backups** of the entire 730 fit on the 740 today — about 100 GiB for a first
run into a 157 GiB datastore, deltas after that. Holding a full retention ladder
for both hosts wants ~250 GiB, which is one 1 TB NVMe, not the 2 TB previously
claimed.

**Restores** are the real constraint, and only for the QEMU guests. `qmrestore`
recreates a disk at its original size, so VMs 101-107 need 6500 GiB provisioned
no matter that they hold 324 GiB. The 740 has 64 GiB unprovisioned. In an actual
disaster you would knowingly overcommit — 324 GiB of data into a 1752 GiB pool
is fine by usage — or restore selectively.

**CT 200 is the exception, and it is the one that matters.** `pct restore`
accepts `--rootfs <storage>:<size>`, so the validator can be restored onto the
740 as a modest container rather than a 7500 GiB one. 16 GiB of data. That
capability exists right now.

## Job layout on the 730 after consolidation

Two jobs created on 2026-10-01 initially collided with the operator's existing
one: a second `--all` job writing full copies of everything to the same
IronWolf. That duplicate was removed and the pre-existing 21:00 job was widened
instead, because VM 103 and VM 107 had **no backups at all**.

| job | guests | target | schedule | retention |
| --- | --- | --- | --- | --- |
| `backup-0cfaec17-9703` | all | `backup` (IronWolf) | 21:00 | 7d / 4w / 3m |
| `backup-730-dr` | 100, 102, 105, 106, 200 | `pbs-740` | 04:00 | 3d / 2w |

The IronWolf has 6.8 TiB free, so ~14 full copies at ~100 GiB cost 1.4 TiB. The
previous `keep-last=2` was leaving far more space idle than it needed to.

## Reclaiming the validator's dead blocks, with it live (2026-10-01)

880 GiB came back. The `ssd` pool went from 12.93% to **1.07%** used, and
`vm-200-disk-0` from 12.74% to 1.03% of its 7500 GiB. Pool metadata dropped too,
2.32% to 0.47% — freeing chunks costs less metadata than tracking them. CT 200
stayed up: `xahaud` is still PID 2344149 from 2026-09-29 09:59:41, at the same
~53% CPU it ran at before.

### Why this was safe, established before running it

`/sys/block/sdb/queue/discard_max_bytes` is **0**. The PERC H730 virtual disk
does not accept discards at all. The thin volumes above it advertise a 128 MiB
discard granularity, so the LVM thin layer frees its chunks and then passes the
discard down to a device that ignores it. The entire cost is thin metadata — no
controller erase, no firmware discard path, nothing for the RAID card to chew
through while a validator is trying to write.

`fstrim` also never touches file data. It reads the filesystem's free-space map
and tells the block layer which ranges are already unused. Corruption is not one
of its failure modes; an I/O stall is the only real risk, and that was the thing
to watch.

Rehearsed first on CT 100 — same thin pool, same unprivileged LXC, 4 GiB
instead of 7.3 TiB. 1.6 GiB trimmed in 2.1 s, pool 12.93% to 12.91%, metadata
flat.

### Use `pct fstrim`, and do not try to slice it

A manual `fstrim -o <offset> -l <length> /var/lib/lxc/200/rootfs/` looks like a
way to trim a huge filesystem in controlled slices. It does nothing. For a
*running* container that host path is an empty directory — the real mount lives
in the container's own namespace — so fstrim resolves to the host's root
filesystem and exits in 4 ms with:

    fstrim: /var/lib/lxc/200/rootfs/: the discard operation is not supported

which is `pve-root` on `sda` correctly reporting that it has no discard support.
Harmless, but it trims nothing. `pct fstrim <vmid>` enters the namespace
properly and is the only correct path. It cannot be sliced.

### So bound it with monitoring instead

Run it in the background and watch the validator's CPU time advance, killing the
trim if it ever stops. Interrupting `fstrim` is safe — it simply stops issuing
further discards.

    P=$(pgrep -o xahaud)                      # see the ps caveat below
    pct fstrim 200 >/tmp/trim.log 2>&1 &
    T=$!
    # every 5s: compare utime+stime from /proc/$P/stat; two flat samples -> kill $T

Across 260 seconds of trimming, `xahaud`'s tick counter advanced at every single
5-second sample — lowest was +37, typical +250 to +500 — and the stall counter
never left zero. The pool's `data_percent` falling steadily from 12.91 to 1.07
doubles as a progress bar.

### Three `ps` idioms that silently lie here

Each of these quietly listed *every* process on the host instead of the one
asked for, which turned a validator health check into a false "process changed"
verdict:

- `ps -eo pid,lstart -p $PID` — `-e` means "all processes" and overrides `-p`.
  Drop the `-e`: `ps -o pid,lstart,etimes,%cpu,rss -p $PID`.
- `pgrep -f /opt/xahaud/bin/xahaud` — returned nothing, leaving `ps -p ""`.
- `ps -C xahaud --no-headers` — did not filter either.

The form that works for finding it in the first place is
`ps -eo pid,lstart,etimes,%cpu,rss,args | grep -E "[x]ahaud"`.

### What it changes

The `ssd` pool now has 7339 GiB free against 79 GiB used. CT 200 is still
*provisioned* at 7500 GiB against 7419 GiB of physical pool, so the paper
overcommit remains, but it is now backed by 1% real usage rather than 13%. There
is no reason to grow that rootfs and every reason to leave it alone.
