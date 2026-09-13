/* ══════════════════════════════════════════════════════════════════════════
   xahau-hub cluster monitor — vanilla, no dependencies.
   Polls /api/state and re-renders. The server does all the work; this file
   only decides how to show it.
   ══════════════════════════════════════════════════════════════════════════ */
'use strict';

const POLL_MS = 5000;
const el = (id) => document.getElementById(id);

/* ── formatting ───────────────────────────────────────────────────────── */
const num = (n, d = 0) =>
  n === null || n === undefined || Number.isNaN(n)
    ? '—'
    : Number(n).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });

function dur(s) {
  if (s === null || s === undefined || Number.isNaN(s)) return '—';
  s = Math.max(0, Math.floor(s));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${s % 60}s`;
  return `${s}s`;
}

function ago(s) {
  if (s === null || s === undefined) return 'never';
  if (s < 2) return 'just now';
  if (s < 90) return `${Math.round(s)}s ago`;
  return `${Math.round(s / 60)}m ago`;
}

const gib = (v, d = 1) => (v === null || v === undefined ? '—' : `${num(v, d)} GiB`);

function tone(pct, warn, crit) {
  if (pct === null || pct === undefined) return 'idle';
  if (crit !== undefined && pct >= crit) return 'crit';
  if (warn !== undefined && pct >= warn) return 'warn';
  return 'ok';
}

/* ── tiny DOM helpers ─────────────────────────────────────────────────── */
function h(tag, attrs, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else n.setAttribute(k, String(v));
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    n.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return n;
}

const tile = (label, value, unit, note, toneName) =>
  h('div', { class: 'tile', 'data-tone': toneName || 'neutral' },
    h('div', { class: 'tile__label', text: label }),
    h('div', { class: 'tile__value' }, String(value), unit ? h('span', { class: 'tile__unit', text: unit }) : null),
    note ? h('div', { class: 'tile__note', text: note }) : null);

const kvRows = (rows) =>
  h('div', { class: 'kv' },
    rows.filter(Boolean).map(([k, v, t]) =>
      h('div', { class: 'kv__row' },
        h('span', { class: 'kv__k', text: k }),
        h('span', { class: 'kv__v', 'data-tone': t || null, text: v === null || v === undefined ? '—' : String(v) }))));

function meter(label, pct, valueText, footText, warn, crit, forcedTone) {
  const t = forcedTone || tone(pct, warn, crit);
  return h('div', { class: 'meter', 'data-tone': t },
    h('div', { class: 'meter__head' },
      h('span', { class: 'meter__label', text: label }),
      h('span', { class: 'meter__value', text: valueText })),
    h('div', {
      class: 'meter__track', role: 'meter', 'aria-label': label,
      'aria-valuenow': pct === null || pct === undefined ? 0 : Math.round(pct),
      'aria-valuemin': 0, 'aria-valuemax': 100,
    }, h('div', { class: 'meter__fill', style: `width:${Math.min(100, Math.max(0, pct || 0))}%` })),
    footText ? h('div', { class: 'meter__foot', text: footText }) : null);
}

function alerts(list, toneName) {
  if (!list || !list.length) return null;
  return h('div', { class: 'alerts' },
    list.map((m) => h('div', { class: 'alert', 'data-tone': toneName || 'crit' },
      h('span', { class: 'alert__mark', 'aria-hidden': 'true', text: toneName === 'info' ? 'i' : '!' }),
      h('span', { text: m }))));
}

function card(title, sub, chipText, chipTone, body) {
  return h('article', { class: 'card' },
    h('header', { class: 'card__head' },
      h('div', { class: 'card__ident' },
        h('h3', { class: 'card__title', text: title }),
        sub ? h('p', { class: 'card__sub', text: sub }) : null),
      h('span', { class: 'chip', 'data-tone': chipTone, text: chipText })),
    h('div', { class: 'card__body' }, body.filter(Boolean)));
}

/* ── stage strip ──────────────────────────────────────────────────────── */
function stageBlock(stage, showSteps) {
  if (!stage || !stage.steps || !stage.steps.length) return null;
  const reached = stage.reached || 0;
  const bar = h('div', { class: 'stage__bar' },
    stage.steps.map((s, i) =>
      h('span', {
        class: 'stage__seg',
        'data-done': s.done ? '1' : '0',
        'data-current': !s.done && i === reached ? '1' : '0',
      })));

  const block = h('div', { class: 'stage' },
    h('div', { class: 'stage__head' },
      h('span', { class: 'stage__label', text: stage.complete ? 'Build complete' : `Next: ${stage.label}` }),
      h('span', { class: 'stage__count', text: `${reached}/${stage.total}` })),
    bar);

  if (showSteps) {
    block.append(h('div', { class: 'steps' },
      stage.steps.map((s, i) =>
        h('div', { class: 'step', 'data-done': s.done ? '1' : '0', 'data-current': !s.done && i === reached ? '1' : '0' },
          h('span', { class: 'step__icon', 'aria-hidden': 'true', text: s.done ? '✓' : String(i + 1) }),
          h('span', { class: 'step__text', text: s.label })))));
  }
  return block;
}

/* ── node card ────────────────────────────────────────────────────────── */
function nodeStatus(n) {
  if (n.guard_blocked) return ['blocked', 'crit'];
  if (!n.enabled) return [`phase ${n.phase}`, 'neutral'];
  if (!n.reachable) return ['unreachable', 'crit'];
  const st = n.ledger && n.ledger.server_state;
  if (n.done && n.done.synced) return [st || 'synced', 'ok'];
  if (st) return [st, 'warn'];
  if (n.done && n.done.service) return ['starting', 'warn'];
  return ['building', 'info'];
}

function nodeCard(n) {
  const [chipText, chipTone] = nodeStatus(n);
  const sub = `${n.role} · vmid ${n.vmid} · ${n.address}`
    + (n.enabled ? (n.is_self ? ' · read locally' : ' · via ssh') : '');
  const body = [];

  body.push(alerts(n.errors, 'crit'));

  if (!n.enabled) {
    body.push(alerts([`Disabled in inventory — scheduled for phase ${n.phase}. Nothing is provisioned for it.`], 'info'));
    body.push(kvRows([
      ['Role', n.role],
      ['vCPU / RAM', `${n.spec.vcpu} / ${num(n.spec.ram_mb / 1024, 0)} GiB`],
      ['DB cap', gib(n.spec.db_gib, 0)],
      ['DB storage', n.spec.db_storage],
    ]));
    return card(n.name, sub, chipText, chipTone, body);
  }

  body.push(stageBlock(n.stage, !(n.stage && n.stage.complete)));

  const db = n.db;
  if (db && db.mounted) {
    const capPct = db.cap_gib ? (db.used_gib / db.cap_gib) * 100 : db.pct;
    body.push(meter('Database volume', capPct,
      `${num(capPct, 1)}%`,
      `${gib(db.used_gib)} of ${gib(db.total_gib, 0)} · ${gib(db.avail_gib)} free · ${db.fs} · warn ${db.warn_pct}% / crit ${db.crit_pct}%`,
      db.warn_pct, db.crit_pct));
  } else if (db && db.blockdev) {
    body.push(meter('Database volume', 0, 'not mounted',
      `${db.blockdev} present, awaiting ${db.want_fs} at ${db.mount}`, undefined, undefined, 'idle'));
  }

  if (n.mem) {
    body.push(meter('Memory', n.mem.pct, `${num(n.mem.pct, 0)}%`,
      `${gib(n.mem.used_gib)} of ${gib(n.mem.total_gib, 0)}`, 85, 95));
  }

  const L = n.ledger;
  if (L) {
    body.push(kvRows([
      ['Validated ledger', num(L.validated_seq)],
      ['Ledger age', L.validated_age_s === null || L.validated_age_s === undefined ? '—' : `${L.validated_age_s}s`,
        L.validated_age_s > 30 ? 'warn' : 'ok'],
      ['Complete ledgers', L.count ? `${num(L.count)} (${num(L.low)}–${num(L.high)})` : (L.complete_ledgers || 'empty'),
        L.count ? null : 'dim'],
      ['Peers', num(L.peers), L.peers >= 5 ? 'ok' : 'warn'],
      ['I/O latency', L.io_latency_ms === null || L.io_latency_ms === undefined ? '—' : `${num(L.io_latency_ms)} ms`,
        L.io_latency_ms > 100 ? 'warn' : null],
      ['Load factor', num(L.load_factor)],
      ['xahaud uptime', dur(L.uptime_s)],
      ['Build', L.build_version || '—'],
    ]));
  } else if (n.reachable) {
    body.push(kvRows([
      ['Guest OS', n.os || '—'],
      ['Guest uptime', dur(n.uptime_s)],
      ['Load (1m)', n.load && n.load.length ? num(n.load[0], 2) : '—'],
      ['vCPU / RAM', `${n.cpus || n.spec.vcpu} / ${num(n.spec.ram_mb / 1024, 0)} GiB`],
      ['DB cap', gib(n.spec.db_gib, 0)],
      ['xahaud', n.xahaud && n.xahaud.installed ? (n.xahaud.version || 'installed') : 'not installed',
        n.xahaud && n.xahaud.installed ? null : 'dim'],
      ['Service', n.xahaud ? n.xahaud.service : '—',
        n.xahaud && n.xahaud.service === 'active' ? 'ok' : 'dim'],
    ]));
  } else {
    body.push(kvRows([
      ['Probe', n.is_self ? 'local (failed)' : `ssh ${n.address}`, 'dim'],
      ['vCPU / RAM', `${n.spec.vcpu} / ${num(n.spec.ram_mb / 1024, 0)} GiB`],
      ['Root / DB', `${gib(n.spec.root_gib, 0)} / ${gib(n.spec.db_gib, 0)}`],
    ]));
    body.push(h('p', { class: 'note', text:
      'Observed from inside the cluster. This dashboard does not query the '
      + 'hypervisor, so it cannot tell you whether the VM itself is powered on — '
      + 'check the Proxmox UI for that.' }));
  }

  return card(n.name, sub, chipText, chipTone, body);
}

/* ── cluster + collector cards ────────────────────────────────────────── */
function clusterCards(s) {
  const c = s.cluster || {};
  const col = s.collector || {};
  const ports = c.ports || {};
  const proxy = c.proxy || {};
  const out = [];

  out.push(card(c.name || 'cluster',
    `${c.network || '—'} · network id ${c.network_id || '—'} · phase ${c.phase || '—'}`,
    `${c.nodes_enabled || 0}/${c.nodes_total || 0} nodes live`,
    c.nodes_enabled ? 'ok' : 'neutral',
    [kvRows([
      ['Peer port', num(ports.peer)],
      ['Public WS', `${num(ports.ws_public)} · via proxy`],
      ['Public RPC', `${num(ports.rpc_public)} · via proxy`],
      ['Admin RPC', `${num(ports.rpc_admin)} · 127.0.0.1 only`, 'ok'],
      ['TLS', proxy.tls || '—'],
      ['Proxy', proxy.kind || '—'],
      ['Database capped at', gib(c.db_cap_gib, 0)],
      ['Database in use', gib(c.db_used_gib)],
    ])]));

  // Where this dashboard lives. Stated explicitly because it is a containment
  // property, not a detail: nothing of ours runs on the hypervisor.
  out.push(card('Collector', 'where this dashboard runs', 'in a VM', 'ok', [
    kvRows([
      ['Running in', col.node || col.hostname || '—'],
      ['Own node', col.node ? 'read locally, no ssh' : 'n/a'],
      ['Peer nodes', 'read over guarded ssh'],
      ['Reads the hypervisor', col.reads_hypervisor ? 'yes' : 'no', 'ok'],
    ]),
    h('p', { class: 'note', text:
      'This service is a systemd unit inside a node VM. It is deliberately NOT '
      + 'installed on the Proxmox host: pve2 also runs guests this repo does not '
      + 'own, so it keeps no packages, units, crons or open ports there. Thin '
      + 'pool figures come from `make growth MODE=host`, which stages itself on '
      + 'the host for one command and deletes itself again.' }),
  ]));

  return out;
}

/* ── overview tiles ───────────────────────────────────────────────────── */
function overview(s) {
  const nodes = (s.nodes || []).filter((n) => n.enabled);
  const synced = nodes.filter((n) => n.done && n.done.synced).length;
  const built = nodes.filter((n) => n.stage && n.stage.complete).length;

  const seqs = nodes.map((n) => n.ledger && n.ledger.validated_seq).filter((v) => v);
  const topSeq = seqs.length ? Math.max(...seqs) : null;

  const used = nodes.reduce((a, n) => a + ((n.db && n.db.used_gib) || 0), 0);
  const cap = nodes.reduce((a, n) => a + ((n.spec && n.spec.db_gib) || 0), 0);

  const peers = nodes.map((n) => n.ledger && n.ledger.peers).filter((v) => v !== null && v !== undefined);
  const topPeers = peers.length ? Math.max(...peers) : null;

  return [
    tile('Nodes synced', `${synced}/${nodes.length}`, null,
      built === nodes.length ? 'all built' : `${built}/${nodes.length} fully built`,
      synced === nodes.length && nodes.length ? 'ok' : synced ? 'warn' : 'crit'),
    tile('Validated ledger', topSeq ? num(topSeq) : '—', null,
      topSeq ? `${s.cluster ? s.cluster.network : ''} · id ${s.cluster ? s.cluster.network_id : ''}` : 'no node answering RPC',
      topSeq ? 'ok' : 'neutral'),
    tile('Database in use', num(used, 1), 'GiB',
      cap ? `of ${num(cap, 0)} GiB capped` : null,
      cap ? tone((used / cap) * 100, 60, 80) : 'neutral'),
    tile('Peers', topPeers === null ? '—' : num(topPeers), null,
      topPeers === null ? 'no node answering RPC' : 'connected to the network',
      topPeers === null ? 'neutral' : topPeers >= 5 ? 'ok' : 'warn'),
  ];
}

/* ── render ───────────────────────────────────────────────────────────── */
function render(s) {
  const c = s.cluster || {};
  el('clusterName').textContent = c.name || 'xahau-hub';
  el('clusterSub').textContent = c.network
    ? `${c.network} · phase ${c.phase}`
    : 'cluster monitor';

  const pulse = el('pulse');
  const stale = s.age_s > Math.max(45, (s.refresh_s || 20) * 2.5);
  pulse.dataset.state = s.error ? 'down' : stale ? 'stale' : 'live';
  el('pulseText').textContent = s.error ? 'collector error' : `updated ${ago(s.age_s)}`;

  el('tiles').replaceChildren(...overview(s));
  el('nodes').replaceChildren(...(s.nodes || []).map(nodeCard));
  el('cluster').replaceChildren(...clusterCards(s));

  const g = s.guard || {};
  el('footer').replaceChildren(
    h('div', { class: 'footer__row' },
      h('strong', { text: 'Read-only. ' }),
      'This dashboard only runs fixed probe commands and answers GET. It changes nothing.'),
    h('div', { class: 'footer__row' },
      h('strong', { text: 'Guarded. ' }),
      `Never contacts ${(g.hosts || []).join(', ')} or ${(g.addresses || []).join(', ')} — the UNL validator host.`),
    h('div', { class: 'footer__row' },
      `Collected in ${num(s.collect_ms)} ms · refresh ${num(s.refresh_s)}s · inventory.yml is the source of truth.`),
  );
  document.title = `${c.name || 'xahau-hub'} — ${(s.nodes || []).filter((n) => n.done && n.done.synced).length}/${(s.nodes || []).filter((n) => n.enabled).length} synced`;
}

async function poll() {
  try {
    const r = await fetch('/api/state', { cache: 'no-store' });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    render(await r.json());
  } catch (e) {
    const pulse = el('pulse');
    pulse.dataset.state = 'down';
    el('pulseText').textContent = 'dashboard unreachable';
  }
}

poll();
setInterval(poll, POLL_MS);
document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
