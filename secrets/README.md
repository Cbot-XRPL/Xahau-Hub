# secrets/

**Nothing in this directory is committed.** `.gitignore` covers `secrets/`
wholesale; only this README and `seeds.env.example` are tracked.
`tests/guard-test.sh` asserts that git still ignores it, and `make guards`
fails the build if that ever stops being true.

## seeds.env

One unique `node_seed` per node, referenced by `inventory.yml` through each
node's `seed_var`.

```bash
make seed NODE=xah-node-1      # validation_create -> appends here, mode 0600
make seeds                     # which nodes have a seed stored (no values shown)
```

Rules, all of them enforced somewhere in the code:

- **Unique per node.** Two nodes with one seed is one identity on the network.
  `guard_seed_unique` refuses a duplicate, `deploy-node.sh` refuses to ship a
  config carrying another node's seed, and `render-cluster-nodes.sh` aborts if
  two nodes report the same `pubkey_node`.
- **Generated with `validation_create`.** Never invented, never derived.
- **Never derived from the validator's key.** Nothing in this repo can reach
  CT 200 on the R730xd, and that is deliberate and tested.
- **Never committed, never pasted into chat, never copied between nodes.**
  `ops/seed-node.sh` excludes `wallet.db` from its rsync for the same reason.

Store them in a password manager as well as here. A lost seed just means the
node gets a new identity; a **leaked** seed lets someone impersonate that node
to its cluster peers.

## alerts.env (optional)

Consumed by `lib/log.sh`'s `alert()`. Without it, alerts go to syslog and
stderr only, which is enough for cron mail but not for a phone.

```bash
XAH_ALERT_WEBHOOK=https://...
XAH_TELEGRAM_TOKEN=...
XAH_TELEGRAM_CHAT=...
```

## What backups contain

`ops/backup-config.sh` captures configuration and a **manifest** of which seed
variable belongs to which node, plus that node's `pubkey_node` — never a seed
value. It redacts `[node_seed]` from every captured config, then greps the
staged archive for seed-shaped strings and **aborts rather than shipping one**.
