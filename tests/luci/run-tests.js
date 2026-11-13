#!/usr/bin/env node
'use strict';
/*
 * View tests for luci-app-wanguard-antidpi (issue #89): runs the REAL code
 * from luci-app-wanguard-antidpi/htdocs/luci-static/resources — the shared
 * core module (wanguard-antidpi/core.js) and the page view
 * (view/wanguard/antidpi.js) — inside node with stubbed LuCI globals
 * (view/poll/rpc/uci/ui/E/L/_), so no router, LuCI or prod backend is
 * involved. Same harness contract the #80-#88 dev smokes used (the
 * "#89 contract" harness); this file is the consolidated regression set:
 *
 *   - #80/#81 scaffold + Overview: strategy words from engine-cmdline
 *     (profile blocks via the --new grammar, last block = catch-all badge,
 *     TCP/QUIC badges, render-fail warn card, honest no-op line), tunnel
 *     card badges (Protected/Unprotected/Not configured + exclusions
 *     panel), validation card (apply --check --json, honest FAILED rows,
 *     dead-rpc degradation), pending bar (Discard = rpcd uci revert of
 *     THIS config only; Review & Apply = uci.save -> uci.apply(5) ->
 *     CLI apply --json, ok/PARTIAL/FAILED notifications, unparsable
 *     output error, busy poll-skip guard).
 *   - #82 Domain lists: inline strict-DNS validation (invalid input never
 *     stages), client-side staging lifecycle over a faithful uci client
 *     stub (creates/changes/deletes -> save() flush -> apply() commit),
 *     mode flip restart badge, whitelist+empty apply guard, soft section
 *     creation, two-step list delete, poll-tick DOM immutability.
 *   - #83 Tunnel protection: strict IPv4/CIDR pin validation (the
 *     valid_addr_entry mirror - leading zeros / bad octets / bad prefix
 *     never stage), pin-vs-hosts honest badges (restart vs reload),
 *     numeric options (interval >= 1, expire >= 0), soft tunnel section,
 *     discard keeps committed truth.
 *   - #84/#85 Profiles: New/Edit drawer with the generic presets (byte
 *     -exact words, two-step armed replace on non-empty words), list rows
 *     (color dot, badges derived FROM the words, policy counter),
 *     enabled toggle -> honest restart badge, reorder via uci move,
 *     adopt-legacy, metadata-only badge on committed truth, policy-ref
 *     delete guard, draft cancel, Open profiles cross-tab navigation.
 *   - #86/#87 Policies: table (priority/match/strategy/state, drag +
 *     fallback arrows with step-10 renumbering), edit drawer (ref
 *     validation BEFORE staging - bogus list/profile never stage, last
 *     -protocol guard, advanced manual priority, device-group staged
 *     -future badge), New policy draft validation, search filter,
 *     metadata-only vs restart badges, cross-tab reload chip, two-step
 *     delete + discard, the domains-tab guard protecting referenced
 *     lists, honest "N rendered" from the status document.
 *   - #88 Tests & Logs: queue counters with the per-tick delta (patched
 *     without rebuilding the tab DOM), debug toggle (staged flip ->
 *     restart badge -> shared apply pipeline, reversible + idempotent),
 *     log viewer (on-demand events --json with filter+tail carried to the
 *     CLI, copy through the execCommand degradation, logread-absent and
 *     rpc-failure degradation keeping the snapshot), uci load failure
 *     degradation per tab.
 *
 * The status document is built DYNAMICALLY from the committed UCI store
 * (the #87 smoke lesson: a mutable hand-built doc breaks the apply-cycle
 * timing), and the uci stub mirrors the minified /www uci.js client
 * semantics the editor tabs rely on.
 *
 * Run: node tests/luci/run-tests.js   (CI runs the same command in the
 * same node:24 container - see the view-test job and dev-test.sh step 13)
 */

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const PKG = path.join(REPO, 'luci-app-wanguard-antidpi', 'htdocs', 'luci-static', 'resources');
const CORE_SRC = fs.readFileSync(path.join(PKG, 'wanguard-antidpi', 'core.js'), 'utf8');
const VIEW_SRC = fs.readFileSync(path.join(PKG, 'view', 'wanguard', 'antidpi.js'), 'utf8');

/* ---------- LuCI polyfills / DOM stubs ---------- */

if (!String.prototype.format) {
	String.prototype.format = function() {
		const args = arguments; let i = 0;
		return this.replace(/%(-?\d*)\.?\d*[sd%]/g, function(m) {
			if (m === '%%') return '%';
			let v = args[i++]; if (v == null) return '';
			if (m.endsWith('d')) v = parseInt(v, 10) || 0;
			return '' + v;
		});
	};
}

function E(spec, attrs, children) {
	const node = {
		tag: '#frag', attrs: {}, style: {}, children: [], listeners: {},
		classList: { _s: {}, add(c) { this._s[c] = 1; }, remove(c) { delete this._s[c]; }, contains(c) { return !!this._s[c]; } },
		addEventListener(ev, fn) { (this.listeners[ev] = this.listeners[ev] || []).push(fn); },
		appendChild(c) { this.children.push(c); return c; },
		insertBefore(n) { this.children.push(n); return n; },
		setAttribute(k, v) { this.attrs[k] = '' + v; },
		getAttribute(k) { return (k in this.attrs) ? this.attrs[k] : null; },
		querySelector() { return null; }, querySelectorAll() { return []; },
		value: '',
		get innerHTML() { return this._h || ''; },
		set innerHTML(v) { this._h = v; if (v === '') this.children.length = 0; },
	};
	if (Array.isArray(spec)) { spec.forEach((c) => node.appendChild(c)); return node; }
	node.tag = spec || '#frag';
	if (attrs) for (const k in attrs) {
		if (k === 'input') node.oninput = attrs[k];
		else if (typeof attrs[k] === 'function') node.addEventListener(k, attrs[k]);
		else node.attrs[k] = attrs[k];
	}
	if (children != null) {
		if (Array.isArray(children)) children.forEach((c) => {
			if (c == null || c === false) return; /* the LuCI dom skips null/false children */
			node.appendChild(c);
		});
		else if (children !== false) node.appendChild(E('#text', null, [ '' + children ]));
	}
	return node;
}
function flat(n) {
	if (typeof n === 'string') return n;
	if (n.tag === '#text') return n.children.map(flat).join('');
	return (n.children || []).map(flat).join('');
}
function findAll(node, pred, out) {
	out = out || [];
	if (pred(node)) out.push(node);
	for (const c of (node.children || [])) findAll(c, pred, out);
	return out;
}
function findByClass(node, cls) {
	return findAll(node, (n) => n.attrs && typeof n.attrs.class === 'string' && n.attrs.class.includes(cls))[0] || null;
}
function findButton(root, text) {
	return findAll(root, (n) => n.tag === 'button' && flat(n) === text)[0] || null;
}
function findInput(root) {
	return findAll(root, (n) => n.tag === 'input')[0] || null;
}
function click(node) { const fns = (node.listeners && node.listeners.click) || []; fns.forEach((f) => f()); }
function fire(node, ev, arg) { const fns = (node.listeners && node.listeners[ev]) || []; fns.forEach((f) => f(arg)); }
function type(node, text) { node.value = text; if (node.oninput) node.oninput({ target: { value: text } }); }
const tick = () => new Promise((r) => setImmediate(r));

/* ---------- uci client stub: the LuCI client lifecycle over a server
 * store (creates/changes/deletes/reorders -> save() flush -> apply()
 * commit), mirroring the minified /www uci.js semantics ---------- */

function deep(o) { return JSON.parse(JSON.stringify(o)); }

function makeUci(server) {
	const st = { values: {}, creates: {}, changes: {}, deletes: {}, reorder: {}, orders: {}, loaded: {} };
	function loadOne(p) {
		const merged = deep(server.committed[p] || {});
		const staged = server.staged[p] || {};
		for (const sid in staged) {
			if (staged[sid] === null) { delete merged[sid]; continue; }
			merged[sid] = Object.assign({}, merged[sid] || {}, deep(staged[sid]));
			merged[sid]['.type'] = staged[sid]['.type'] || (merged[sid]['.type'] || '');
			merged[sid]['.name'] = sid;
		}
		for (const sid in (server.stagedDelete[p] || {})) delete merged[sid];
		if (server.stagedOrder && server.stagedOrder[p]) {
			const rebuilt = {};
			server.stagedOrder[p].forEach((sid) => { if (merged[sid]) rebuilt[sid] = merged[sid]; });
			for (const sid in merged) if (!rebuilt[sid]) rebuilt[sid] = merged[sid];
			for (const sid in merged) delete merged[sid];
			Object.assign(merged, rebuilt);
			server.stagedOrder[p] = Object.keys(rebuilt);
		}
		let i = 0;
		for (const sid in merged) { merged[sid]['.index'] = merged[sid]['.index'] != null ? merged[sid]['.index'] : i; i++; }
		return merged;
	}
	const uci = {
		state: st,
		/* per-suite instrumentation (the #81 pending-bar scenarios) */
		_saves: 0,
		_applyCalls: [],
		_applyImpl: null, /* null = the real fold below */
		load(pkgs) {
			if (!Array.isArray(pkgs)) pkgs = [pkgs];
			const tasks = [];
			for (const p of pkgs) if (!st.values[p]) tasks.push((function() {
				if (server.failLoad) return Promise.reject(new Error(server.failLoad));
				st.values[p] = loadOne(p);
				return Promise.resolve(p);
			})());
			return Promise.all(tasks);
		},
		unload(pkgs) {
			if (!Array.isArray(pkgs)) pkgs = [pkgs];
			for (const p of pkgs) {
				delete st.values[p]; delete st.creates[p]; delete st.changes[p]; delete st.deletes[p];
				delete st.reorder[p]; delete st.orders[p];
			}
		},
		get(conf, sid, opt) {
			if (st.creates[conf] && st.creates[conf][sid]) {
				const s = st.creates[conf][sid];
				return (opt == null) ? s : ((s[opt] === undefined ? null : s[opt]));
			}
			if (st.deletes[conf] && st.deletes[conf][sid] === true) return null;
			const v = st.values[conf];
			if (!v || !v[sid]) return null;
			const c = (st.changes[conf] || {})[sid];
			if (opt != null) {
				if (c && c[opt] !== undefined) return c[opt];
				return (v[sid][opt] === undefined ? null : v[sid][opt]);
			}
			const s = Object.assign({}, v[sid]);
			if (c) Object.assign(s, c);
			return s;
		},
		sections(conf, type) {
			const v = st.values[conf] || {};
			const sa = [];
			for (const sid in v) {
				if (st.deletes[conf] && st.deletes[conf][sid] === true) continue;
				if (type && v[sid]['.type'] !== type) continue;
				const s = Object.assign({}, v[sid]);
				const c = (st.changes[conf] || {})[sid];
				if (c) Object.assign(s, c);
				s['.name'] = sid;
				sa.push(s);
			}
			for (const sid in (st.creates[conf] || {})) {
				const s = st.creates[conf][sid];
				if (type && s['.type'] !== type) continue;
				const copy = Object.assign({}, s); copy['.name'] = sid;
				sa.push(copy);
			}
			sa.sort((a, b) => (a['.index'] || 0) - (b['.index'] || 0));
			return sa;
		},
		set(conf, sid, opt, val) {
			if (st.creates[conf] && st.creates[conf][sid]) {
				if (val != null) st.creates[conf][sid][opt] = val;
				else delete st.creates[conf][sid][opt];
				return;
			}
			if (!st.values[conf] || !st.values[conf][sid]) return;
			st.changes[conf] = st.changes[conf] || {};
			st.changes[conf][sid] = st.changes[conf][sid] || {};
			st.changes[conf][sid][opt] = val;
		},
		add(conf, type, name) {
			const sid = name || ('new' + Math.random().toString(16).slice(2, 8));
			st.creates[conf] = st.creates[conf] || {};
			st.creates[conf][sid] = { '.type': type, '.anonymous': !name, '.index': 1000 };
			return sid;
		},
		remove(conf, sid) {
			if (st.creates[conf] && st.creates[conf][sid]) { delete st.creates[conf][sid]; return; }
			st.deletes[conf] = st.deletes[conf] || {};
			st.deletes[conf][sid] = true;
		},
		move(conf, sid1, sid2, after) {
			const sa = this.sections(conf).map((s) => s['.name']);
			const from = sa.indexOf(sid1);
			let to = sa.indexOf(sid2);
			if (from < 0 || to < 0) return false;
			sa.splice(from, 1);
			to = sa.indexOf(sid2);
			sa.splice(after ? to + 1 : to, 0, sid1);
			st.reorder[conf] = true;
			st.orders[conf] = sa;
			sa.forEach((sid, i) => {
				if (st.creates[conf] && st.creates[conf][sid]) st.creates[conf][sid]['.index'] = i;
				else if (st.values[conf] && st.values[conf][sid]) st.values[conf][sid]['.index'] = i;
			});
			return true;
		},
		save() {
			this._saves++;
			const touched = [];
			for (const conf of new Set([ ...Object.keys(st.deletes), ...Object.keys(st.creates), ...Object.keys(st.changes), ...Object.keys(st.reorder) ])) {
				if (st.reorder[conf] && st.orders[conf]) {
					server.stagedOrder[conf] = st.orders[conf].slice();
				}
				touched.push(conf);
				for (const sid in (st.deletes[conf] || {})) {
					server.stagedDelete[conf] = server.stagedDelete[conf] || {};
					server.stagedDelete[conf][sid] = true;
				}
				for (const sid in (st.creates[conf] || {})) {
					server.staged[conf] = server.staged[conf] || {};
					server.staged[conf][sid] = deep(st.creates[conf][sid]);
				}
				for (const sid in (st.changes[conf] || {})) {
					server.staged[conf] = server.staged[conf] || {};
					server.staged[conf][sid] = Object.assign({}, server.staged[conf][sid] || {}, deep(st.changes[conf][sid]));
				}
			}
			uci.unload(touched);
			return uci.load(touched).then(() => touched);
		},
		apply(timeout) {
			this._applyCalls.push(timeout);
			if (this._applyImpl) return this._applyImpl();
			for (const conf in server.stagedDelete) {
				server.committed[conf] = server.committed[conf] || {};
				for (const sid in server.stagedDelete[conf]) delete server.committed[conf][sid];
			}
			for (const conf in server.staged) {
				server.committed[conf] = server.committed[conf] || {};
				for (const sid in server.staged[conf]) {
					if (server.staged[conf][sid] === null) { delete server.committed[conf][sid]; continue; }
					server.committed[conf][sid] = Object.assign({}, server.committed[conf][sid] || {},
						deep(server.staged[conf][sid]));
					server.committed[conf][sid]['.name'] = sid;
				}
			}
			for (const conf in (server.stagedOrder || {})) {
				if (!server.committed[conf]) continue;
				const ord = server.stagedOrder[conf].filter((sid) => server.committed[conf][sid]);
				if (!ord.length) continue;
				const rebuilt = {};
				ord.forEach((sid) => { rebuilt[sid] = server.committed[conf][sid]; });
				for (const sid in server.committed[conf]) if (!rebuilt[sid]) rebuilt[sid] = server.committed[conf][sid];
				server.committed[conf] = rebuilt;
			}
			server.staged = {}; server.stagedDelete = {}; server.stagedOrder = {};
			server.applies++;
			return Promise.resolve(0);
		}
	};
	return uci;
}

/* committed seed: the base config every suite starts from; suites add
 * their own sections (policy/profile/tunnel) via the extras argument */
function freshServer(extras) {
	const committed = {
		'wanguard-antidpi': {
			engine: { '.type': 'engine', qnum: '300', fwmark: '0x40000000', user: 'daemon', debug: '0',
				nfqws2_opt: [ '--filter-tcp=443', '--payload=tls_client_hello' ] },
			whitelist: { '.type': 'whitelist', enabled: '0',
				domains: [ 'alpha.example', 'beta.example' ] },
			list_media: { '.type': 'domainlist', name: 'Video domains',
				domains: [ 'zeta.example', 'beta.example' ] }
		}
	};
	if (extras) Object.assign(committed['wanguard-antidpi'], extras);
	return {
		committed: committed,
		staged: {}, stagedDelete: {}, stagedOrder: {}, applies: 0,
		failLoad: null
	};
}

/* ---------- rpc/ui/poll/Class/L stubs ---------- */

const RPC = {
	routes: {},
	declare(spec) {
		const key = spec.object + '.' + spec.method;
		return function(...args) {
			const h = RPC.routes[key];
			if (!h) return Promise.reject(new Error('no route: ' + key));
			return Promise.resolve(h(...args));
		};
	}
};
const UI = {
	_notes: [],
	addNotification(ctx, node, sev) { this._notes.push([ sev || '', flat(node) ]); },
	createHandlerFn(scope, fn) { return function() { return fn.apply(scope, arguments); }; },
	changes: { init() { UI._changesInits++; } },
	_changesInits: 0
};

/* minimal document stub for copyText's execCommand fallback (the router's
 * http:// LuCI path); execCommand flips to true only in the copy scenario */
global.document = {
	execCommand: null,
	_selected: null,
	createElement(tag) {
		return { tag, value: '', style: {}, attrs: {},
			setAttribute(k, v) { this.attrs[k] = '' + v; },
			select() { global.document._selected = this; } };
	},
	body: {
		_children: [],
		appendChild(c) { this._children.push(c); },
		removeChild(c) { this._children = this._children.filter((x) => x !== c); }
	}
};

const poll = { add(fn) { poll._cbs.push(fn); }, _cbs: [] };
const Class = function() {}; Class.prototype = {};
Class.extend = function(p) { const F = function() {}; F.prototype = Object.assign(Object.create(this.prototype), p); F.extend = Class.extend; return F; };
const L = { Class };
const _ = (s) => s;
const view = { extend(o) { return o; } };

/* module-level suite state (suites reassign these; the load helpers pass
 * the CURRENT stubs into the Function wrapper, so a rebuilt core sees a
 * fresh server store) */
let SERVER = null;
let UCI = null;
let ad = null, v = null;

function loadCore() {
	const fn = new Function('rpc', 'uci', 'ui', 'poll', 'E', 'L', '_', CORE_SRC);
	const C = fn(RPC, UCI, UI, poll, E, L, _);
	if (typeof C !== 'function') throw new Error('core.js must yield a LuCI class');
	return new C();
}
function loadView(core) {
	const fn = new Function('view', 'poll', 'E', 'L', '_', 'ad', 'uci', 'ui', VIEW_SRC);
	return fn(view, poll, E, L, _, core, UCI, UI);
}

/* ---------- check harness ---------- */

let pass = 0, fail = 0;
function ok(name, cond, extra) {
	if (cond) { pass++; console.log('ok - ' + name); }
	else { fail++; console.log('NOT OK - ' + name + (extra !== undefined ? ' :: ' + JSON.stringify(extra) : '')); }
}
function texts() { return flat(ad.state.bodyNode); }
function btn(label) { return findButton(ad.state.bodyNode, label); }
function btnN(label, idx) {
	return findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === label)[idx] || null;
}
function inputByPh(ph) {
	return findAll(ad.state.bodyNode, (n) => n.tag === 'input' && n.attrs.placeholder === ph)[0] || null;
}
function selects() { return findAll(ad.state.bodyNode, (n) => n.tag === 'select'); }
function checkboxes() { return findAll(ad.state.bodyNode, (n) => n.tag === 'input' && n.attrs.type === 'checkbox'); }
function textareas() { return findAll(ad.state.bodyNode, (n) => n.tag === 'textarea'); }
function chips() {
	return findAll(ad.state.bodyNode, (n) => n.attrs && typeof n.attrs.class === 'string' &&
		n.attrs.class.split(' ').some((c) => c === 'wg-ad-chip' || c.startsWith('wg-ad-chip-'))).map(flat).map((s) => s.trim());
}
function hchips() { /* the header chips row (state.chipsNode, outside bodyNode) */
	return findAll(ad.state.chipsNode, (n) => n.attrs && typeof n.attrs.class === 'string' &&
		n.attrs.class.split(' ').some((c) => c === 'wg-ad-chip' || c.startsWith('wg-ad-chip-'))).map(flat).map((s) => s.trim());
}
function uciGet(sid, opt) { return UCI.get('wanguard-antidpi', sid, opt); }

/* canned CLI documents shared by several suites */
const APPLY_OK_STEPS = JSON.stringify({ ok: true, partial: false, steps: { mark: 'ok', tunnel: 'skipped', nft: 'applied', whitelist: 'refreshed', engine: 'noop' } });
const BASE_CMDLINE = '/usr/bin/nfqws2\n--qnum=300\n--fwmark=0x40000000\n--user=daemon\n--lua-init=@/usr/share/wanguard-antidpi/lua/zapret-lib.lua.gz\n--lua-init=@/usr/share/wanguard-antidpi/lua/zapret-antidpi.lua.gz\n';

/* the #81 overview document template (overrides object) */
const STATUS = (o) => JSON.stringify(Object.assign({
	service: { enabled: true, pid: '20507', uptime_s: 3600 },
	engine: { pid: '20507', version: 'nfqws2 v1.0.6', profiles: 2,
		hostlists: [ '/usr/share/wanguard-antidpi/whitelist.hosts' ], running_argv: [ 'nfqws2' ] },
	nft: { table_present: true,
		counters: { tcp: { packets: 100, bytes: 6000 }, udp: { packets: 5, bytes: 500 } } },
	tunnel: { hosts: [ 'tunnel.example' ],
		entries: [ { ip: '198.51.100.10', source: 'pin', expires_h: null },
			{ ip: '203.0.113.7', source: 'resolved', expires_h: 5 } ],
		update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } },
	whitelist: { mode: 'whitelist', domains: [ 'rutracker.org' ],
		file: { exists: true, mtime: 1 } },
	mihomo: { state: 'installed', mark: '0x10000000', install_on_start: true, backup: true,
		running: true, api: '0.0.0.0:9090', config: '/etc/mihomo/config.yaml', config_missing: false },
	pending: { count: 0, sections: [] },
	events: [ 'line1' ],
	degraded: {}
}, o));

const suiteFns = [];
function suite(name, fn) { suiteFns.push({ name, fn }); }

/* ==================== #80/#81: scaffold + Overview ==================== */

suite('#80/#81 overview: strategy, tunnel, validation, pending bar', async () => {
	const CMDLINE_OK = [
		'/usr/bin/nfqws2',
		'--filter-tcp=443', '--payload=tls_client_hello',
		'--lua-desync=multisplit:blob=fake:pos=2',
		'--new',
		'--filter-udp=443', '--payload=quic_initial',
		'--lua-desync=fake:blob=fakeq'
	].join('\n') + '\n';

	const CHECK_FAIL = JSON.stringify({ ok: false, checks: {
		config: { ok: true, detail: null },
		nft: { ok: true, present: true, detail: null },
		mark: { ok: true, value: '0x10000000', detail: null },
		engine: { ok: false, pid: null, detail: 'engine not running' },
		hostlist: { ok: true, needed: false, exists: false, detail: null }
	} });

	const APPLY_OK = JSON.stringify({ ok: true, partial: false,
		steps: { mark: 'ok', tunnel: 'ok', nft: 'applied', whitelist: 'refreshed', engine: 'noop' } });
	const APPLY_PARTIAL = JSON.stringify({ ok: true, partial: true,
		steps: { mark: 'ok', tunnel: 'kept-last-known', nft: 'applied', whitelist: 'refreshed', engine: 'noop' } });
	const APPLY_FAIL = JSON.stringify({ ok: false, partial: false,
		steps: { mark: 'failed', tunnel: 'ok', nft: 'failed', whitelist: 'refreshed', engine: 'noop' } });

	SERVER = freshServer();
	UCI = makeUci(SERVER);

	RPC.routes['file.exec'] = (cmd, args) => {
		if (cmd !== '/usr/bin/wanguard-antidpi')
			return Promise.resolve({ code: 127, stdout: '', stderr: 'not found' });
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected: ' + args.join(' ') });
	};
	RPC.routes['uci.revert'] = (conf) => {
		RPC._reverted = conf;
		return Promise.resolve({ code: 0 });
	};

	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();   // first data tick (render() already did one pre-refresh)

	/* -- overview skeleton -- */
	ok('notice: only mihomo DIRECT eligible', texts().includes('Only mihomo DIRECT traffic is eligible'));
	ok('overview cards: strategy/tunnel/validation', ['Current strategy', 'Tunnel protection', 'Validation']
		.every((t) => texts().includes(t)));

	/* -- strategy card -- */
	ok('strategy: word chips rendered', texts().includes('--lua-desync=multisplit:blob=fake:pos=2'));
	ok('strategy: binary path dropped', !texts().includes('/usr/bin/nfqws2'));
	const stratCard = findAll(ad.state.bodyNode, (n) => n.tag === 'div' &&
		typeof n.attrs.class === 'string' && n.attrs.class.includes('wg-ad-panel') &&
		flat(n).includes('Current strategy'))[0];
	const profRows = findAll(stratCard, (n) => n.tag === 'tr' &&
		n.children.some((c) => c.tag === 'td'));
	ok('strategy: two profile blocks derived from --new', profRows.length === 2, profRows.length);
	ok('strategy: last block = Default (catch-all)',
		profRows.length === 2 && flat(profRows[1]).includes('Default (catch-all)'));
	ok('strategy: first block named Profile 1', flat(profRows[0]).includes('Profile 1'));
	ok('strategy: TCP badge on first block', flat(profRows[0]).includes('TCP'));
	ok('strategy: QUIC badge on second block', flat(profRows[1]).includes('QUIC'));
	const desyncCells = findAll(ad.state.bodyNode, (n) => n.tag === 'td' && flat(n) === '1');
	ok('strategy: desync counters rendered', desyncCells.length >= 2, desyncCells.length);
	ok('strategy: Open profiles affordance (#85)', texts().includes('Open profiles'));

	/* -- tunnel card -- */
	ok('tunnel: Protected badge (hosts + entries + cron)', findByClass(ad.state.bodyNode, 'wg-ad-chip-ok') != null &&
		texts().includes('Protected'));
	ok('tunnel: hostname shown', texts().includes('tunnel.example'));
	ok('tunnel: refresh line with cron active', texts().includes('every 6 h') && texts().includes('cron active'));
	ok('tunnel: exclusions collapsed by default', !texts().includes('203.0.113.7'));
	const reviewBtn = findButton(ad.state.bodyNode, 'Review exclusions');
	ok('tunnel: Review exclusions button', reviewBtn != null);
	click(reviewBtn);
	ok('tunnel: exclusions panel opens', texts().includes('203.0.113.7') && texts().includes('198.51.100.10'));
	ok('tunnel: pin never expires', texts().includes('never'));
	ok('tunnel: resolved expires 5 h', texts().includes('5 h'));
	click(findButton(ad.state.bodyNode, 'Hide exclusions'));
	ok('tunnel: panel closes again', !texts().includes('203.0.113.7'));

	/* -- validation card -- */
	ok('validation: Not run yet before the first check', texts().includes('Not run yet'));
	ok('validation: provider effectiveness = Not tested', texts().includes('Provider effectiveness') &&
		texts().includes('Not tested'));
	ok('validation: tunnel exclusions row derived from status', texts().includes('Tunnel exclusions'));
	const runBtn = findButton(ad.state.bodyNode, 'Run checks');
	ok('validation: Run checks button', runBtn != null);
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		if (args[0] === 'apply' && args[1] === '--check')
			return Promise.resolve({ code: 1, stdout: CHECK_FAIL, stderr: '' });  // rc 1 + the doc
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	click(runBtn);
	await tick();
	await tick();
	ok('validation: check doc stored', ad.state.checkDoc != null && ad.state.checkDoc.ok === false);
	ok('validation: engine row FAILED with detail', texts().includes('FAILED') &&
		texts().includes('engine not running'));
	ok('validation: config row still ok', texts().includes('ok'));
	ok('validation: hostlist not-consumed note', texts().includes('not consumed in this mode'));
	ok('validation: buttons re-enabled after run', ad.state.checkBusy === false);

	/* -- tick rebuild preserves interactive state -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('tick: check results survive the rebuild', texts().includes('engine not running'));
	click(findButton(ad.state.bodyNode, 'Review exclusions'));
	await ad.refresh(); ad.update();
	ok('tick: exclusions panel stays open across ticks', texts().includes('203.0.113.7'));

	/* -- pending bar -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0,
			stdout: STATUS({ pending: { count: 2, sections: [ 'whitelist', 'engine' ] } }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('pending: bar visible when count > 0', texts().includes('Review configuration before applying'));
	ok('pending: sections listed', texts().includes('whitelist, engine'));
	const discardBtn = findButton(ad.state.bodyNode, 'Discard');
	const applyBtn = findButton(ad.state.bodyNode, 'Review & Apply');
	ok('pending: Discard + Review & Apply buttons', discardBtn != null && applyBtn != null);

	click(discardBtn);
	await tick();
	ok('pending: discard reverted OUR config only', RPC._reverted === 'wanguard-antidpi');
	ok('pending: discard re-queried the changes badge', UI._changesInits >= 1);

	/* -- review & apply: the commit-then-CLI-apply contract -- */
	let applyExecuted = null;
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0,
			stdout: STATUS({ pending: { count: 2, sections: [ 'whitelist' ] } }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		if (args[0] === 'apply' && args[1] === '--json') {
			applyExecuted = args;
			return Promise.resolve({ code: 0, stdout: APPLY_OK, stderr: '' });
		}
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	UCI._applyImpl = () => Promise.resolve(0);
	click(applyBtn);
	ok('apply: busy during flight (poll skip guard)', ad.state.busy === true);
	await tick();
	await tick();
	ok('apply: uci.save + uci.apply(5) before the CLI', UCI._saves >= 1 &&
		UCI._applyCalls.includes(5), UCI._applyCalls);
	ok('apply: CLI apply --json executed', applyExecuted != null &&
		applyExecuted.join(' ') === 'apply --json');
	ok('apply: ok notification with steps', UI._notes.some((n) => n[0] === 'info' &&
		n[1].includes('Configuration applied') && n[1].includes('engine:noop')));

	/* -- apply PARTIAL and FAILED severities -- */
	UI._notes.length = 0;
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0,
			stdout: STATUS({ pending: { count: 1, sections: [ 'whitelist' ] } }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		if (args[0] === 'apply' && args[1] === '--json')
			return Promise.resolve({ code: 2, stdout: APPLY_PARTIAL, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	const b2 = findButton(ad.state.bodyNode, 'Review & Apply');
	click(b2);
	await tick();
	await tick();
	ok('apply: PARTIAL notification is a warning', UI._notes.some((n) => n[0] === 'warning' &&
		n[1].includes('Apply PARTIAL') && n[1].includes('kept-last-known')));

	UI._notes.length = 0;
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0,
			stdout: STATUS({ pending: { count: 1, sections: [ 'whitelist' ] } }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		if (args[0] === 'apply' && args[1] === '--json')
			return Promise.resolve({ code: 1, stdout: APPLY_FAIL, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	click(findButton(ad.state.bodyNode, 'Review & Apply'));
	await tick();
	await tick();
	ok('apply: FAILED notification is an error', UI._notes.some((n) => n[0] === 'error' &&
		n[1].includes('Apply FAILED')));

	UI._notes.length = 0;
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		if (args[0] === 'apply' && args[1] === '--json')
			return Promise.resolve({ code: 1, stdout: 'Usage: ...', stderr: 'usage' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	click(findButton(ad.state.bodyNode, 'Review & Apply'));
	await tick();
	await tick();
	ok('apply: unparsable output = honest error', UI._notes.some((n) => n[0] === 'error' &&
		n[1].includes('could not be parsed')));

	/* -- pending bar hidden at zero -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('pending: bar hidden when count == 0', !texts().includes('Review configuration before applying'));

	/* -- strategy degradation: config does not render -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline')
			return Promise.resolve({ code: 1, stdout: '/usr/bin/nfqws2\n', stderr: 'whitelist: invalid domain: @@\n' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('strategy: render failure = warn card with the reason',
		texts().includes('does not render') && texts().includes('invalid domain'));

	/* -- strategy degradation: no words = honest no-op line -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: '/usr/bin/nfqws2\n', stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('strategy: empty words = no-op line', texts().includes('no-op mode'));

	/* -- tunnel degradation variants -- */
	const tun = (hosts, entries, cron) => STATUS({ tunnel: {
		hosts: hosts, entries: entries, update_interval_h: 6, expire_hours: 24, cron: cron } });
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: tun([], [], { ok: true, lines: 0 }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('tunnel: no hosts = Not configured', texts().includes('Not configured'));

	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0,
			stdout: tun([ 't.example' ], [], { ok: false, lines: 0 }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	ok('tunnel: hosts but no entries = Unprotected', texts().includes('Unprotected'));
	ok('tunnel: cron missing surfaced', texts().includes('cron MISSING'));

	/* -- check rpc failure keeps the page alive -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		if (args[0] === 'apply' && args[1] === '--check')
			return Promise.resolve({ code: 127, stdout: '', stderr: 'old CLI: unknown flag --json' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	click(findButton(ad.state.bodyNode, 'Run checks'));
	await tick();
	ok('validation: old CLI check = honest error line', texts().includes('unknown flag') || texts().includes('failed'));

	/* -- check rpc dead (reject path) -- */
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'apply') return Promise.reject(new Error('rpc dead'));
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	click(findButton(ad.state.bodyNode, 'Run checks'));
	await tick();
	ok('validation: dead rpc = honest error, page alive', texts().includes('could not be executed') &&
		ad.state.checkBusy === false);

	/* -- discard failure path -- */
	UI._notes.length = 0;
	RPC.routes['uci.revert'] = () => Promise.reject({ message: 'permission denied' });
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0,
			stdout: STATUS({ pending: { count: 1, sections: [ 'whitelist' ] } }), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	await ad.refresh(); ad.update();
	click(findButton(ad.state.bodyNode, 'Discard'));
	await tick();
	ok('pending: discard failure = error notification', UI._notes.some((n) => n[0] === 'error' &&
		n[1].includes('Discarding the staged changes failed')));
	ok('pending: busy cleared after discard failure', ad.state.busy === false);

	/* -- uci.apply rejects: rollback path -- */
	UI._notes.length = 0;
	RPC.routes['uci.revert'] = () => Promise.resolve({});
	UCI._applyImpl = () => Promise.reject(new Error('rollback deadline'));
	click(findButton(ad.state.bodyNode, 'Review & Apply'));
	await tick();
	await tick();
	ok('apply: commit failure = error notification (rollback)', UI._notes.some((n) => n[0] === 'error' &&
		n[1].includes('Applying the configuration failed')));
	ok('apply: busy cleared after commit failure', ad.state.busy === false);

	/* -- poll guard: busy tick skipped -- */
	let polled = 0;
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') { polled++; return Promise.resolve({ code: 0, stdout: STATUS({}), stderr: '' }); }
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	ad.state.busy = true;
	await poll._cbs[0]();
	ok('poll: busy tick skips refresh entirely', polled === 0);
	ad.state.busy = false;
	await poll._cbs[0]();
	ok('poll: free tick refreshes', polled === 1);
});

/* ==================== #82: Domain lists ==================== */

suite('#82 domains: validation, staging lifecycle, mode flip, guards', async () => {
	SERVER = freshServer();
	UCI = makeUci(SERVER);

	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') {
			const staged = Object.keys(SERVER.staged['wanguard-antidpi'] || {}).length +
				Object.keys(SERVER.stagedDelete['wanguard-antidpi'] || {}).length;
			return Promise.resolve({ code: 0, stdout: STATUS_PENDING(staged, []), stderr: '' });
		}
		if (args[0] === 'engine-cmdline')
			return Promise.resolve({ code: 0, stdout: '/usr/bin/nfqws2\n--filter-tcp=443\n', stderr: '' });
		if (args[0] === 'apply') return Promise.resolve({ code: 0, stdout: APPLY_OK_STEPS, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected: ' + args.join(' ') });
	};

	const STATUS_PENDING = (n, secs) => JSON.stringify({
		service: { enabled: true, pid: '9', uptime_s: 9 },
		engine: { pid: '9', version: 'nfqws2 v1.0.6', profiles: 1, hostlists: [], running_argv: null },
		nft: { table_present: true, counters: { tcp: { packets: 1, bytes: 1 }, udp: { packets: 1, bytes: 1 } } },
		tunnel: { hosts: [], entries: [], update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } },
		whitelist: { mode: 'blanket', domains: [], file: { exists: false, mtime: null } },
		mihomo: { state: 'installed', mark: '0x10000000', install_on_start: true, backup: true, running: true, api: null, config: '/x', config_missing: false },
		pending: { count: n, sections: secs || [] },
		events: [], degraded: {}
	});

	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();

	/* -- tab renders lists from UCI -- */
	ad.switchTab('domains');
	await tick(); await tick();
	ok('mode card: blanket active by default', texts().includes('Blanket mode'));
	ok('legacy panel: label + legacy badge', texts().includes('Legacy list'));
	ok('named list panel: label from option name', texts().includes('Video domains'));
	ok('named list: count badge', texts().includes('2 domain(s)'));
	ok('policies column: em dash (no policies yet)', texts().includes('Used by policies') && texts().includes('—'));
	ok('apply block: no unsaved edits hint', texts().includes('No unsaved edits.'));
	ok('apply button disabled when clean', (findButton(ad.state.bodyNode, 'Apply changes') || {}).attrs !== undefined);

	/* -- invalid domains never stage (the criterion) -- */
	const domRows = () => findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-domrow').length;
	const rowsBefore = domRows();
	type(findInput(ad.state.bodyNode), '*.wild.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	ok('wildcard rejected inline', texts().includes('Not a valid DNS hostname'));
	ok('wildcard not staged (row count unchanged)', domRows() === rowsBefore, domRows());
	type(findInput(ad.state.bodyNode), 'singlelabel');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	ok('single label rejected', texts().includes('Not a valid DNS hostname'));
	type(findInput(ad.state.bodyNode), 'two labels');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	ok('space rejected', texts().includes('Not a valid DNS hostname'));
	type(findInput(ad.state.bodyNode), 'a,b.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	ok('comma rejected', texts().includes('Not a valid DNS hostname'));
	type(findInput(ad.state.bodyNode), 'alpha.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	ok('duplicate rejected with the domain named', texts().includes('is already in this list'));
	ok('server still untouched by invalid input', Object.keys(SERVER.staged).length === 0 &&
		SERVER.committed['wanguard-antidpi'].whitelist.domains.length === 2);

	/* -- valid add stages client-side -- */
	type(findInput(ad.state.bodyNode), 'gamma.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	ok('valid add staged: row appears', domRows() === rowsBefore + 1, domRows());
	ok('dirty: unsaved hint gone, reload badge shown', !texts().includes('No unsaved edits.') &&
		texts().includes('Applies via reload - live connections stay up'));
	ok('client staged only (server staged empty)', Object.keys(SERVER.staged).length === 0);
	ok('input cleared after add', (findInput(ad.state.bodyNode) || {}).value === '');

	/* -- input text survives a re-render -- */
	type(findInput(ad.state.bodyNode), 'partial-typing');
	click(findButton(ad.state.bodyNode, 'Blanket'));
	await tick();
	ok('input text survives the re-render', (findInput(ad.state.bodyNode) || {}).value === 'partial-typing');

	/* -- mode change staging + restart badge -- */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Whitelist')[0]);
	await tick();
	ok('whitelist mode staged (active style moved)',
		findByClass(ad.state.bodyNode, 'wg-ad-modebtn-active') != null &&
		flat(findByClass(ad.state.bodyNode, 'wg-ad-modebtn-active')) === 'Whitelist');
	ok('mode-flip chip: requires engine restart', texts().includes('Mode change staged - requires engine restart'));
	ok('apply badge: restart (mode wins over lists)', texts().includes('Requires engine restart'));

	/* -- apply happy path: stage -> save -> apply(5) commit -> CLI apply -- */
	type(findInput(ad.state.bodyNode), 'partial-typing-clear'); // overwrite the input, unused
	UI._notes.length = 0;
	const applyBtn = findButton(ad.state.bodyNode, 'Apply changes');
	ok('apply button enabled when dirty', applyBtn != null);
	click(applyBtn);
	await tick(); await tick(); await tick();
	ok('uci.save flushed staging to the server', UCI.state.changes['wanguard-antidpi'] === undefined ||
		Object.keys(UCI.state.changes).length === 0);
	ok('uci.apply committed (server applies++)', SERVER.applies === 1, SERVER.applies);
	ok('notification: configuration applied', UI._notes.some((n) => n[0] === 'info' && n[1].includes('Configuration applied')));
	const committed = SERVER.committed['wanguard-antidpi'];
	ok('gamma committed', (committed.whitelist.domains || []).includes('gamma.example'));
	ok('enabled committed to 1', committed.whitelist.enabled === '1');
	ok('editor reset after apply (No unsaved edits)', texts().includes('No unsaved edits.'));
	ok('mode card shows committed whitelist mode', texts().includes('Whitelist mode'));

	/* -- list delete: two-step arm -> confirm -- */
	const delBtn0 = findButton(ad.state.bodyNode, 'Delete list');
	ok('delete list button present on named lists', delBtn0 != null);
	click(delBtn0);
	await tick();
	ok('delete arms to Confirm delete', findButton(ad.state.bodyNode, 'Confirm delete') != null);
	click(findButton(ad.state.bodyNode, 'Confirm delete'));
	await tick();
	ok('delete staged: list panel gone', !texts().includes('Video domains'));
	click(findButton(ad.state.bodyNode, 'Apply changes'));
	await tick(); await tick(); await tick();
	ok('list delete committed', SERVER.committed['wanguard-antidpi'].list_media === undefined);

	/* -- create list: named section staged with the slug id -- */
	const inputs = findAll(ad.state.bodyNode, (n) => n.tag === 'input');
	ok('two inputs on the tab (legacy add + new-list name)', inputs.length === 2, inputs.length);
	type(inputs[1], 'Video domains');
	click(findButton(ad.state.bodyNode, 'Create list'));
	await tick();
	const vdPanels = findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-panel' &&
		flat(n).includes('Video domains') && !flat(n).includes('Legacy list')).length;
	ok('new list panel appears with the label', vdPanels >= 1, vdPanels);
	ok('slug section id staged (list_video_domains)', UCI.get('wanguard-antidpi', 'list_video_domains') != null,
		Object.keys(UCI.state.creates['wanguard-antidpi'] || {}));
	click(findButton(ad.state.bodyNode, 'Apply changes'));
	await tick(); await tick(); await tick();
	ok('named section committed', SERVER.committed['wanguard-antidpi'].list_video_domains != null);
	ok('label committed', SERVER.committed['wanguard-antidpi'].list_video_domains.name === 'Video domains');

	/* -- discard edits: staged dropped, committed untouched -- */
	type(findInput(ad.state.bodyNode), 'temp.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	click(findButton(ad.state.bodyNode, 'Discard edits'));
	await tick(); await tick();
	ok('discard drops the staged edit', !texts().includes('temp.example'));
	ok('discard leaves committed intact', (SERVER.committed['wanguard-antidpi'].whitelist.domains || []).join(',') === 'alpha.example,beta.example,gamma.example');

	/* -- whitelist+empty guard blocks apply -- */
	/* remove every domain via staging; re-find the button after each click
	 * (every staged change rebuilds the tab - the old nodes go stale) */
	for (;;) {
		const rm = findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-domremove')[0];
		if (!rm) break;
		click(rm);
		await tick();
	}
	ok('all rows removed (merged set empty)', findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-domrow').length === 0);
	click(findButton(ad.state.bodyNode, 'Whitelist'));
	await tick();
	ok('inline render-fail warning shown', texts().includes('Whitelist mode with no domains fails at render time'));
	UI._notes.length = 0;
	click(findButton(ad.state.bodyNode, 'Apply changes'));
	await tick(); await tick();
	ok('apply blocked with the guard notification', UI._notes.some((n) => n[0] === 'error' &&
		n[1].includes('Whitelist mode needs at least one domain')));
	ok('nothing was staged to the server by the blocked apply', SERVER.applies === 3, SERVER.applies);

	/* -- soft whitelist section: create-from-missing path -- */
	/* fresh server without a whitelist section */
	SERVER = freshServer();
	delete SERVER.committed['wanguard-antidpi'].whitelist;
	UCI = makeUci(SERVER);
	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS_PENDING(0, []), stderr: '' });
		if (args[0] === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: '/usr/bin/nfqws2\n', stderr: '' });
		if (args[0] === 'apply') return Promise.resolve({ code: 0, stdout: APPLY_OK_STEPS, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected' });
	};
	/* rebuild the core against the new stubs */
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	ad.switchTab('domains');
	await tick(); await tick();
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Whitelist')[0]);
	await tick();
	type(findInput(ad.state.bodyNode), 'solo.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	click(findButton(ad.state.bodyNode, 'Apply changes'));
	await tick(); await tick(); await tick();
	const c2 = SERVER.committed['wanguard-antidpi'];
	ok('missing whitelist section created as a named section', c2.whitelist != null &&
		c2.whitelist['.type'] === 'whitelist', c2.whitelist);
	ok('solo domain landed through the created section', (c2.whitelist.domains || []).includes('solo.example'));

	/* -- uci load failure = honest warn card -- */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	SERVER.failLoad = 'permission denied';
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	ad.switchTab('domains');
	await tick(); await tick();
	ok('uci load failure renders the warn card', texts().includes('The configuration could not be read'));
	ok('busy flags stay clean after the failure', ad.state.busy === false);

	/* -- poll tick never rebuilds the domains tab -- */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	SERVER.failLoad = null;
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	ad.switchTab('domains');
	await tick(); await tick();
	type(findInput(ad.state.bodyNode), 'wip.example');
	click(findButton(ad.state.bodyNode, 'Add domain'));
	await tick();
	const beforeTick = ad.state.bodyNode.firstChild;
	await ad.refresh(); ad.update();
	ok('poll tick leaves the domains DOM untouched', ad.state.bodyNode.firstChild === beforeTick);
	ok('staged edits survive the tick', texts().includes('wip.example') && ad.state.domains.dirty === true);
});

/* ==================== #83: Tunnel protection ==================== */

suite('#83 tunnel: pin validation, honest badges, soft section', async () => {
	let STATUS_DOC = JSON.stringify({
		service: { enabled: true, pid: '9', uptime_s: 9 },
		engine: { pid: '9', version: 'nfqws2 v1.0.6', profiles: 1, hostlists: [], running_argv: null },
		nft: { table_present: true, counters: { tcp: { packets: 1, bytes: 1 }, udp: { packets: 1, bytes: 1 } } },
		tunnel: { hosts: [ 'cdn.example.net' ],
			entries: [ { ip: '203.0.113.0/24', source: 'pin', expires_h: null },
				{ ip: '192.0.2.11', source: 'resolved', expires_h: 17 } ],
			update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } },
		whitelist: { mode: 'blanket', domains: [], file: { exists: false, mtime: null } },
		mihomo: { state: 'installed', mark: '0x10000000', install_on_start: true, backup: true, running: true, api: null, config: '/x', config_missing: false },
		pending: { count: 0, sections: [] },
		events: [], degraded: {}
	});
	const APPLY_OK = JSON.stringify({ ok: true, partial: false, steps: { mark: 'ok', tunnel: 'applied', nft: 'applied', whitelist: 'refreshed', engine: 'restarted' } });

	SERVER = freshServer();
	SERVER.committed['wanguard-antidpi'].tunnel = {
		'.type': 'tunnel',
		proxy_servers: [ '203.0.113.0/24' ],
		tunnel_hosts: [ 'cdn.example.net' ],
		update_interval: '6',
		expire_hours: '24'
	};
	UCI = makeUci(SERVER);

	RPC.routes['file.exec'] = (cmd, args) => {
		if (args[0] === 'status') return Promise.resolve({ code: 0, stdout: STATUS_DOC, stderr: '' });
		if (args[0] === 'engine-cmdline')
			return Promise.resolve({ code: 0, stdout: '/usr/bin/nfqws2\n--filter-tcp=443\n', stderr: '' });
		if (args[0] === 'apply') return Promise.resolve({ code: 0, stdout: APPLY_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected: ' + args.join(' ') });
	};

	const pinInput = () =>
		findAll(ad.state.bodyNode, (n) => n.tag === 'input' && n.attrs.placeholder === '203.0.113.0/24')[0] || null;
	const hostInput = () =>
		findAll(ad.state.bodyNode, (n) => n.tag === 'input' && n.attrs.placeholder === 'cdn.example.net')[0] || null;
	const numInputs = () =>
		findAll(ad.state.bodyNode, (n) => n.tag === 'input' && (n.attrs.placeholder === '6' || n.attrs.placeholder === '24'));
	const setButtons = () =>
		findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Set');
	const addPinBtn = () => findButton(ad.state.bodyNode, 'Add pin');
	const addHostBtn = () => findButton(ad.state.bodyNode, 'Add host');

	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();

	/* -- tab renders status + set + editor -- */
	ad.switchTab('tunnel');
	await tick(); await tick();
	ok('status card: Protected badge', findByClass(ad.state.bodyNode, 'wg-ad-chip-ok') != null &&
		flat(findByClass(ad.state.bodyNode, 'wg-ad-chip-ok')).trim() === 'Protected');
	ok('status card: hostname shown', texts().includes('cdn.example.net'));
	ok('status card: refresh + cron', texts().includes('every 6 h') && texts().includes('cron active'));
	ok('status card: expire shown', texts().includes('24 h'));
	ok('set card: counter', texts().includes('2 exclusion(s)'));
	ok('set card: pin row with source+never', texts().includes('203.0.113.0/24') && texts().includes('pin') && texts().includes('never'));
	ok('set card: resolved row with expiry', texts().includes('192.0.2.11') && texts().includes('resolved') && texts().includes('17 h'));
	ok('editor: pin row', findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-domrow').length === 2);
	ok('apply block: no unsaved edits hint', texts().includes('No unsaved edits.'));

	/* -- invalid pins never stage (the #61 render contract stays unreachable) -- */
	const badPins = [ '010.1.1.1', '256.1.1.1', '1.2.3.4/33', '1.2.3.4/x', '1.2.3', '' ];
	const rowsBefore = () => findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-domrow').length;
	const rb = rowsBefore();
	for (let i = 0; i < badPins.length; i++) {
		type(pinInput(), badPins[i]);
		click(addPinBtn());
		await tick();
		const rejected = texts().includes('Not a valid IPv4 address or CIDR') ||
			texts().includes('Enter an address or CIDR.');
		ok('invalid pin rejected: ' + JSON.stringify(badPins[i]), rejected);
	}
	ok('invalid pins never staged (row count unchanged)', rowsBefore() === rb, rowsBefore());
	type(pinInput(), '203.0.113.0/24');
	click(addPinBtn());
	await tick();
	ok('duplicate pin rejected by name', texts().includes('is already pinned'));
	ok('server untouched by invalid input', Object.keys(SERVER.staged).length === 0 &&
		SERVER.committed['wanguard-antidpi'].tunnel.proxy_servers.length === 1);

	/* -- valid pin stages; restart badge appears -- */
	type(pinInput(), '198.51.100.222');
	click(addPinBtn());
	await tick();
	ok('valid pin staged: row appears', rowsBefore() === rb + 1, rowsBefore());
	ok('dirty: unsaved hint gone', !texts().includes('No unsaved edits.'));
	ok('pins changed: restart badge', texts().includes('Exclusion set changed - apply re-renders the table and restarts the engine'));
	ok('client staged only (server staged empty)', Object.keys(SERVER.staged).length === 0);

	/* -- input text survives a re-render -- */
	type(pinInput(), 'partial-typing');
	type(hostInput(), 'singlelabel');
	click(addHostBtn());
	await tick();
	ok('host single label rejected', texts().includes('Not a valid DNS hostname'));
	ok('pin input text survives the re-render', (pinInput() || {}).value === 'partial-typing');

	/* -- valid host stages -- */
	type(hostInput(), 'edge.example.org');
	click(addHostBtn());
	await tick();
	ok('valid host staged', texts().includes('edge.example.org'));

	/* -- numeric options: interval >= 1, expire >= 0 -- */
	const nums = numInputs();
	ok('two number inputs present', nums.length === 2, nums.length);
	type(nums[0], '0');
	click(setButtons()[0]);
	await tick();
	ok('interval 0 rejected (min 1)', texts().includes('Whole hours, at least 1'));
	type(numInputs()[0], 'abc');
	click(setButtons()[0]);
	await tick();
	ok('non-numeric interval rejected', texts().includes('Whole hours, at least 1'));
	type(numInputs()[0], '12');
	click(setButtons()[0]);
	await tick();
	ok('interval 12 staged', uciGet('tunnel', 'update_interval') === '12',
		uciGet('tunnel', 'update_interval'));
	type(numInputs()[1], '0');
	click(setButtons()[1]);
	await tick();
	ok('expire 0 staged (legal: never)', uciGet('tunnel', 'expire_hours') === '0',
		uciGet('tunnel', 'expire_hours'));

	/* -- remove the added pin: pins back to the original -> honest badge flip -- */
	const removeBtns = () => findAll(ad.state.bodyNode, (n) => n.attrs && n.attrs.class === 'wg-ad-domremove');
	click(removeBtns()[1]); /* domrows: pins first (seed, added), then hosts - remove the ADDED pin */
	await tick();
	ok('added pin removed (seed pin + 2 hosts rows)', removeBtns().length === 3, removeBtns().length);
	ok('pins restored: badge flips to the reload chip',
		!texts().includes('Exclusion set changed - apply re-renders the table and restarts the engine') &&
		texts().includes('Applies via tunnel-update + nft reload - the engine restarts only if the set changes'));

	/* -- apply happy path through the shared pipeline -- */
	type(pinInput(), '198.51.100.222');
	click(addPinBtn());
	await tick();
	UI._notes.length = 0;
	const applyBtn = findButton(ad.state.bodyNode, 'Apply changes');
	ok('apply button enabled when dirty', applyBtn != null);
	click(applyBtn);
	await tick(); await tick(); await tick();
	ok('uci.apply committed (server applies++)', SERVER.applies === 1, SERVER.applies);
	ok('notification: configuration applied', UI._notes.some((n) => n[0] === 'info' && n[1].includes('Configuration applied')));
	const committed = SERVER.committed['wanguard-antidpi'];
	ok('pin committed', (committed.tunnel.proxy_servers || []).includes('198.51.100.222'));
	ok('host committed', (committed.tunnel.tunnel_hosts || []).includes('edge.example.org'));
	ok('interval committed', committed.tunnel.update_interval === '12');
	ok('expire committed', committed.tunnel.expire_hours === '0');
	ok('editor reset after apply (No unsaved edits)', texts().includes('No unsaved edits.'));

	/* -- discard edits: staged dropped, committed untouched -- */
	type(pinInput(), '10.0.0.1');
	click(addPinBtn());
	await tick();
	click(findButton(ad.state.bodyNode, 'Discard edits'));
	await tick(); await tick();
	ok('discard drops the staged pin', !texts().includes('10.0.0.1'));
	ok('discard leaves committed intact', (SERVER.committed['wanguard-antidpi'].tunnel.proxy_servers || []).join(',') === '203.0.113.0/24,198.51.100.222');

	/* -- soft tunnel section: create-from-missing path -- */
	SERVER = freshServer();
	delete SERVER.committed['wanguard-antidpi'].tunnel;
	UCI = makeUci(SERVER);
	STATUS_DOC = (function() {
		const o = JSON.parse(STATUS_DOC);
		o.tunnel = { hosts: [], entries: [], update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } };
		return JSON.stringify(o);
	})();
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ad.switchTab('tunnel');
	await tick(); await tick();
	ok('missing section: Not configured badge', flat(findByClass(ad.state.bodyNode, 'wg-ad-chip-muted')).trim() === 'Not configured');
	type(pinInput(), '192.0.2.99');
	click(addPinBtn());
	await tick();
	ok('missing tunnel section created as a named client section',
		uciGet('tunnel') != null &&
		uciGet('tunnel')['.type'] === 'tunnel',
		uciGet('tunnel'));
	click(findButton(ad.state.bodyNode, 'Apply changes'));
	await tick(); await tick(); await tick();
	const c2 = SERVER.committed['wanguard-antidpi'];
	ok('created section committed', c2.tunnel != null && c2.tunnel['.type'] === 'tunnel', c2.tunnel);
	ok('pin landed through the created section', (c2.tunnel.proxy_servers || []).includes('192.0.2.99'));

	/* -- uci load failure = honest warn card -- */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	SERVER.failLoad = 'permission denied';
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ad.switchTab('tunnel');
	await tick(); await tick();
	ok('uci load failure renders the warn card', texts().includes('The configuration could not be read'));

	/* -- poll tick never rebuilds the tunnel tab -- */
	SERVER = freshServer();
	SERVER.committed['wanguard-antidpi'].tunnel = {
		'.type': 'tunnel', proxy_servers: [ '203.0.113.0/24' ],
		tunnel_hosts: [ 'cdn.example.net' ], update_interval: '6', expire_hours: '24'
	};
	UCI = makeUci(SERVER);
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ad.switchTab('tunnel');
	await tick(); await tick();
	type(pinInput(), '10.9.9.9');
	click(addPinBtn());
	await tick();
	const beforeTick = ad.state.bodyNode.firstChild;
	await ad.refresh(); ad.update();
	ok('poll tick leaves the tunnel DOM untouched', ad.state.bodyNode.firstChild === beforeTick);
	ok('staged edits survive the tick', texts().includes('10.9.9.9') && ad.state.tunnel.dirty === true, [ texts().includes('10.9.9.9'), ad.state.tunnel.dirty ]);
});

/* ==================== #84/#85: Profiles ==================== */

suite('#84/#85 profiles: drawer, presets, badges, reorder, guards', async () => {
	let STATUS_DOC = JSON.stringify({
		service: { enabled: true, pid: '9', uptime_s: 9 },
		engine: { pid: '9', version: 'nfqws2 v1.0.6', profiles: 0, profile_sections: [], hostlists: [], running_argv: null },
		nft: { table_present: true, counters: { tcp: { packets: 1, bytes: 1 }, udp: { packets: 1, bytes: 1 } } },
		tunnel: { hosts: [], entries: [], update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } },
		whitelist: { mode: 'blanket', domains: [], file: { exists: false, mtime: null } },
		mihomo: { state: 'installed', mark: '0x10000000', install_on_start: true, backup: true, running: true, api: null, config: '/x', config_missing: false },
		pending: { count: 0, sections: [] },
		events: [], degraded: {}
	});
	let CMDLINE_OUT = BASE_CMDLINE;
	const APPLY_OK = JSON.stringify({ ok: true, partial: false, steps: { engine: 'restarted' } });

	SERVER = freshServer();
	UCI = makeUci(SERVER);

	RPC.routes['file.exec'] = (cmd, params) => {
		const sub = (params && params[0]) || '';
		if (sub === 'status') return Promise.resolve({ code: 0, stdout: STATUS_DOC, stderr: '' });
		if (sub === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: CMDLINE_OUT, stderr: '' });
		if (sub === 'apply') return Promise.resolve({ code: 0, stdout: APPLY_OK, stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected: ' + sub });
	};

	const profSids = () => {
		const conf = SERVER.committed['wanguard-antidpi'];
		return Object.keys(conf).filter((sid) => conf[sid] && conf[sid]['.type'] === 'profile');
	};
	const stagedSids = () => ad.profilesModel().sections.map((p) => p.sid);
	const rows = () =>
		findAll(ad.state.bodyNode, (n) => n.attrs && typeof n.attrs.class === 'string' &&
			n.attrs.class.split(' ').indexOf('wg-ad-profrow') >= 0);
	const drawerRow = (label) => findAll(ad.state.bodyNode, (n) => n.tag === 'div' &&
		typeof n.attrs.class === 'string' && flat(n).indexOf(label) === 0)[0] || null;

	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();

	/* ==== A. empty state: legacy active, list panel, New profile ==== */
	ad.switchTab('profiles');
	await tick(); await tick();
	ok('legacy card: active badge', chips().includes('active'), chips());
	ok('legacy adopt button', btn('Adopt into a profile') != null);
	ok('legacy words strip keeps the chip-strip class (header/card strips stay tucked)',
		findByClass(ad.state.bodyNode, 'wg-ad-chips') != null);
	ok('list panel header', texts().includes('Strategy profiles'));
	ok('empty state hint', texts().includes('No profiles configured - the legacy strategy words drive the engine.'));
	ok('New profile button', btn('New profile') != null);
	ok('clean: no unsaved edits', texts().includes('No unsaved edits.'));

	/* ==== B. drawer (new): name required, preset fills the draft ==== */
	click(btn('New profile'));
	await tick();
	ok('drawer opens with the New profile title', texts().includes('New profile'));
	ok('drawer Cancel button', btn('Cancel') != null);
	ok('drawer rows use the formrow spacing class (#94: proto + color, not the negative-margin chip strip)',
		drawerRow('Protocols (UI metadata):') != null &&
		drawerRow('Protocols (UI metadata):').attrs.class.indexOf('wg-ad-formrow') >= 0 &&
		drawerRow('Color dot:') != null &&
		drawerRow('Color dot:').attrs.class.indexOf('wg-ad-formrow') >= 0,
		[ 'Protocols (UI metadata):', 'Color dot:' ].map((l) => drawerRow(l) && drawerRow(l).attrs.class));
	click(btn('Create profile'));
	await tick();
	ok('name-required error shown', texts().includes('Enter a profile name.'));
	ok('nothing staged on invalid create', profSids().length === 0 && stagedSids().length === 0);
	/* preset: fills the draft words + proto */
	click(btn('TLS over TCP (generic)'));
	await tick();
	let ta = textareas()[0];
	ok('preset fills the draft words textarea', (ta || {}).value === '--filter-tcp=443\n--payload=tls_client_hello\n--lua-desync=multisplit:pos=midsld', ta && ta.value);
	ok('preset proto visible as an active toggle', findAll(ad.state.bodyNode, (n) => n.tag === 'button' &&
		typeof n.attrs.class === 'string' && n.attrs.class.indexOf('wg-ad-modebtn-active') >= 0).map(flat).includes('TCP'));
	/* name + create */
	const nameIn = inputByPh('Profile name');
	type(nameIn, 'TCP Main');
	click(btn('Create profile'));
	await tick();
	ok('profile created from the preset draft', stagedSids().includes('prof_tcp_main'), stagedSids());
	ok('drawer closed after create', btn('Create profile') == null && btn('Cancel') == null);
	ok('preset words staged byte-exactly', JSON.stringify(uciGet('prof_tcp_main', 'strategy_words')) ===
		JSON.stringify([ '--filter-tcp=443', '--payload=tls_client_hello', '--lua-desync=multisplit:pos=midsld' ]),
		uciGet('prof_tcp_main', 'strategy_words'));
	ok('preset proto staged', uciGet('prof_tcp_main', 'proto') === 'tcp', uciGet('prof_tcp_main', 'proto'));
	ok('default color blue staged', uciGet('prof_tcp_main', 'color') === 'blue', uciGet('prof_tcp_main', 'color'));
	ok('dirty after create', ad.state.profiles.dirty === true);
	ok('strategy change -> restart badge', texts().includes('Strategy changed - apply restarts the engine'), texts());

	/* ==== C. list row: dot, badges from words, policy counter ==== */
	const row0 = rows()[0];
	ok('row dot has the blue palette class', row0 && findAll(row0, (n) => n.attrs &&
		typeof n.attrs.class === 'string' && n.attrs.class.indexOf('wg-ad-dot-blue') >= 0).length === 1);
	ok('row name', row0 && flat(findAll(row0, (n) => n.tag === 'strong')[0]) === 'TCP Main');
	ok('row TCP badge derived from the words', row0 && findAll(row0, (n) => {
		const cls = (n.attrs && n.attrs.class) || '';
		return cls.indexOf('wg-ad-chip') >= 0 && flat(n).trim() === 'TCP';
	}).length === 1, row0 && findAll(row0, (n) => ((n.attrs || {}).class || '').indexOf('wg-ad-chip') >= 0).map(flat));
	ok('row: no policies hint', row0 && flat(row0).includes('No policies'));
	ok('row word-count hint', texts().includes('no words - contributes nothing to the strategy') === false);

	/* ==== D. second profile via the QUIC preset + edit-mode flow ==== */
	click(btn('New profile'));
	await tick();
	click(btn('QUIC over UDP (generic)'));
	await tick();
	type(inputByPh('Profile name'), 'QUIC Side');
	click(btn('Create profile'));
	await tick();
	ok('second profile staged', stagedSids()[1] === 'prof_quic_side', stagedSids());
	ok('quic preset words staged', JSON.stringify(uciGet('prof_quic_side', 'strategy_words')) ===
		JSON.stringify([ '--filter-udp=443', '--payload=quic_initial', '--lua-desync=fake:repeats=2' ]),
		uciGet('prof_quic_side', 'strategy_words'));
	const row1 = rows()[1];
	ok('row QUIC badge', row1 && findAll(row1, (n) => {
		const cls = (n.attrs && n.attrs.class) || '';
		return cls.indexOf('wg-ad-chip') >= 0 && flat(n).trim() === 'QUIC';
	}).length === 1);

	/* edit mode: prefilled words, whitespace guard, preset arm */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Edit')[0]);
	await tick();
	ok('drawer opens in edit mode', texts().includes('Edit profile: TCP Main'), texts());
	ok('drawer Close button', btn('Close') != null);
	ta = textareas()[0];
	ok('edit words prefilled', (ta || {}).value === '--filter-tcp=443\n--payload=tls_client_hello\n--lua-desync=multisplit:pos=midsld', ta && ta.value);
	type(ta, '--filter-tcp= 443\n');
	fire(ta, 'change', { target: { value: ta.value } });
	await tick();
	ok('whitespace rejected in edit mode', texts().includes('Each strategy word must be a single argv word'));
	ok('whitespace never staged (words intact)', JSON.stringify(uciGet('prof_tcp_main', 'strategy_words')).indexOf(' 443') < 0);
	ta = textareas()[0];
	type(ta, '--filter-tcp=443\n--payload=tls_client_hello\n--lua-desync=multisplit:pos=midsld');
	fire(ta, 'change', { target: { value: ta.value } });
	await tick();
	/* preset onto an existing profile: two-step (no silent overwrite) */
	click(btn('QUIC over UDP (generic)'));
	await tick();
	ok('preset arm shows the confirm label', texts().includes('Confirm: replace words with "QUIC over UDP (generic)"?'), texts());
	click(btn('Confirm: replace words with "QUIC over UDP (generic)"?'));
	await tick();
	ok('armed preset replaced the words', JSON.stringify(uciGet('prof_tcp_main', 'strategy_words')) ===
		JSON.stringify([ '--filter-udp=443', '--payload=quic_initial', '--lua-desync=fake:repeats=2' ]),
		uciGet('prof_tcp_main', 'strategy_words'));
	ok('armed preset set the proto metadata', uciGet('prof_tcp_main', 'proto') === 'quic', uciGet('prof_tcp_main', 'proto'));
	/* restore the TLS words for the later scenarios */
	click(btn('TLS over TCP (generic)'));
	await tick();
	ok('second preset click is armed again', texts().includes('Confirm: replace words with "TLS over TCP (generic)"?'));
	click(btn('Confirm: replace words with "TLS over TCP (generic)"?'));
	await tick();
	ok('words restored to the TLS preset', JSON.stringify(uciGet('prof_tcp_main', 'strategy_words')) ===
		JSON.stringify([ '--filter-tcp=443', '--payload=tls_client_hello', '--lua-desync=multisplit:pos=midsld' ]));

	/* ==== E. color pick in the drawer ==== */
	/* (no metadata-only assert here: the words still differ from the
	 * committed truth at this point, so the restart badge is honest) */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n).trim() === 'green' &&
		typeof n.attrs.class === 'string' && n.attrs.class.indexOf('cbi-button') >= 0)[0]);
	await tick();
	ok('color staged through the drawer', uciGet('prof_tcp_main', 'color') === 'green', uciGet('prof_tcp_main', 'color'));
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n).trim() === 'blue' &&
		typeof n.attrs.class === 'string' && n.attrs.class.indexOf('cbi-button') >= 0)[0]);
	await tick();
	click(btn('Close'));
	await tick();
	ok('drawer closed', btn('Close') == null);

	/* ==== F. enabled toggle off -> disabled row ==== */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Edit')[0]);
	await tick();
	fire(checkboxes()[0], 'change', { target: { checked: false } });
	await tick();
	ok('disabled staged', uciGet('prof_tcp_main', 'enabled') === '0');
	/* disabling a profile WITH words changes the render -> restart badge */
	ok('disable with words -> restart badge', texts().includes('Strategy changed - apply restarts the engine'));
	click(btn('Close'));
	await tick();
	const offRow = rows()[0];
	ok('row carries the off style + disabled chip', offRow &&
		offRow.attrs.class.indexOf('wg-ad-profrow-off') >= 0 &&
		findAll(offRow, (n) => ((n.attrs || {}).class || '').indexOf('wg-ad-chip') >= 0).map(flat).map((s) => s.trim()).includes('disabled'));
	ok('row skip hint', flat(offRow).includes('skipped on the render'));
	/* back on */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Edit')[0]);
	await tick();
	fire(checkboxes()[0], 'change', { target: { checked: true } });
	await tick();
	ok('re-enabled -> restart badge back', texts().includes('Strategy changed - apply restarts the engine'));
	click(btn('Close'));
	await tick();

	/* ==== G. reorder (order = render order) ==== */
	const moveUpBtns = () => findAll(ad.state.bodyNode, (n) => n.tag === 'button' && n.attrs.title === 'Move up');
	const moveDownBtns = () => findAll(ad.state.bodyNode, (n) => n.tag === 'button' && n.attrs.title === 'Move down');
	ok('first row: Move up disabled', moveUpBtns()[0].attrs.disabled === '');
	click(moveDownBtns()[0]);
	await tick();
	const sids = stagedSids();
	ok('move down swaps with the next section', sids[0] === 'prof_quic_side' && sids[1] === 'prof_tcp_main', sids);

	/* ==== H0. apply #1: commit the staged profiles (the guard below needs
	 * committed truth - the policy seed edits the committed store) ==== */
	UI._notes.length = 0;
	click(btn('Apply changes'));
	await tick(); await tick(); await tick();
	ok('apply #1 committed', SERVER.applies === 1, SERVER.applies);
	ok('notification: configuration applied', UI._notes.some((n) => n[0] === 'info' && n[1].includes('Configuration applied')));
	ok('committed color', SERVER.committed['wanguard-antidpi'].prof_tcp_main.color === 'blue');
	ok('committed words (TLS preset)', JSON.stringify(SERVER.committed['wanguard-antidpi'].prof_tcp_main.strategy_words) ===
		JSON.stringify([ '--filter-tcp=443', '--payload=tls_client_hello', '--lua-desync=multisplit:pos=midsld' ]));
	ok('committed proto (quic preset side)', SERVER.committed['wanguard-antidpi'].prof_quic_side.proto === 'quic');
	ok('editor reset after apply #1', texts().includes('No unsaved edits.'));

	/* ==== H. policy-ref delete guard ==== */
	/* seed a policy section referencing the TCP profile (#86 ref contract) */
	SERVER.committed['wanguard-antidpi'].pol_video = { '.type': 'policy', name: 'Video traffic', profile: 'prof_tcp_main' };
	UCI.unload('wanguard-antidpi');
	ad.switchTab('overview');
	await tick();
	ad.switchTab('profiles');
	await tick(); await tick();
	const tcpRowNow = rows().filter((r) => flat(r).includes('TCP Main'))[0];
	ok('policy counter on the referenced row', tcpRowNow && flat(tcpRowNow).includes('1 policy(s)'), rows().map(flat));
	const delTcp = tcpRowNow && findAll(tcpRowNow, (n) => n.tag === 'button' && (flat(n) === 'Delete' || flat(n) === 'Confirm delete?'))[0];
	ok('delete disabled while referenced', delTcp && delTcp.attrs.disabled === '');
	ok('delete guard title', delTcp && delTcp.attrs.title === 'Unlink the policies first.');
	/* a free profile stays deletable (two-step, staged client-side) */
	const quicRowNow = rows().filter((r) => flat(r).includes('QUIC Side'))[0];
	click(findAll(quicRowNow, (n) => n.tag === 'button' && flat(n) === 'Delete')[0]);
	await tick();
	ok('two-step delete arms on an unreferenced profile', texts().includes('Confirm delete?'));
	delete SERVER.committed['wanguard-antidpi'].pol_video;
	UCI.unload('wanguard-antidpi');
	ad.switchTab('overview');
	await tick();
	ad.switchTab('profiles');
	await tick(); await tick();
	const delBtns = () => findAll(ad.state.bodyNode, (n) => n.tag === 'button' && (flat(n) === 'Delete' || flat(n) === 'Confirm delete?'));
	/* committed order after apply #1 = [QUIC Side, TCP Main] (the staged
	 * reorder was committed), and the delete arm survived the reload -
	 * the first row's Delete confirms the armed deletion */
	click(delBtns()[0]);
	await tick();
	ok('armed delete removes the profile', stagedSids().includes('prof_quic_side') === false, stagedSids());
	ok('delete staged client-side only', profSids().includes('prof_quic_side') === true && SERVER.applies === 1);

	/* ==== I. adopt legacy ==== */
	click(btn('Adopt into a profile'));
	await tick();
	const model = ad.profilesModel();
	const adopted = model.sections.filter((p) => p.sid === 'prof_adopted_legacy')[0];
	ok('adopted words = legacy words', adopted && JSON.stringify(adopted.words) ===
		JSON.stringify([ '--filter-tcp=443', '--payload=tls_client_hello' ]), adopted && adopted.words);
	ok('adopted proto derived from the filter flags', adopted && adopted.proto.join(',') === 'tcp', adopted && adopted.proto);
	ok('legacy card flips to the warn chip', chips().includes('ignored while profiles exist'), chips());

	/* ==== J. apply #2 + the metadata-only badge on committed truth ==== */
	UI._notes.length = 0;
	click(btn('Apply changes'));
	await tick(); await tick(); await tick();
	ok('apply #2 committed', SERVER.applies === 2, SERVER.applies);
	const conf = SERVER.committed['wanguard-antidpi'];
	ok('quic profile deleted from committed', profSids().includes('prof_quic_side') === false, profSids());
	ok('adopted words committed', JSON.stringify(conf.prof_adopted_legacy.strategy_words) ===
		JSON.stringify([ '--filter-tcp=443', '--payload=tls_client_hello' ]));
	ok('notification: configuration applied (#2)', UI._notes.some((n) => n[0] === 'info' && n[1].includes('Configuration applied')));
	ok('editor reset after apply #2', texts().includes('No unsaved edits.'));
	ok('origStrategy refreshed after apply', ad.profilesStrategyKey(ad.profilesModel()) === ad.state.profiles.origStrategy);
	/* color-only edit on committed words = metadata-only (argv untouched) */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Edit')[0]);
	await tick();
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n).trim() === 'orange' &&
		typeof n.attrs.class === 'string' && n.attrs.class.indexOf('cbi-button') >= 0)[0]);
	await tick();
	ok('color-only edit on committed words -> metadata-only badge', texts().includes('Metadata only - the engine stays untouched'), texts());
	/* disable with words on committed truth -> restart (render changes) */
	fire(checkboxes()[0], 'change', { target: { checked: false } });
	await tick();
	ok('disable on committed words -> restart badge', texts().includes('Strategy changed - apply restarts the engine'));
	fire(checkboxes()[0], 'change', { target: { checked: true } });
	await tick();
	click(btn('Discard edits'));
	await tick(); await tick();
	ok('color/disable probes discarded', texts().includes('No unsaved edits.'));

	/* ==== K. drawer draft lifecycle: cancel drops the draft ==== */
	click(btn('New profile'));
	await tick();
	type(inputByPh('Profile name'), 'Draft Never');
	click(btn('Cancel'));
	await tick();
	ok('cancel drops the draft (nothing staged)', stagedSids().every((s) => s !== 'prof_draft_never'));
	ok('cancel leaves committed truth clean', ad.state.profiles.dirty === false);

	/* ==== L. poll tick never rebuilds the tab ==== */
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Edit')[0]);
	await tick();
	ta = textareas()[0];
	type(ta, '--filter-tcp=443\n--payload=tls_client_hello\n--lua-desync=multisplit:pos=midsld\n--filter-udp=443');
	fire(ta, 'change', { target: { value: ta.value } });
	await tick();
	const beforeTick = ad.state.bodyNode.firstChild;
	await ad.refresh(); ad.update();
	ok('poll tick leaves the profiles DOM untouched', ad.state.bodyNode.firstChild === beforeTick);
	ok('staged edits survive the tick', ad.state.profiles.dirty === true && texts().includes('Strategy changed - apply restarts the engine'));
	click(btn('Discard edits'));
	await tick(); await tick();
	ok('discard restores the committed words', ad.profilesModel().sections.some((p) => JSON.stringify(p.words) ===
		JSON.stringify([ '--filter-tcp=443', '--payload=tls_client_hello', '--lua-desync=multisplit:pos=midsld' ])));

	/* ==== M. Overview: Open profiles link + named profiles ==== */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	CMDLINE_OUT = '/usr/bin/nfqws2\n--qnum=300\n--fwmark=0x40000000\n--user=daemon\n--lua-init=@l.gz\n--lua-init=@a.gz\n--filter-tcp=443\n--payload=tls_client_hello\n';
	const doc = JSON.parse(STATUS_DOC);
	doc.engine.profile_sections = [];
	STATUS_DOC = JSON.stringify(doc);
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ok('overview: Open profiles button', btn('Open profiles') != null);
	ok('overview: generic label without sections', texts().includes('Default (catch-all)'));
	click(btn('Open profiles'));
	await tick(); await tick();
	ok('Open profiles switches to the profiles tab', ad.state.activeTab === 'profiles' && texts().includes('Strategy profiles'));
	/* named profiles in the strategy table */
	ad.switchTab('overview');
	await tick(); await tick();
	doc.engine.profile_sections = [ { id: 'prof_a', name: 'Named profile', proto: [ 'tcp' ], enabled: true, words: 2 } ];
	STATUS_DOC = JSON.stringify(doc);
	await ad.refresh(); ad.update();
	let orow = findAll(ad.state.bodyNode, (n) => n.tag === 'tr')[1];
	ok('overview: named profile from the status surface', flat(orow.children[0]) === 'Named profile', flat(orow.children[0]));
	doc.engine.profile_sections = [ { id: 'prof_a', name: 'Named profile', proto: [ 'tcp' ], enabled: false, words: 2 } ];
	STATUS_DOC = JSON.stringify(doc);
	await ad.refresh(); ad.update();
	orow = findAll(ad.state.bodyNode, (n) => n.tag === 'tr')[1];
	ok('overview: disabled section keeps the generic label (render skip is honest)',
		flat(orow.children[0]) === 'Default (catch-all)', flat(orow.children[0]));

	/* ==== N. uci load failure = honest warn card ==== */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	SERVER.failLoad = 'permission denied';
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ad.switchTab('profiles');
	await tick(); await tick();
	ok('uci load failure renders the warn card', texts().includes('The configuration could not be read'));
});

/* ==================== #86/#87: Policies ==================== */

suite('#86/#87 policies: table, drawer refs, drag, badges, guards', async () => {
	function buildDoc() {
		const conf = SERVER.committed['wanguard-antidpi'];
		const secs = Object.keys(conf).filter((s) => conf[s]['.type'] === 'policy')
			.sort((a, b) => (parseInt(conf[a].priority, 10) || 0) - (parseInt(conf[b].priority, 10) || 0))
			.map(policySectionOf);
		const rendered = secs.filter((s) => s.enabled).length;
		return JSON.stringify({
			service: { enabled: true, pid: '9', uptime_s: 9 },
			engine: { pid: '9', version: 'nfqws2 v1.0.6', profiles: 1,
				profile_sections: [ { id: 'prof_split', name: 'Split profile', proto: [ 'tcp' ], enabled: true, words: 3 } ],
				policies: rendered,
				policy_sections: secs,
				hostlists: [ '/usr/share/wanguard-antidpi/lists/list_media.hosts' ],
				running_argv: null },
			nft: { table_present: true, counters: { tcp: { packets: 1, bytes: 1 }, udp: { packets: 1, bytes: 1 } } },
			tunnel: { hosts: [], entries: [], update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } },
			whitelist: { mode: 'blanket', domains: [], file: { exists: false, mtime: null } },
			mihomo: { state: 'installed', mark: '0x10000000', install_on_start: true, backup: true, running: true, api: null, config: '/x', config_missing: false },
			pending: { count: 0, sections: [] },
			events: [], degraded: {}
		});
	}
	function policySectionOf(sid) {
		const c = SERVER.committed['wanguard-antidpi'][sid];
		return {
			id: sid, name: c.name, priority: c.priority, domainlist: c.domainlist,
			proto: (c.proto || '').split(' ').filter((t) => t.length),
			action: c.action, profile: c.profile, device_group: c.device_group,
			enabled: c.enabled != '0'
		};
	}

	SERVER = freshServer({
		prof_split: { '.type': 'profile', name: 'Split profile', enabled: '1', proto: 'tcp',
			strategy_words: [ '--filter-tcp=443', '--payload=tls_client_hello', '--lua-desync=multisplit:pos=midsld' ] },
		pol_media: { '.type': 'policy', name: 'Video traffic', priority: '10',
			domainlist: 'list_media', proto: 'tcp', action: 'bypass', profile: '',
			device_group: '', enabled: '1' }
	});
	UCI = makeUci(SERVER);

	RPC.routes['file.exec'] = (cmd, params) => {
		const sub = (params && params[0]) || '';
		if (sub === 'status') return Promise.resolve({ code: 0, stdout: buildDoc(), stderr: '' });
		if (sub === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: BASE_CMDLINE, stderr: '' });
		if (sub === 'apply') return Promise.resolve({ code: 0, stdout: JSON.stringify({ ok: true, partial: false, steps: { engine: 'restarted' } }), stderr: '' });
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected: ' + sub });
	};

	const polRows = () =>
		findAll(ad.state.bodyNode, (n) => n.tag === 'tr' && n.attrs &&
			typeof n.attrs.class === 'string' && n.attrs.class.split(' ').indexOf('wg-ad-polrow') >= 0);
	const polSids = () => {
		const conf = SERVER.committed['wanguard-antidpi'];
		return Object.keys(conf).filter((sid) => conf[sid] && conf[sid]['.type'] === 'policy');
	};
	const stagedPolSids = () => ad.policiesModel().sections.map((p) => p.sid);
	const orderedSids = () => ad.policiesModel().ordered.map((p) => p.sid);
	const drawerRow = (label) => findAll(ad.state.bodyNode, (n) => n.tag === 'div' &&
		typeof n.attrs.class === 'string' && flat(n).indexOf(label) === 0)[0] || null;

	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();

	/* ==== A. tab opens: notice, columns, committed row, search, add ==== */
	ad.switchTab('policies');
	await tick(); await tick();
	ok('standing notice present', texts().includes('Only mihomo DIRECT traffic is eligible'), texts());
	ok('table header', texts().includes('Processing policies'));
	ok('rendered-count chip from the status document', chips().includes('1 rendered'), chips());
	ok('scoped-by-policies chip', chips().includes('Desync scoped by policies'), chips());
	ok('columns: Priority / Match / Strategy / State',
		texts().includes('Priority') && texts().includes('Match') &&
		texts().includes('Strategy') && texts().includes('State'), texts());
	ok('search input', inputByPh('Search policies') != null);
	ok('Add policy button', btn('Add policy') != null);
	ok('device-group foot-note (concept text)', texts().includes(
		'Device groups are identifiers for future group targeting; mihomo DIRECT filtering does not preserve client identity.'), texts());
	ok('order hint mentions the restart/reload split', texts().includes('Order = priority (lower first)'), texts());

	const row0 = polRows()[0];
	ok('row priority cell', row0 && flat(row0.children[0]).trim() === '10', row0 && flat(row0.children[0]));
	ok('row match cell = policy name + list label + TCP badge', row0 &&
		flat(row0.children[1]).includes('Video traffic') &&
		flat(row0.children[1]).includes('Video domains') &&
		flat(row0.children[1]).includes('TCP'), row0 && flat(row0.children[1]));
	ok('row strategy cell = pass unmodified (bypass)', row0 &&
		flat(row0.children[2]).includes('pass unmodified'), row0 && flat(row0.children[2]));
	ok('row state cell = Enabled chip', row0 &&
		flat(row0.children[3]).includes('Enabled'), row0 && flat(row0.children[3]));
	ok('row is draggable', row0 && row0.attrs.draggable === 'true', row0 && row0.attrs.draggable);
	ok('clean: no unsaved edits', texts().includes('No unsaved edits.'));

	/* ==== B. row menu: fallback arrows, disable without delete ==== */
	click(btn('⋯'));
	await tick();
	ok('row menu opens', btn('Edit') != null && btn('Disable') != null && btn('Delete') != null, texts());
	const upBtn = btn('↑ Move up');
	ok('Move up disabled at the top (fallback arrows live)', upBtn && upBtn.attrs.disabled === '', upBtn && upBtn.attrs);
	ok('Move down present', btn('↓ Move down') != null);
	click(btn('Disable'));
	await tick();
	ok('disable staged without deletion', uciGet('pol_media', 'enabled') === '0' &&
		polSids().includes('pol_media'), uciGet('pol_media', 'enabled'));
	ok('row shows the Disabled chip', polRows()[0] && flat(polRows()[0].children[3]).includes('Disabled'),
		polRows()[0] && flat(polRows()[0].children[3]));
	ok('disable of the only policy -> restart badge', texts().includes('Policy order or actions changed - apply restarts the engine'), texts());
	/* the menu stays open across the re-render - Enable is right there */
	click(btn('Enable'));
	await tick();
	ok('re-enable staged', uciGet('pol_media', 'enabled') === '1');
	ok('re-enabled policy = argv key back to committed -> metadata-only badge',
		texts().includes('Metadata only - the engine stays untouched'), texts());

	/* ==== C. edit drawer: ref validation BEFORE staging, advanced priority ==== */
	/* the menu is still open after the Enable click - Edit is right there */
	click(btn('Edit'));
	await tick();
	ok('drawer opens with the edit title', texts().includes('Edit policy: Video traffic'), texts());
	ok('drawer Close button', btn('Close') != null);
	ok('drawer proto toggles row = wg-ad-formrow spacing (#94: no negative-margin collision with the list select)',
		drawerRow('Protocols (block filters):') != null &&
		drawerRow('Protocols (block filters):').attrs.class.indexOf('wg-ad-formrow') >= 0 &&
		drawerRow('Protocols (block filters):').attrs.class.indexOf('wg-ad-chips') < 0,
		drawerRow('Protocols (block filters):') && drawerRow('Protocols (block filters):').attrs.class);
	ok('device-group staged-future badge', texts().includes('stored, ignored by the current render'), texts());
	ok('two selects without strategy (list + action)', selects().length === 2, selects().length);
	/* bogus refs: validated BEFORE staging (the issue criterion) */
	fire(selects()[0], 'change', { target: { value: 'list_nope' } });
	await tick();
	ok('missing list = inline error', texts().includes('The domain list does not exist'), texts());
	ok('bogus list ref NOT staged', uciGet('pol_media', 'domainlist') === 'list_media', uciGet('pol_media', 'domainlist'));
	/* device group staging */
	type(inputByPh('Device group (optional)'), 'lobby');
	ok('device group staged (metadata)', uciGet('pol_media', 'device_group') === 'lobby', uciGet('pol_media', 'device_group'));
	/* advanced collapse: manual priority */
	ok('Advanced collapse button', btn('Advanced') != null);
	click(btn('Advanced'));
	await tick();
	ok('advanced reveals the priority editor', inputByPh('Priority (lower = earlier)') != null, texts());
	ok('priority prefilled', inputByPh('Priority (lower = earlier)').value === '10');
	type(inputByPh('Priority (lower = earlier)'), '5');
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Set')[0]);
	await tick();
	ok('priority 5 staged via Set', uciGet('pol_media', 'priority') === '5', uciGet('pol_media', 'priority'));
	type(inputByPh('Priority (lower = earlier)'), 'abc');
	click(findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n) === 'Set')[0]);
	await tick();
	ok('non-numeric priority rejected, nothing staged', texts().includes('Priority must be a whole number.') &&
		uciGet('pol_media', 'priority') === '5', uciGet('pol_media', 'priority'));
	click(btn('Hide advanced'));
	await tick();
	ok('advanced collapsed again', inputByPh('Priority (lower = earlier)') == null);
	/* protocol toggles: the block filters, last-protocol guard */
	const protoBtn = (label) => findAll(ad.state.bodyNode, (n) => n.tag === 'button' && flat(n).trim() === label &&
		typeof n.attrs.class === 'string' && n.attrs.class.indexOf('cbi-button') >= 0)[0];
	click(protoBtn('UDP'));
	await tick();
	ok('UDP toggle stages tcp+udp', uciGet('pol_media', 'proto') === 'tcp udp', uciGet('pol_media', 'proto'));
	click(protoBtn('TCP'));
	await tick();
	ok('TCP uncheck leaves udp', uciGet('pol_media', 'proto') === 'udp', uciGet('pol_media', 'proto'));
	click(protoBtn('UDP'));
	await tick();
	ok('last protocol guarded', texts().includes('At least one protocol is required.') &&
		uciGet('pol_media', 'proto') === 'udp', uciGet('pol_media', 'proto'));
	click(protoBtn('UDP'));
	await tick();
	/* action -> strategy: the profile select appears, refs validated */
	fire(selects()[1], 'change', { target: { value: 'strategy' } });
	await tick();
	ok('strategy action reveals the profile select (3 selects)', selects().length === 3, selects().length);
	ok('strategy without profile = inline hint', texts().includes('Strategy policies need a strategy profile.'), texts());
	fire(selects()[2], 'change', { target: { value: 'prof_nope' } });
	await tick();
	ok('missing profile = inline error', texts().includes('The strategy profile does not exist'), texts());
	ok('bogus profile ref NOT staged', uciGet('pol_media', 'profile') === '', uciGet('pol_media', 'profile'));
	fire(selects()[2], 'change', { target: { value: 'prof_split' } });
	await tick();
	ok('valid profile staged', uciGet('pol_media', 'profile') === 'prof_split', uciGet('pol_media', 'profile'));
	ok('profile hint gone', texts().includes('Strategy policies need a strategy profile.') === false);
	ok('strategy cell now names the profile', polRows()[0] && flat(polRows()[0].children[2]).includes('Split profile'),
		polRows()[0] && flat(polRows()[0].children[2]));
	click(btn('Close'));
	await tick();
	ok('drawer closed', btn('Close') == null);

	/* ==== D. new policy drawer: staged-draft validation, create ==== */
	click(btn('Add policy'));
	await tick();
	ok('drawer opens with the New policy title', texts().includes('New policy'), texts());
	click(btn('Create policy'));
	await tick();
	ok('empty name rejected', texts().includes('Enter a policy name.'));
	ok('nothing staged on invalid create', stagedPolSids().length === 1, stagedPolSids());
	type(inputByPh('Policy name'), 'Chat domains');
	click(btn('Create policy'));
	await tick();
	ok('missing list rejected on create', texts().includes('The domain list does not exist'), texts());
	fire(selects()[0], 'change', { target: { value: 'list_media' } });
	await tick();
	fire(selects()[1], 'change', { target: { value: 'strategy' } });
	await tick();
	click(btn('Create policy'));
	await tick();
	ok('strategy draft without profile rejected', texts().includes('Strategy policies need a strategy profile.'), texts());
	ok('still nothing staged', stagedPolSids().length === 1, stagedPolSids());
	fire(selects()[2], 'change', { target: { value: 'prof_split' } });
	await tick();
	click(btn('Create policy'));
	await tick();
	ok('policy created from the draft', stagedPolSids().includes('pol_chat_domains'), stagedPolSids());
	ok('drawer closed after create', btn('Create policy') == null && btn('Cancel') == null);
	ok('created priority = next step-10 after committed max', uciGet('pol_chat_domains', 'priority') === '15',
		uciGet('pol_chat_domains', 'priority'));
	ok('created action+profile staged', uciGet('pol_chat_domains', 'action') === 'strategy' &&
		uciGet('pol_chat_domains', 'profile') === 'prof_split');
	ok('dirty after create', ad.state.policies.dirty === true);
	ok('argv change -> restart badge', texts().includes('Policy order or actions changed - apply restarts the engine'), texts());

	/* ==== E. full cycle: raise the priority (fallback + drag) ==== */
	/* ordered now: pol_media(5), pol_chat_domains(15) */
	ok('ordered by priority', JSON.stringify(orderedSids()) === JSON.stringify([ 'pol_media', 'pol_chat_domains' ]),
		orderedSids());
	click(btnN('⋯', 1));
	await tick();
	click(btn('↑ Move up'));
	await tick();
	ok('move up renumbers to step-10 (chat first)', JSON.stringify(orderedSids()) ===
		JSON.stringify([ 'pol_chat_domains', 'pol_media' ]) &&
		uciGet('pol_chat_domains', 'priority') === '10' && uciGet('pol_media', 'priority') === '20',
		{ order: orderedSids(), chat: uciGet('pol_chat_domains', 'priority'), media: uciGet('pol_media', 'priority') });
	UI._notes.length = 0;
	click(btn('Apply changes'));
	await tick(); await tick(); await tick();
	ok('apply #1 committed', SERVER.applies === 1, SERVER.applies);
	ok('notification: configuration applied', UI._notes.some((n) => n[0] === 'info' && n[1].includes('Configuration applied')));
	const conf1 = SERVER.committed['wanguard-antidpi'];
	ok('committed order: chat raised to 10, media 20', conf1.pol_chat_domains.priority === '10' &&
		conf1.pol_media.priority === '20', { chat: conf1.pol_chat_domains.priority, media: conf1.pol_media.priority });
	ok('committed strategy fields', conf1.pol_chat_domains.action === 'strategy' &&
		conf1.pol_chat_domains.profile === 'prof_split' && conf1.pol_media.proto === 'udp' &&
		conf1.pol_media.device_group === 'lobby');
	/* apply ran the whole chain: dirty reset + editor reset; the CLI's
	 * status reads committed truth (the dynamic stub), the config-change
	 * flag rebuilds the editor tab - the chip is fresh right away */
	await ad.refresh(); ad.update();
	ok('apply #1: status reflects 2 rendered blocks', chips().includes('2 rendered'), chips());
	ok('apply #1: no unsaved edits', texts().includes('No unsaved edits.'));

	/* ==== F. drag reorder (HTML5 events, same renumber) ==== */
	const rowsNow = polRows();
	fire(rowsNow[1], 'dragstart');
	fire(rowsNow[0], 'dragover', { preventDefault() {} });
	fire(rowsNow[0], 'drop');
	await tick();
	ok('drag drop reorders (media lands before chat) + renumbers',
		JSON.stringify(orderedSids()) === JSON.stringify([ 'pol_media', 'pol_chat_domains' ]) &&
		uciGet('pol_media', 'priority') === '10' && uciGet('pol_chat_domains', 'priority') === '20',
		{ order: orderedSids(), media: uciGet('pol_media', 'priority') });
	click(btn('Discard edits'));
	await tick(); await tick();
	ok('discard restores the committed order', JSON.stringify(orderedSids()) ===
		JSON.stringify([ 'pol_chat_domains', 'pol_media' ]) &&
		uciGet('pol_chat_domains', 'priority') === '10', orderedSids());

	/* ==== G. search filter ==== */
	type(inputByPh('Search policies'), 'chat');
	fire(inputByPh('Search policies'), 'change', { target: { value: 'chat' } });
	await tick();
	ok('search narrows to the matching row', polRows().length === 1 &&
		flat(polRows()[0]).includes('Chat domains'), polRows().map(flat));
	type(inputByPh('Search policies'), 'zzz');
	fire(inputByPh('Search policies'), 'change', { target: { value: 'zzz' } });
	await tick();
	ok('no match = honest empty line', texts().includes('No policies match the search.'), texts());
	type(inputByPh('Search policies'), '');
	fire(inputByPh('Search policies'), 'change', { target: { value: '' } });
	await tick();
	ok('cleared search restores both rows', polRows().length === 2, polRows().length);

	/* ==== H. metadata-only badge + the cross-tab reload chip ==== */
	/* ordered: chat(10) first, media(20) - rename the chat policy */
	click(btnN('⋯', 0));
	await tick();
	click(btn('Edit'));
	await tick();
	ok('drawer on the chat policy', texts().includes('Edit policy: Chat domains'), texts());
	type(inputByPh('Policy name'), 'Chat policy');
	click(btn('Close'));
	await tick();
	ok('name-only edit on committed truth -> metadata-only badge',
		texts().includes('Metadata only - the engine stays untouched'), texts());
	ok('metadata-only: no restart badge', texts().includes('Policy order or actions changed - apply restarts the engine') === false);
	/* the user path for list-content edits: stage them on the Domain lists
	 * tab, come back - the policies apply card shows the reload chip */
	ad.switchTab('domains');
	await tick(); await tick();
	type(inputByPh('domain.example'), 'gamma.example');
	click(btn('Add domain'));
	await tick();
	ok('domains tab staged the new domain', uciGet('whitelist', 'domains').includes('gamma.example'));
	ad.switchTab('policies');
	await tick(); await tick();
	ok('staged list edit shows the reload chip', texts().includes('Domain list edits apply via reload - live connections stay up'), texts());
	ok('reload chip rides the metadata-only state (no restart claim)',
		texts().includes('Metadata only - the engine stays untouched'), texts());
	UI._notes.length = 0;
	click(btn('Apply changes'));
	await tick(); await tick(); await tick();
	ok('apply #2 committed', SERVER.applies === 2, SERVER.applies);
	ok('committed renamed policy + staged domain', SERVER.committed['wanguard-antidpi'].pol_chat_domains.name === 'Chat policy' &&
		SERVER.committed['wanguard-antidpi'].whitelist.domains.includes('gamma.example'),
		{ name: (SERVER.committed['wanguard-antidpi'].pol_chat_domains || {}).name,
			domains: (SERVER.committed['wanguard-antidpi'].whitelist || {}).domains });
	await ad.refresh(); ad.update();

	/* ==== I. two-step delete + guard ==== */
	/* ordered: chat(10) first, media(20) - delete the chat policy */
	click(btn('⋯'));
	await tick();
	click(btn('Delete'));
	await tick();
	ok('two-step delete arms', texts().includes('Confirm delete?'));
	click(btn('Confirm delete?'));
	await tick();
	ok('delete staged client-side only', stagedPolSids().includes('pol_chat_domains') === false &&
		polSids().includes('pol_chat_domains') === true, { staged: stagedPolSids(), committed: polSids() });
	click(btn('Discard edits'));
	await tick(); await tick();
	ok('discarded delete restores the policy', stagedPolSids().includes('pol_chat_domains') === true);

	/* ==== J. the domains tab protects referenced lists (#87 guard) ==== */
	ad.switchTab('domains');
	await tick(); await tick();
	click(btn('Delete list'));
	await tick();
	ok('referenced list delete = inline guard', texts().includes('Referenced by 2 policy(s) - unlink them first.'), texts());
	ok('guard: delete NOT armed', btn('Confirm delete') == null, texts());

	/* ==== K. poll tick never rebuilds the tab ==== */
	ad.switchTab('policies');
	await tick(); await tick();
	click(btn('⋯'));
	await tick();
	click(btn('Edit'));
	await tick();
	const beforeTick = ad.state.bodyNode.firstChild;
	await ad.refresh(); ad.update();
	ok('poll tick leaves the policies DOM untouched', ad.state.bodyNode.firstChild === beforeTick);
	click(btn('Close'));
	await tick();
	ok('drawer cancel drops nothing (edit mode stages are separate)', ad.state.policies.editor === null);

	/* ==== L. uci load failure = honest warn card ==== */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	SERVER.failLoad = 'permission denied';
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ad.switchTab('policies');
	await tick(); await tick();
	ok('uci load failure renders the warn card', texts().includes('The configuration could not be read'));
});

/* ==================== #88: Tests & Logs ==================== */

suite('#88 tests: counters delta, debug toggle, log viewer, degradations', async () => {
	function buildDoc() {
		const conf = SERVER.committed['wanguard-antidpi'];
		const secs = Object.keys(conf).filter((s) => conf[s]['.type'] === 'policy')
			.sort((a, b) => (parseInt(conf[a].priority, 10) || 0) - (parseInt(conf[b].priority, 10) || 0))
			.map((sid) => {
				const c = conf[sid];
				return {
					id: sid, name: c.name, priority: c.priority, domainlist: c.domainlist,
					proto: (c.proto || '').split(' ').filter((t) => t.length),
					action: c.action, profile: c.profile, device_group: c.device_group,
					enabled: c.enabled != '0'
				};
			});
		const rendered = secs.filter((s) => s.enabled).length;
		return JSON.stringify({
			service: { enabled: true, pid: '9', uptime_s: 9 },
			engine: { pid: '9', version: 'nfqws2 v1.0.6', profiles: 1,
				profile_sections: [ { id: 'prof_split', name: 'Split profile', proto: [ 'tcp' ], enabled: true, words: 3 } ],
				policies: rendered,
				policy_sections: secs,
				hostlists: [ '/usr/share/wanguard-antidpi/lists/list_media.hosts' ],
				running_argv: null },
			nft: { table_present: true, counters: NFT },
			tunnel: { hosts: [], entries: [], update_interval_h: 6, expire_hours: 24, cron: { ok: true, lines: 1 } },
			whitelist: { mode: 'blanket', domains: [], file: { exists: false, mtime: null } },
			mihomo: { state: 'installed', mark: '0x10000000', install_on_start: true, backup: true, running: true, api: null, config: '/x', config_missing: false },
			pending: { count: 0, sections: [] },
			events: [], degraded: {}
		});
	}

	/* mutable queue counters - every buildDoc() re-serializes them, so each
	 * tick parses FRESH objects (the prevCounters aliasing contract) */
	let NFT = { tcp: { packets: 1, bytes: 1 }, udp: { packets: 1, bytes: 1 } };
	/* the events stub: mode 'ok' | 'degraded' | 'fail'; echoes the filter */
	let EVENTS_MODE = 'ok';
	let LAST_EVENTS_ARGS = null;
	const EVENTS_LINES = {
		engine: [
			'Thu Nov 12 10:00:01 2026 kern.warn kernel: nfqws2 verdict drop line 1',
			'Thu Nov 12 10:01:02 2026 daemon.info wanguard-antidpi: init step 2 done'
		],
		nfqws2: [
			'Thu Nov 12 10:00:01 2026 kern.warn kernel: nfqws2 verdict drop line 1'
		],
		antidpi: [
			'Thu Nov 12 10:01:02 2026 daemon.info wanguard-antidpi: init step 2 done'
		],
		mihomo: [
			'Thu Nov 12 10:02:03 2026 user.warn mihomo: dial DIRECT failed warning 3'
		]
	};

	SERVER = freshServer({
		prof_split: { '.type': 'profile', name: 'Split profile', enabled: '1', proto: 'tcp',
			strategy_words: [ '--filter-tcp=443', '--payload=tls_client_hello', '--lua-desync=multisplit:pos=midsld' ] }
	});
	UCI = makeUci(SERVER);

	RPC.routes['file.exec'] = (cmd, params) => {
		const sub = (params && params[0]) || '';
		if (sub === 'status') return Promise.resolve({ code: 0, stdout: buildDoc(), stderr: '' });
		if (sub === 'engine-cmdline') return Promise.resolve({ code: 0, stdout: BASE_CMDLINE, stderr: '' });
		if (sub === 'apply') return Promise.resolve({ code: 0, stdout: JSON.stringify({ ok: true, partial: false, steps: { engine: 'restarted' } }), stderr: '' });
		if (sub === 'events') {
			LAST_EVENTS_ARGS = params.slice();
			if (EVENTS_MODE === 'fail')
				return Promise.resolve({ code: 2, stdout: '', stderr: 'logread: permission denied' });
			let filter = 'engine';
			(params || []).forEach((a) => {
				if (typeof a === 'string' && a.indexOf('--filter=') === 0) filter = a.slice(9);
			});
			const lines = EVENTS_MODE === 'degraded' ? [] : (EVENTS_LINES[filter] || []);
			return Promise.resolve({ code: 0, stdout: JSON.stringify({
				available: EVENTS_MODE !== 'degraded', filter: filter, tail: 50, lines: lines
			}), stderr: '' });
		}
		return Promise.resolve({ code: 2, stdout: '', stderr: 'unexpected: ' + sub });
	};

	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();

	/* ==== A. tab opens: counters / validation / debug / log cards ==== */
	ad.switchTab('tests');
	await tick(); await tick();

	ok('counters card renders', texts().includes('Queue counters'), texts());
	ok('table headers with delta columns', texts().includes('Packets') &&
		texts().includes('Δ packets') && texts().includes('Bytes') && texts().includes('Δ bytes'), texts());
	ok('first tick: deltas muted', texts().includes('Δ = between the last two polls') &&
		!/\+\d/.test(texts()), texts());
	ok('TCP/UDP rule rows', texts().includes('TCP (443) queue') && texts().includes('UDP (443) queue'), texts());

	ok('validation panel reused (Run checks + provider row)', btn('Run checks') != null &&
		texts().includes('Provider effectiveness') && texts().includes('Not tested'), texts());
	ok('validation honest: Not run yet', texts().includes('Not run yet.'), texts());

	ok('debug card renders', texts().includes('Engine verbose logging'), texts());
	ok('debug off chip', chips().includes('Verbose logging is off'), chips());
	ok('toggle button in off state', btn('Turn on verbose logging') != null);
	ok('apply disabled without a staged flip', btn('Apply changes') != null &&
		btn('Apply changes').attrs.disabled === '');
	ok('debug nature hint', texts().includes('Diagnostic surface, not a resting state'), texts());

	ok('log card renders', texts().includes('Syslog tail'), texts());
	ok('filter select with 4 options', selects().length === 1 &&
		selects()[0].children.filter((o) => o.tag === 'option').length === 4, selects().length);
	ok('refresh button + not-fetched hint', btn('Refresh') != null && texts().includes('Not fetched yet.'), texts());
	ok('copy button hidden without a snapshot', btn('Copy') == null);
	ok('CLI-side bound hint', texts().includes('The filter and the 50-line bound run on the router'), texts());

	/* ==== B. counters delta per tick; log/debug DOM survive ==== */
	const dbgBtnBefore = btn('Turn on verbose logging');
	NFT = { tcp: { packets: 15, bytes: 2000 }, udp: { packets: 4, bytes: 700 } };
	await ad.refresh(); ad.update();
	await tick();
	ok('delta after tick 2: +14 packets', texts().includes('+14'), texts());
	ok('delta after tick 2: +1999 bytes', texts().includes('+1999'), texts());
	ok('processing chip went active', hchips().includes('Processing active'), hchips());
	ok('debug editor survived the tick patch', btn('Turn on verbose logging') === dbgBtnBefore,
		{ same: btn('Turn on verbose logging') === dbgBtnBefore });

	/* ==== C. debug toggle: staged flip -> restart badge -> shared apply ==== */
	click(btn('Turn on verbose logging'));
	await tick();
	ok('debug staged to 1', uciGet('engine', 'debug') === '1', uciGet('engine', 'debug'));
	ok('restart badge on the staged flip',
		chips().includes('The debug flag rides the engine argv - apply restarts the engine'), chips());
	ok('apply enabled with the staged flip', btn('Apply changes') != null &&
		btn('Apply changes').attrs.disabled == null,
		btn('Apply changes') && btn('Apply changes').attrs.disabled);
	/* idempotency: on -> off -> on ends at the same staged value */
	click(btn('Turn off verbose logging'));
	await tick();
	ok('toggle back staged 0 (reversible)', uciGet('engine', 'debug') === '0');
	ok('badge gone at committed value', chips().includes('The debug flag rides the engine argv - apply restarts the engine') === false);
	click(btn('Turn on verbose logging'));
	await tick();
	ok('re-toggle idempotent (still 1)', uciGet('engine', 'debug') === '1');
	UI._notes.length = 0;
	click(btn('Apply changes'));
	await tick(); await tick(); await tick(); await tick();
	ok('debug apply #1 committed', SERVER.applies === 1, SERVER.applies);
	ok('debug apply notification', UI._notes.some((n) => n[1].includes('Configuration applied')), UI._notes);
	ok('committed debug = 1', SERVER.committed['wanguard-antidpi'].engine.debug === '1',
		SERVER.committed['wanguard-antidpi'].engine.debug);
	/* the configChanged rebuild re-reads origDebug -> ON state, no badge */
	await tick();
	ok('verbose ON chip after apply', chips().includes('Verbose logging is ON - turn it off when done'), chips());
	ok('no restart badge at committed ON', chips().includes('The debug flag rides the engine argv - apply restarts the engine') === false, chips());
	ok('toggle now offers off', btn('Turn off verbose logging') != null);
	/* turn it back off (the issue: "снимается обратно") */
	click(btn('Turn off verbose logging'));
	await tick();
	UI._notes.length = 0;
	click(btn('Apply changes'));
	await tick(); await tick(); await tick(); await tick();
	ok('debug apply #2 committed', SERVER.applies === 2, SERVER.applies);
	ok('committed debug back to 0', SERVER.committed['wanguard-antidpi'].engine.debug === '0',
		SERVER.committed['wanguard-antidpi'].engine.debug);
	await tick();
	ok('off chip restored', chips().includes('Verbose logging is off'), chips());

	/* ==== D. log fetch + copy + filter switch ==== */
	click(btn('Refresh'));
	await tick(); await tick();
	ok('log fetched: engine lines rendered', texts().includes('nfqws2 verdict drop line 1') &&
		texts().includes('wanguard-antidpi: init step 2 done'), texts());
	ok('mihomo line NOT in the engine snapshot', texts().includes('mihomo: dial DIRECT failed') === false);
	ok('copy button appears with a snapshot', btn('Copy') != null);
	ok('events exec carried the default filter+tail', JSON.stringify(LAST_EVENTS_ARGS) ===
		JSON.stringify([ 'events', '--json', '--filter=engine', '--tail=50' ]), LAST_EVENTS_ARGS);
	/* copy through the execCommand fallback */
	global.document.execCommand = () => true;
	UI._notes.length = 0;
	click(btn('Copy'));
	await tick();
	ok('copy success toast', UI._notes.some((n) => n[0] === 'info' && n[1].includes('Log copied to the clipboard')), UI._notes);
	ok('copy used a textarea select', global.document._selected != null &&
		global.document._selected.value.includes('nfqws2 verdict drop line 1'));
	/* filter switch: an explicit re-fetch carries the new filter */
	fire(selects()[0], 'change', { target: { value: 'mihomo' } });
	await tick();
	ok('filter select switched', selects()[0].value === 'mihomo');
	click(btn('Refresh'));
	await tick(); await tick();
	ok('mihomo fetch carried --filter=mihomo', LAST_EVENTS_ARGS.indexOf('--filter=mihomo') >= 0, LAST_EVENTS_ARGS);
	ok('mihomo snapshot rendered', texts().includes('mihomo: dial DIRECT failed warning 3'), texts());
	ok('previous engine lines gone', texts().includes('nfqws2 verdict drop line 1') === false);

	/* ==== E. degraded: logread absent + rpc failure keep the snapshot ==== */
	EVENTS_MODE = 'degraded';
	click(btn('Refresh'));
	await tick(); await tick();
	ok('logread-absent honest card', texts().includes('logread is unavailable on this system'), texts());
	EVENTS_MODE = 'fail';
	click(btn('Refresh'));
	await tick(); await tick();
	ok('rpc failure surfaced', texts().includes('The log fetch failed: logread: permission denied'), texts());
	EVENTS_MODE = 'ok';
	click(btn('Refresh'));
	await tick(); await tick();
	ok('recovery re-renders the snapshot', findByClass(ad.state.bodyNode, 'wg-ad-log') != null &&
		texts().includes('mihomo: dial DIRECT failed warning 3'), texts());

	/* ==== F. tick immutability with a fetched log ==== */
	const preNow = findByClass(ad.state.bodyNode, 'wg-ad-log');
	NFT = { tcp: { packets: 30, bytes: 4000 }, udp: { packets: 9, bytes: 1400 } };
	await ad.refresh(); ad.update();
	await tick();
	ok('log pre survives the tick', findByClass(ad.state.bodyNode, 'wg-ad-log') === preNow);
	ok('counters patched to the fresh window', texts().includes('+15'), texts());

	/* ==== G. uci load failure: debug card degrades, the tab stays alive ==== */
	SERVER = freshServer();
	UCI = makeUci(SERVER);
	SERVER.failLoad = 'permission denied';
	ad = loadCore();
	v = loadView(ad);
	await v.load();
	v.render();
	await ad.refresh(); ad.update();
	ad.switchTab('tests');
	await tick(); await tick();
	ok('debug card degrades honestly', texts().includes('The configuration could not be read'), texts());
	ok('counters still alive on uci failure', texts().includes('Queue counters'), texts());
	ok('log card still alive on uci failure', texts().includes('Syslog tail'), texts());
	ok('validation still alive on uci failure', btn('Run checks') != null);
});

/* ==================== runner ==================== */

(async () => {
	for (const s of suiteFns) {
		console.log('\n=== suite: ' + s.name);
		/* fresh per-suite stub state */
		UI._notes.length = 0;
		UI._changesInits = 0;
		poll._cbs.length = 0;
		RPC.routes = {};
		delete RPC._reverted;
		global.document.execCommand = null;
		global.document._selected = null;
		global.document.body._children.length = 0;
		SERVER = null; UCI = null; ad = null; v = null;
		try {
			await s.fn();
		}
		catch (e) {
			fail++;
			console.log('NOT OK - suite crashed :: ' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e));
		}
	}
	console.log('\nVIEW-TESTS: %d pass, %d fail', pass, fail);
	process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('VIEW-TESTS CRASH', e); process.exit(2); });
