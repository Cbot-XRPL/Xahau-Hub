# ══════════════════════════════════════════════════════════════════════════════
#  Xahau Deep + Public Node Cluster — thin wrappers over the scripts.
#
#  Everything is driven by inventory.yml. Nothing here touches the R730xd:
#  CT 200 there is a live UNL validator and lib/guard.sh refuses to reach it.
#
#  Typical first run (phase 1):
#     make check                    # inventory math, no overcommit, guards
#     make host-check               # READ-ONLY preflight on pve2, changes nothing
#     make create-vm  NODE=xah-node-1
#     ... install Ubuntu ...
#     make attach-db  NODE=xah-node-1
#     ... run bootstrap in the guest ...
#     make seed       NODE=xah-node-1
#     make deploy     NODE=xah-node-1
#     make measure    NODE=xah-node-1     # once backfill is stable
#     make seed-from  FROM=xah-node-1 TO=xah-node-2
#     make cluster
# ══════════════════════════════════════════════════════════════════════════════

SHELL   := /bin/bash
.DEFAULT_GOAL := help
INV     := ./lib/inventory.py
# Host-side scripts need the Proxmox host. host-run.sh stages this repo into a
# temp dir there, runs one command, and deletes it — so nothing of ours lives on
# pve2. Standing on pve2 already? It runs in place and stages nothing.
HOSTRUN := ./ops/host-run.sh
NODE    ?=
HISTORY ?= initial
YES     ?= 0
export XAH_YES = $(YES)

.PHONY: help check inventory guards host-check space create-vm attach-db bootstrap \
        seed seeds render render-all deploy deploy-all cluster cluster-deploy \
        health measure growth growth-nodes prune prune-status seed-from backup net \
        nvme migrate phase2 status lint clean dashboard dashboard-status

## help: this list
help:
	@printf '\n\033[1mXahau Deep + Public Node Cluster\033[0m\n'
	@printf 'phase %s — host %s (%s)\n\n' \
	  "$$($(INV) get cluster.phase)" \
	  "$$($(INV) get cluster.host.name)" "$$($(INV) get cluster.host.address)"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /' | awk -F': ' '{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' | sed 's/^  //'
	@printf '\nnodes:\n'
	@while read -r n; do printf '  %-14s %-6s vmid %-4s %-16s db %s GiB %s\n' \
	  "$$n" "$$($(INV) node $$n role)" "$$($(INV) node $$n vmid)" \
	  "$$($(INV) node $$n address)" "$$($(INV) node $$n db_gib)" \
	  "$$([ "$$($(INV) node $$n enabled)" = 1 ] && echo '' || echo '(disabled — phase '$$($(INV) node $$n phase)')')" ; \
	  done < <($(INV) nodes)
	@printf '\nvariables:  NODE=<name>  HISTORY=initial|final  YES=1 (skip prompts)\n\n'

## check: inventory sanity + no-overcommit math + guard self-test
check: inventory guards
	@echo
	@printf '\033[32mall checks passed\033[0m\n'

## inventory: validate inventory.yml and the allocation math
inventory:
	@$(INV) check

## guards: prove the validator guard rails still refuse what they must
guards:
	@./tests/guard-test.sh

## lint: bash syntax check every script
lint:
	@rc=0; for f in $$(find . -name '*.sh' -not -path './.git/*'); do \
	  bash -n "$$f" || { echo "SYNTAX: $$f"; rc=1; }; done; \
	  python3 -m py_compile lib/*.py && rm -rf lib/__pycache__; \
	  [ $$rc = 0 ] && printf '\033[32mall scripts parse\033[0m\n'; exit $$rc

## host-check: READ-ONLY preflight on pve2 (lvm policy, space, media, residue)
host-check:
	@$(HOSTRUN) provision/05-host-check.sh

## space: no-overcommit check against the real thin pool
space:
	@$(HOSTRUN) provision/01-space-check.sh

## net: verify gateway, DNS, free addresses and reachable endpoints
net:
	@$(HOSTRUN) provision/02-net-check.sh $(NODE)

## create-vm: NODE=... create the VM with its ROOT DISK ONLY
create-vm:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@$(HOSTRUN) provision/10-create-vm.sh $(NODE) $(if $(MODE),--mode $(MODE),)

## attach-db: NODE=... hot-add the database disk AFTER the OS install
attach-db:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@$(HOSTRUN) provision/11-attach-db-disk.sh $(NODE)

## bootstrap: NODE=... sync the tooling then run the guest bootstrap over ssh
bootstrap:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@./ops/deploy-node.sh $(NODE) --tooling-only
	@./ops/remote.sh $(NODE) -- provision/20-guest-bootstrap.sh

## seed: NODE=... mint a unique node_seed into secrets/seeds.env
seed:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@./ops/gen-seed.sh --for $(NODE) $(if $(VIA),--via $(VIA),) --append

## seeds: which node has a seed stored (values never printed)
seeds:
	@printf '%-14s %-22s %s\n' NODE SEED_VARIABLE STATUS; \
	 set -a; [ -f secrets/seeds.env ] && . ./secrets/seeds.env; set +a; \
	 while read -r n; do v=$$($(INV) node $$n seed_var); \
	   if [ -n "$${!v:-}" ]; then s='stored'; else s='MISSING'; fi; \
	   printf '%-14s %-22s %s\n' "$$n" "$$v" "$$s"; done < <($(INV) nodes)

## render: NODE=... render xahaud.cfg into out/<node>/ (HISTORY=initial|final)
render:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required (or use render-all)'; exit 2; }
	@./config/render-config.sh $(NODE) --history $(HISTORY)

## render-all: render every enabled node's config
render-all:
	@./config/render-config.sh --all --history $(HISTORY)

## deploy: NODE=... render, push the config, restart, wait for server_info
deploy:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@./ops/deploy-node.sh $(NODE) --restart --wait --history $(HISTORY)

## deploy-all: rolling deploy across every enabled node, one at a time
deploy-all:
	@while read -r n; do echo "── $$n"; \
	  ./ops/deploy-node.sh $$n --restart --wait --history $(HISTORY) || exit 1; \
	  done < <($(INV) nodes --enabled)

## cluster: regenerate [cluster_nodes]/[ips_fixed] from live pubkey_node values
cluster:
	@./cluster/render-cluster-nodes.sh

## cluster-deploy: regenerate, re-render, and rolling-restart the cluster
cluster-deploy:
	@./cluster/render-cluster-nodes.sh --deploy --history $(HISTORY)

## health: server_info, complete_ledgers, peers, lower-bound drift
health:
	@./ops/healthcheck.sh $(NODE)

## status: one-line status per node
status:
	@./ops/healthcheck.sh $(NODE) --quiet || true
	@./ops/remote.sh --all -- ops/growth-watch.sh --mode guest 2>/dev/null || true

## measure: NODE=... GB per million ledgers (run when backfill is stable)
measure:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@./ops/remote.sh $(NODE) -- ops/measure.sh $(if $(RECORD),--record,)

## growth: per-node DB growth (MODE=host routes to pve2 for thin pool data%)
growth:
	@if [ "$(MODE)" = host ]; then $(HOSTRUN) ops/growth-watch.sh --mode host; \
	 else ./ops/remote.sh --all -- ops/growth-watch.sh --mode guest; fi

## prune-status: what prune-guard would do right now, per node
prune-status:
	@./ops/remote.sh --all -- ops/prune-guard.sh --status

## prune: NODE=... fire can_delete now (prune-guard does this from cron)
prune:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@./ops/remote.sh $(NODE) -- ops/prune-guard.sh --force

## growth-nodes: run growth-watch inside every node (df/du per DB volume)
growth-nodes:
	@./ops/remote.sh --all -- ops/growth-watch.sh --mode guest

## seed-from: FROM=... TO=... copy a synced database instead of backfilling
seed-from:
	@[ -n "$(FROM)" ] && [ -n "$(TO)" ] || { echo 'FROM= and TO= are required'; exit 2; }
	@./ops/seed-node.sh --from $(FROM) --to $(TO)

## dashboard: install/restart the read-only monitoring dashboard INSIDE its node
dashboard:
	@./dashboard/install.sh $(if $(SYNC),--sync-only,)

## dashboard-status: is the dashboard up, and at which URL
dashboard-status:
	@./dashboard/install.sh --status

## backup: configs + seed manifest (never the seeds) into backups/
backup:
	@./ops/backup-config.sh

## nvme: PHASE 1.5 — set up nvme-vg on the 4 TB NVMe (hardware must be present)
nvme:
	@$(HOSTRUN) provision/00-nvme-setup.sh

## migrate: NODE=... move that node's DB volume to the NVMe, one node at a time
migrate:
	@[ -n "$(NODE)" ] || { echo 'NODE= is required'; exit 2; }
	@./ops/migrate-to-nvme.sh $(NODE)

## phase2: what adding node 3 actually requires
phase2:
	@sed -n '1,60p' docs/PHASE-2.md

## clean: remove rendered configs (they contain seeds) and local state
clean:
	@rm -rf out/* .state/*; echo 'removed out/ and .state/ (rendered configs contained seeds)'
