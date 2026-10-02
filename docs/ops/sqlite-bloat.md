# The SQLite files do not shrink, and they are most of the disk

On 2026-10-02 `xah-node-1` was at 314 GiB of its 700 GiB volume. The breakdown
was not what the sizing model assumed:

| file | on disk | live data |
| --- | --- | --- |
| `transaction.db` | **192.6 GiB** | 40.8 GiB |
| `nudb/` (archive + writable) | 107.2 GiB | — |
| `ledger.db` | 0.3 GiB | 0.1 GiB |

`transaction.db` was **larger than the entire NuDB**, and 78% of it was free
pages. `ledger.db` was 78% free pages too.

Pruning was never broken. `min(LedgerSeq)` in both files matched
`complete_ledgers` exactly, so `online_delete` had been deleting rows on
schedule the whole time. SQLite simply never returns emptied pages to the
filesystem — the file only grows.

A `VACUUM` took `transaction.db` to 40 GiB and the volume from 314 GiB used to
153 GiB. **161 GiB reclaimed, none of it data.**

## This is why the sizing model under-counted

`cluster.measured.gib_per_million: 992` was measured as a blend. Taken apart on
the live node, per 1000 ledgers:

- NuDB: **0.763 GiB**, and NuDB holds up to **2x** `online_delete`
- `transaction.db`: **0.285 GiB** when freshly vacuumed, and up to ~4.7x that
  when left to bloat
- `ledger.db`: negligible

So the disk a node needs is `2 x online_delete x 0.763` plus
`ledger_history x 0.285`, with the second term drifting upward until someone
vacuums. At `online_delete: 200000` / `ledger_history: 180000` that is ~356 GiB
freshly vacuumed and ~545 GiB fully re-bloated, against a 700 GiB volume.

## Two traps worth knowing before you run it

**The temp file lands on the root disk.** The role configs set
`sqlite_temp_store: file`. With no `SQLITE_TMPDIR`, SQLite wrote its rebuild to
`/var/tmp` — on the 46 GiB root volume, not the 700 GiB data volume. It reached
9.6 GiB free with ~9 GiB still to write before being killed. Killing a VACUUM is
safe: it rolls back and the original file is untouched, which was verified by
re-reading the row count and ledger range afterwards.

**It writes the rebuild twice.** VACUUM builds a copy in the temp store, then
copies that back into the original file through the WAL. Budget ~2x the live
size of writes — 97 GiB of writes for a 41 GiB result here — and do not read
progress from the file size, which stays at its old value until the final
checkpoint. The honest progress signals are `write_bytes` in `/proc/<pid>/io`
and the size of `transaction.db-wal`.

`ops/vacuum-tx-db.sh` does all of this correctly: it reports the bloat, refuses
to start unless the data volume can hold 2x the live size, forces the temp
store onto that volume, stops xahaud, vacuums, restarts, and waits for `full`.

## What a restart looks like afterwards, so it does not alarm anyone

On start the node reports `server_state=connected` and `complete_ledgers=empty`
for a minute or two, then a narrow range that expands in both directions. That
is the complete-ledger set being rebuilt, not missing history. Once it reaches
`full` the whole on-disk window is registered — here it came back as
26,078,438-26,219,572, all 141,134 ledgers, with NuDB and the SHAMapStore
`DbState`/`CanDelete` rows byte-identical to before the vacuum.

## Do not run this on CT 200

The validator on the R730 is out of scope for this repo and
`ops/vacuum-tx-db.sh` inherits the guard that refuses its host address. Its
space problem was a different one — un-discarded thin blocks, not SQLite free
pages — and is covered in `backup-and-dr.md`.
