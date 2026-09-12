# Clustering, and how to add a node

## What it does and does not do

`[cluster_nodes]` buys:

- shared **load and fee-escalation** state
- shared **client abuse accounting** — behind a load balancer this matters, a
  client cannot hop backends to dodge rate limiting
- transactions relayed between members **skip redundant signature
  verification**

It buys **nothing** in terms of consensus or trust. Trust comes from the UNL in
`config/validators.txt`, and these are stock nodes that do not validate.

## How it is generated

Never hand-edit `[cluster_nodes]` or `[ips_fixed]`.

```bash
make cluster           # collect live pubkey_node values, write fragments
make cluster-deploy    # + re-render every config + rolling restart
```

`render-cluster-nodes.sh`:

1. reads the enabled nodes from `inventory.yml`
2. asks each one for its `pubkey_node` (`server_info` over the node's admin
   RPC via ssh, falling back to public RPC)
3. writes, per node, `cluster/rendered/<node>.cluster-nodes.cfg` containing
   every *other* node, and `<node>.ips-fixed.cfg` with their peer addresses
4. records everything in `cluster/rendered/pubkeys.tsv`
5. **aborts if two nodes report the same `pubkey_node`** — that is one identity
   on two nodes, almost always a copied `node_seed`

`config/render-config.sh` splices those fragments into each node's
`xahaud.cfg`.

The result looks like this on node 1:

```ini
[cluster_nodes]
n9XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX  xah-node-2

[ips_fixed]
192.168.1.111 21337
```

## Adding node 3

Full procedure in `docs/PHASE-2.md`. The cluster part is:

```bash
# 1. inventory.yml: set xah-node-3 enabled: true
# 2. build it (create-vm, attach-db, bootstrap, seed, deploy)
# 3. then:
make cluster-deploy
```

That is it. Two scripts, one inventory entry.

## Things that go wrong

**A node was down when `make cluster` ran.** It is omitted from every other
node's list. Clustering is symmetric, so it is not clustered at all — it does
not share load state and the proxy's rate limiting can be sidestepped by
hopping to it. The script warns loudly and asks before writing an incomplete
set. Start the node and re-run.

**`--cached` was used.** It reuses `pubkeys.tsv` instead of asking the nodes.
Convenient when one node is briefly down, dangerous if a key has actually
changed — a stale key means that node is silently not clustered. The script
warns every time.

**A seed was replaced.** The node's `pubkey_node` changes, so every other
node's fragment is stale. Re-run `make cluster-deploy` after any seed change.

**Peer counts.** All nodes share one public IP, and xahaud limits inbound
connections per source IP — multiple instances behind one address is not
recommended upstream. `peers_max` is deliberately modest (40 deep, 30 api) and
the nodes peer outbound. Do not set all three to aggressive counts dialing the
same hubs.
