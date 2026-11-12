/* luci-app-wanguard-antidpi core — the shared engine behind the Anti-DPI
 * page (view/wanguard/antidpi.js, issues #80-#88). Thin client over the
 * `wanguard-antidpi` CLI surfaces (#76 status, #77 apply): ONE status exec
 * per refresh plus the strategy-words exec (engine-cmdline), with the
 * heavier probes (apply --check, apply, the Tests & Logs log fetch
 * `events --json`) strictly on-demand behind their buttons. The browser
 * never touches nft/logread directly; its only direct
 * UCI verbs are the Domain lists editor's staging (#82), the Tunnel
 * protection editor's staging (#83), the Profiles editor's staging
 * (#84/#85), the Policies editor's staging (#87) and the Tests & Logs
 * debug toggle (#88 - all client-side via
 * the uci client, applied through the same save -> apply(5) -> CLI apply
 * pipeline as the pending bar) and the bar's Discard (uci revert,
 * config-scoped).
 *
 * Degradation contract (#76/#81): nothing throws on missing surfaces. An
 * old or missing CLI (the pre-status packages, a denied ACL) resolves to
 * the page's "unavailable — update the package" section plus muted chips;
 * a present CLI renders its stable keys. Partial degradations surface as
 * the status document's "degraded" map or per-card warn lines. Every
 * overview element shows data from #76/#77 or an explicit unavailable /
 * not-tested state - never hardcoded example values.
 *
 * No innerHTML with CLI data: only static strings from THIS file's
 * tables/chips ever reach innerHTML (CLI-derived fields go through E()
 * text nodes), same discipline as the luci-app-wanguard core.
 */
'use strict';
'require rpc';
'require uci';
'require ui';

var callCli = rpc.declare({
	object: 'file',
	method: 'exec',
	params: [ 'command', 'params' ],
	expect: { '': {} }
});

/* Discard of the staged-UCI bar: rpcd's config-scoped revert (our ACL
 * grants it in the write class; the luCi uci client itself has no revert
 * wrapper). Only /tmp/.uci deltas for THIS config are cleared. */
var callUciRevert = rpc.declare({
	object: 'uci',
	method: 'revert',
	params: [ 'config' ],
	reject: true
});

var CLI = '/usr/bin/wanguard-antidpi';

/* per-page session state (module closure; one page load = one instance) */
var state = {
	status: null,       /* parsed `status --json` document (#76 contract) */
	strategy: null,     /* { words: [...]|null, error: string|null } from engine-cmdline */
	unavailable: null,  /* null = loading, false = live, 'exec'/'parse' = degraded */
	prevPkts: null,     /* queue packets of the previous tick (processing delta) */
	activeTab: 'overview',
	tabsNode: null,     /* tab bar holder, set by the view render */
	chipsNode: null,    /* chips row holder, set by the view render */
	bodyNode: null,     /* tab body holder, set by the view render */
	exclusionsOpen: false, /* tunnel exclusions panel toggle (kept across ticks) */
	checkDoc: null,     /* last `apply --check --json` document (kept across ticks) */
	checkError: null,   /* rpc failure of the last check run */
	checkBusy: false,
	applyBusy: false,
	discardBusy: false,
	configChanged: false, /* a config-change cycle just committed/reverted - the
	                           next update() rebuilds the editor tabs too (their
	                           after-config renders used the stale status) */
	domains: {          /* Domain lists tab (#82): client-side staged editor */
		loaded: false,    /* the uci config has been read at least once */
		dirty: false,     /* staged edits awaiting the apply pipeline */
		origEnabled: null,  /* committed enabled at load time (mode-flip detect) */
		deleteArm: null,  /* sid armed for the two-step list delete */
		errors: {},       /* inline validation errors, per-list (and '__new') */
		inputs: {},       /* per-list add-domain input text (survives re-renders) */
		newName: ''       /* new-list label input text */
	},
	tunnel: {           /* Tunnel protection tab (#83): client-side staged editor */
		loaded: false,    /* the uci config has been read at least once */
		dirty: false,     /* staged edits awaiting the apply pipeline */
		origPins: null,   /* committed proxy_servers at load time (restart-badge detect) */
		errors: {},       /* inline validation errors, per option */
		inputs: {}        /* add-pin / add-host / number input texts (survive re-renders) */
	},
	profiles: {         /* Profiles tab (#84/#85): list + drawer staged editor */
		loaded: false,    /* the uci config has been read at least once */
		dirty: false,     /* staged edits awaiting the apply pipeline */
		origStrategy: null, /* committed strategy key at load time (restart-badge detect) */
		deleteArm: null,  /* sid armed for the two-step profile delete */
		editor: null,     /* drawer: { sid: 'new'|<sid>, presetArm: bool } or null */
		draft: null,      /* new-profile drawer draft: { name, proto, wordsText, color } */
		errors: {},       /* inline validation errors, per profile (and 'editor') */
		inputs: {}        /* per-profile words textarea + name input texts */
	},
	policies: {         /* Policies tab (#87): table + drawer staged editor */
		loaded: false,    /* the uci config has been read at least once */
		dirty: false,     /* staged edits awaiting the apply pipeline */
		origArgvKey: null,  /* committed policy argv key at load (restart-badge detect) */
		deleteArm: null,  /* sid armed for the two-step policy delete */
		menuOpen: null,   /* sid of the open row actions menu (the «…» column) */
		search: '',       /* table search text (client-side filter) */
		editor: null,     /* drawer: { sid: 'new'|<sid>, advanced: bool } or null */
		draft: null,      /* new-policy drawer draft: { name, device_group, domainlist,
		                       proto[], action, profile, enabled } */
		dragSid: null,    /* row sid held by the HTML5 drag (reorder on drop) */
		errors: {},       /* inline validation errors, per policy (and 'editor') */
		inputs: {}        /* per-policy name/device_group/priority input texts */
	},
	tests: {            /* Tests & Logs tab (#88): counters + log viewer + debug toggle */
		countersHost: null, /* the counters card holder - patched per tick (the
		                         log snapshot and the debug editor must survive) */
		origDebug: null,  /* committed engine.debug at load (restart-badge detect) */
		logBusy: false,
		logError: null,   /* rpc/exec failure of the last log fetch */
		logFilter: 'engine',
		logLines: null,   /* last fetched snapshot (array of lines) or null = never fetched */
		logAvail: null    /* last snapshot's availability (logread present) */
	},
	prevCounters: null, /* the counters snapshot of the previous tick (#88 deltas) */
	busy: false
};

/* sub-tab frame (issue #80): the order of the concept mock; every tab is
 * real since #88 (#81 overview, #82 domain lists, #83 tunnel protection,
 * #84/#85 profiles, #86/#87 policies, #88 tests & logs) - the placeholder
 * branch below stays as the honest fallback for future tabs */
var TABS = [ 'overview', 'profiles', 'policies', 'domains', 'tunnel', 'tests' ];

function tabLabel(id) {
	switch (id) {
		case 'overview': return _('Overview');
		case 'profiles': return _('Profiles');
		case 'policies': return _('Policies');
		case 'domains':  return _('Domain lists');
		case 'tunnel':   return _('Tunnel protection');
		case 'tests':    return _('Tests & Logs');
	}
	return id;
}

/* Tab grammar = the luci-app-wanguard wg-tab look (issue #80 "active-стиль
 * wg-tab"): the four .wg-tabs rules below are byte-identical to the wanguard
 * core stylesheet so the pages read identically when BOTH packages are
 * installed and this page still styles correctly in standalone mode. All
 * .wg-ad-* names are antidpi-owned. */
var CSS = [
	".wg-tabs { display:flex; gap:.25em; border-bottom:1px solid rgba(128,128,128,.25); margin:.75em 0; }",
	".wg-tab { background:none; border:none; border-bottom:2px solid transparent; padding:.45em .9em; cursor:pointer; opacity:.6; font-size:1em; }",
	".wg-tab:hover { opacity:.85; }",
	".wg-tab-active { opacity:1; border-bottom-color:#2563eb; font-weight:bold; }",
	".wg-ad-head { display:flex; justify-content:space-between; align-items:flex-start; gap:1em; flex-wrap:wrap; }",
	".wg-ad-sub { opacity:.6; display:block; }",
	".wg-ad-actions { display:flex; gap:.6em; flex-shrink:0; padding-top:.35em; }",
	".wg-ad-chips { display:flex; gap:.6em; flex-wrap:wrap; align-items:center; margin:-.25em 0 .5em; }",
	".wg-ad-chip { display:inline-flex; align-items:center; gap:.4em; padding:.15em .7em; border-radius:1em; font-size:.82em; background:rgba(128,128,128,.12); white-space:nowrap; cursor:default; }",
	".wg-ad-dot { display:inline-block; width:.6em; height:.6em; border-radius:50%; background:rgba(128,128,128,.5); }",
	".wg-ad-chip-ok { background:rgba(34,197,94,.12); color:#15803d; }",
	".wg-ad-chip-ok .wg-ad-dot { background:#22c55e; }",
	".wg-ad-chip-warn { background:rgba(234,88,12,.12); color:#c2410c; }",
	".wg-ad-chip-warn .wg-ad-dot { background:#ea580c; }",
	".wg-ad-chip-muted { opacity:.6; }",
	".wg-ad-word { font-family:monospace; font-size:.78em; cursor:default; }",
	".wg-ad-degraded { font-size:.82em; opacity:.65; margin:0 0 .75em; }",
	".wg-ad-panel { background:rgba(128,128,128,.06); border:1px solid rgba(128,128,128,.3); border-radius:6px; padding:1em; margin:0 0 .9em; }",
	".wg-ad-panel h3 { margin:0 0 .4em; }",
	".wg-ad-hint { opacity:.55; margin:0; }",
	".wg-ad-bar { border-left:3px solid #ea580c; }",
	".wg-ad-kv { display:flex; gap:.6em; margin:.15em 0; font-size:.9em; }",
	".wg-ad-kv-label { opacity:.6; min-width:9em; }",
	".wg-ad-table { width:100%; border-collapse:collapse; font-size:.85em; margin:.4em 0; }",
	".wg-ad-table th { text-align:left; opacity:.6; font-weight:normal; padding:.25em .5em; border-bottom:1px solid rgba(128,128,128,.3); }",
	".wg-ad-table td { text-align:left; padding:.25em .5em; border-bottom:1px solid rgba(128,128,128,.15); }",
	".wg-ad-check-ok { color:#15803d; }",
	".wg-ad-check-fail { color:#c2410c; font-weight:bold; }",
	".wg-ad-check-muted { opacity:.55; }",
	".wg-ad-error { color:#c2410c; font-size:.85em; margin:.2em 0; }",
	".wg-ad-modebtn-active { font-weight:bold; border-bottom:2px solid #2563eb; }",
	".wg-ad-domrow { display:flex; align-items:center; gap:.5em; padding:.15em 0; border-bottom:1px dotted rgba(128,128,128,.2); font-family:monospace; font-size:.85em; }",
	".wg-ad-domremove { background:none; border:none; cursor:pointer; color:#c2410c; padding:0 .3em; font-size:1em; }",
	".wg-ad-addrow { display:flex; gap:.4em; margin:.5em 0 0; }",
	".wg-ad-addrow input { flex:1; min-width:14em; }",
	".wg-ad-profrow { display:flex; align-items:center; gap:.5em; flex-wrap:wrap; padding:.45em 0; border-top:1px solid rgba(128,128,128,.18); }",
	".wg-ad-profrow-off { opacity:.55; }",
	".wg-ad-dot-blue { background:#2563EB; }",
	".wg-ad-dot-green { background:#22C55E; }",
	".wg-ad-dot-purple { background:#7C3AED; }",
	".wg-ad-dot-orange { background:#EA580C; }",
	".wg-ad-dot-gray { background:#6B7280; }",
	".wg-ad-editor { background:rgba(128,128,128,.06); border:1px solid rgba(128,128,128,.3); border-left:4px solid rgba(128,128,128,.45); border-radius:6px; padding:1em; margin:0 0 .9em; }",
	".wg-ad-presetrow { display:flex; gap:.5em; align-items:center; flex-wrap:wrap; margin:.4em 0; }",
	".wg-ad-words { width:100%; min-height:7em; font-family:monospace; font-size:.85em; white-space:pre; }",
	".wg-ad-rowmenu { display:flex; gap:.5em; align-items:center; flex-wrap:wrap; padding:.3em 0 .45em .7em; margin-left:.4em; border-left:2px solid rgba(128,128,128,.35); }",
	".wg-ad-polrow { cursor:grab; }",
	".wg-ad-search { min-width:16em; }",
	".wg-ad-log { max-height:22em; overflow:auto; font-family:monospace; font-size:.78em; white-space:pre-wrap; word-break:break-all; background:rgba(128,128,128,.08); border-radius:4px; padding:.6em; margin:.4em 0; }",
	".wg-ad-copy { background:none; border:1px solid rgba(128,128,128,.4); border-radius:3px; cursor:pointer; font-size:.78em; padding:.05em .5em; opacity:.7; color:inherit; }",
	".wg-ad-copy:hover { opacity:1; }"
].join('\n');

/* ---------- status fetching / parsing ---------- */

/* rpc/file exec failures (binary missing, ACL denied) reject the promise;
 * an ANSWER that is not a #76 JSON document (pre-status CLI: the usage
 * error goes to stderr, stdout stays empty) means "old package" */
function parseStatus(res) {
	var doc = null;
	if (res && typeof res.stdout == 'string' && res.stdout.length) {
		try {
			doc = JSON.parse(res.stdout);
		}
		catch (e) {}
	}
	if (doc && doc.service && doc.engine && doc.mihomo && doc.pending &&
	    ('degraded' in doc)) {
		state.status = doc;
		state.unavailable = false;
	}
	else {
		state.status = null;
		state.unavailable = res ? 'parse' : 'exec';
	}
}

/* engine-cmdline stdout: line 1 is the engine binary path, the rest are the
 * rendered argv words, one per line (#76 gotcha: the LIVE /proc cmdline of
 * a running engine carries the binary too - the rendered surface is the
 * authority). rc != 0 = the config does not render; stderr carries the
 * human reason and becomes the strategy card's warn line. */
function parseCmdline(res) {
	if (res && res.code == 0 && typeof res.stdout == 'string') {
		var lines = res.stdout.split('\n').map(function(s) { return s.trim(); })
			.filter(function(s) { return s.length > 0; });
		lines.shift();
		state.strategy = { words: lines, error: null };
		return;
	}
	var reason = (res && typeof res.stderr == 'string' && res.stderr.length)
		? res.stderr.split('\n')[0].trim() : null;
	state.strategy = { words: null, error: reason };
}

/* never rejects: every caller can .then() unconditionally (issue #80
 * "без throw"). The strategy words ride along only when the status surface
 * is alive (a pre-status CLI cannot render the page anyway). */
function refresh() {
	return callCli(CLI, [ 'status', '--json' ]).then(function(res) {
		parseStatus(res);
	}).catch(function() {
		state.status = null;
		state.unavailable = 'exec';
	}).then(function() {
		if (state.unavailable) {
			state.strategy = null;
			return;
		}
		return callCli(CLI, [ 'engine-cmdline' ]).then(function(res) {
			parseCmdline(res);
		}).catch(function() {
			state.strategy = { words: null, error: _('The strategy surface is unavailable') };
		});
	});
}

/* ---------- shared render helpers ---------- */

function chipEl(def) {
	return E('span', { 'class': 'wg-ad-chip ' + def.cls, 'title': def.title || '' }, [
		E('span', { 'class': 'wg-ad-dot' }, []),
		' ',
		def.label
	]);
}

function kvRow(label, valueNodes) {
	return E('div', { 'class': 'wg-ad-kv' }, [
		E('span', { 'class': 'wg-ad-kv-label' }, [ label ]),
		E('span', {}, valueNodes)
	]);
}

/* a validation row: ok == true -> green ok, false -> red FAILED, null ->
 * muted (not run / not applicable / never tested). The detail text renders
 * whenever present: failure reasons, mode notes ("not consumed in this
 * mode") and the muted provider row's standing "Not tested" hint. */
function checkRow(label, ok, detail) {
	var mark, cls;
	if (ok === true) {
		mark = _('ok');
		cls = 'wg-ad-check-ok';
	}
	else if (ok === false) {
		mark = _('FAILED');
		cls = 'wg-ad-check-fail';
	}
	else {
		mark = _('—');
		cls = 'wg-ad-check-muted';
	}
	return E('tr', {}, [
		E('td', {}, [ label ]),
		E('td', { 'class': cls, 'title': detail || '' }, [ mark ]),
		E('td', {}, [ (detail != null) ? detail : '' ])
	]);
}

/* ---------- chips row (issue #80): Engine / Processing / Scope / Pending ---------- */

/* Engine Running: the nfqws2 pid from the status document; stopped is an
 * honest state (the service may be disabled), not a degradation */
function engineChip() {
	var st = state.status;
	if (st.engine.pid != null)
		return { cls: 'wg-ad-chip-ok', label: _('Engine running') };
	return { cls: 'wg-ad-chip-muted', label: _('Engine stopped') };
}

/* Processing Active: the queue counters of the two 443 rules TICK when the
 * engine handles marked traffic — the chip follows the client-side delta
 * between consecutive polls (the concept's "queue-дельты", spike-75 §6).
 * First tick has no delta evidence yet -> idle; a table with no counters
 * is a degraded surface -> Table absent. The same snapshot feeds the Tests
 * & Logs counters card (#88): prevCounters is the previous tick's object
 * (every refresh re-parses the status document, so the reference never
 * aliases the current tick). */
function processingChip() {
	var st = state.status;
	var c = (st.nft && st.nft.counters) ? st.nft.counters : null;
	if (c == null) {
		state.prevPkts = null;
		state.prevCounters = null;
		return { cls: 'wg-ad-chip-warn',
			label: (st.nft && st.nft.table_present) ? _('Processing unknown') : _('Table absent') };
	}
	var pkts = ((c.tcp && c.tcp.packets != null) ? c.tcp.packets : 0) +
		((c.udp && c.udp.packets != null) ? c.udp.packets : 0);
	var active = (state.prevPkts != null && pkts > state.prevPkts);
	state.prevPkts = pkts;
	state.prevCounters = c;
	return active
		? { cls: 'wg-ad-chip-ok', label: _('Processing active') }
		: { cls: 'wg-ad-chip-muted', label: _('Processing idle') };
}

/* Scope mihomo DIRECT: the routing-mark integration state (#60) — the queue
 * only sees mihomo DIRECT egress when the mark is installed */
function scopeChip() {
	var m = state.status.mihomo;
	if (m.state == 'installed')
		return { cls: 'wg-ad-chip-ok', label: _('Scope mihomo DIRECT'),
			title: (m.mark != null) ? 'routing-mark ' + m.mark : '' };
	if (m.state == 'conflict')
		return { cls: 'wg-ad-chip-warn', label: _('Mark conflict'),
			title: (m.mark != null) ? 'routing-mark ' + m.mark : '' };
	return { cls: 'wg-ad-chip-warn', label: _('Mark not installed') };
}

/* N pending change: the staged-UCI counter of the status document; null
 * means the surface itself is degraded (#76) */
function pendingChip() {
	var p = state.status.pending;
	if (p.count == null)
		return { cls: 'wg-ad-chip-muted', label: _('Pending unknown') };
	if (p.count > 0)
		return { cls: 'wg-ad-chip-warn', label: '%d pending change(s)'.format(p.count) };
	return { cls: 'wg-ad-chip-muted', label: _('No pending changes') };
}

/* degraded map of the status document (muted hint line; the per-surface
 * "unavailable" cards belong to the content stages #81–#88). The keys are
 * the CLI's own surface identifiers - rendered as text nodes only. */
function degradedLine() {
	var d = state.status.degraded;
	var keys = [];
	for (var k in d)
		if (d[k] != null)
			keys.push(k);
	if (!keys.length)
		return E([]);
	keys.sort();
	return E('div', { 'class': 'wg-ad-degraded' }, [
		_('Degraded surfaces: %s').format(keys.join(', '))
	]);
}

function updateChips() {
	var node = state.chipsNode;
	if (!node)
		return;
	node.innerHTML = '';

	if (state.unavailable || !state.status) {
		/* muted variant for the unavailable page (#80): one honest chip
		 * instead of four lies (also covers the pre-first-refresh tick) */
		node.appendChild(chipEl({ cls: 'wg-ad-chip-muted', label: _('Status unavailable') }));
		return;
	}

	node.appendChild(chipEl(engineChip()));
	node.appendChild(chipEl(processingChip()));
	node.appendChild(chipEl(scopeChip()));
	node.appendChild(chipEl(pendingChip()));
	node.appendChild(degradedLine());
}

/* ---------- overview: strategy card (#81) ---------- */

/* Split the rendered argv into profile blocks: the engine grammar separates
 * blocks with --new and the LAST block is the default catch-all (design §3,
 * spike-75). Until the profiles stage (#85) this list is DERIVED from the
 * active word set - the honest read-only view the issue asks for. */
function parseStrategy(words) {
	var groups = [ [] ];
	words.forEach(function(w) {
		if (w == '--new')
			groups.push([]);
		else
			groups[groups.length - 1].push(w);
	});
	return groups.map(function(g, i) {
		var proto = [];
		var desync = 0;
		g.forEach(function(w) {
			if (w.indexOf('--filter-tcp=') == 0 && proto.indexOf('TCP') < 0)
				proto.push('TCP');
			if (w.indexOf('--filter-udp=') == 0 && proto.indexOf('QUIC') < 0)
				proto.push('QUIC');
			if (w.indexOf('--lua-desync=') == 0)
				desync++;
		});
		return {
			name: (groups.length == 1 || i == groups.length - 1)
				? _('Default (catch-all)') : _('Profile %d').format(i + 1),
			words: g,
			proto: proto,
			desync: desync
		};
	});
}

function buildStrategyCard() {
	var st = state.status;
	var s = state.strategy;
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Current strategy') ])
	]);

	if (s == null) {
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading strategy words…') ]));
		return card;
	}
	if (s.error != null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ (s.error.length > 0)
				? _('The strategy configuration does not render: %s').format(s.error)
				: _('The strategy configuration does not render.') ])
		]));
		return card;
	}
	if (!s.words.length) {
		card.appendChild(E('p', {}, [ _('No strategy words configured - the engine runs in no-op mode.') ]));
		return card;
	}

	var row = E('div', { 'class': 'wg-ad-chips' });
	s.words.forEach(function(w) {
		row.appendChild(E('span', { 'class': 'wg-ad-chip wg-ad-word' }, [ w ]));
	});
	card.appendChild(row);

	var groups = parseStrategy(s.words);
	/* named profiles (#84): when the rendered block count matches the
	 * enabled-with-words section count, show the real section names -
	 * otherwise keep the generic labels (the render skips empty/disabled
	 * profiles, so a mismatch is honest) */
	var secs = (st.engine && st.engine.profile_sections) || [];
	var names = null;
	if (secs.length) {
		var en = secs.filter(function(p) { return p.enabled && p.words > 0; })
			.map(function(p) { return p.name; });
		if (en.length == groups.length)
			names = en;
	}

	var table = E('table', { 'class': 'wg-ad-table' }, [
		E('tr', {}, [
			E('th', {}, [ _('Profile') ]),
			E('th', {}, [ _('Protocols') ]),
			E('th', {}, [ _('Words') ]),
			E('th', {}, [ _('Policies') ])
		])
	]);
	groups.forEach(function(p, i) {
		table.appendChild(E('tr', {}, [
			E('td', {}, [ (names && names[i]) ? names[i] : p.name ]),
			E('td', {}, [ p.proto.join(' ') || _('—') ]),
			E('td', {}, [ '%d'.format(p.words.length) ]),
			E('td', {}, [ '%d'.format(p.desync) ])
		]));
	});
	card.appendChild(table);

	/* the concept's "Open profiles" affordance (#85): jump from the live
	 * strategy view to the profiles management */
	var meta = [];
	if (st.engine && st.engine.version != null)
		meta.push(st.engine.version);
	card.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() { switchTab('profiles'); })
		}, [ _('Open profiles') ])
	]));
	if (meta.length)
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ meta.join(' · ') ]));
	return card;
}

/* ---------- overview: tunnel protection card (#81) ---------- */

function buildExclusionsPanel(t) {
	var table = E('table', { 'class': 'wg-ad-table' }, [
		E('tr', {}, [
			E('th', {}, [ _('Address') ]),
			E('th', {}, [ _('Source') ]),
			E('th', {}, [ _('Expires') ])
		])
	]);
	(t.entries || []).forEach(function(e) {
		var src = (e.source == 'pin') ? _('pin') : _('resolved');
		var exp = (e.source == 'pin' || e.expires_h == null)
			? _('never') : _('%d h').format(e.expires_h);
		table.appendChild(E('tr', {}, [
			E('td', {}, [ e.ip ]),
			E('td', {}, [ src ]),
			E('td', {}, [ exp ])
		]));
	});
	if (!(t.entries || []).length)
		table.appendChild(E('tr', {}, [
			E('td', { 'colspan': '3' }, [ _('The merged exclusion set is empty.') ])
		]));
	return table;
}

function buildTunnelCard() {
	var t = state.status.tunnel;
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Tunnel protection') ])
	]);

	if (t == null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The tunnel protection surface is unavailable.') ])
		]));
		return card;
	}

	var hosts = (t.hosts && t.hosts.length) ? t.hosts.join(', ') : null;
	var entries = (t.entries || []).length;
	var cronOk = (t.cron != null && t.cron.ok);

	/* badge: the honest protection state of the configured tunnel */
	var badge;
	if (!hosts)
		badge = chipEl({ cls: 'wg-ad-chip-muted', label: _('Not configured') });
	else if (entries > 0 && cronOk)
		badge = chipEl({ cls: 'wg-ad-chip-ok', label: _('Protected'),
			title: (hosts.length > 60) ? hosts : '' });
	else
		badge = chipEl({ cls: 'wg-ad-chip-warn', label: _('Unprotected') });

	card.appendChild(badge);
	card.appendChild(kvRow(_('Hostname(s)'), [ hosts || _('—') ]));
	card.appendChild(kvRow(_('Mode'), [ _('Static pins + auto-resolved addresses') ]));

	var refreshTxt = (t.update_interval_h != null)
		? _('every %d h').format(t.update_interval_h) : _('unknown');
	refreshTxt += (cronOk) ? ' · ' + _('cron active') : ' · ' + _('cron MISSING');
	card.appendChild(kvRow(_('Refresh'), [ refreshTxt ]));
	card.appendChild(kvRow(_('Exclusions'), [ '%d'.format(entries) ]));

	card.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() {
				state.exclusionsOpen = !state.exclusionsOpen;
				renderBody();
			})
		}, [ state.exclusionsOpen ? _('Hide exclusions') : _('Review exclusions') ])
	]));

	if (state.exclusionsOpen)
		card.appendChild(buildExclusionsPanel(t));
	return card;
}

/* ---------- overview: validation card (#81) ---------- */

/* tunnel exclusions row: derived from the status document (#76) - the CLI
 * check (#77) probes config/nft/mark/engine/hostlist and has no tunnel
 * probe of its own */
function tunnelCheck() {
	var t = state.status.tunnel;
	if (t == null)
		return { ok: null, detail: _('surface unavailable') };
	var hosts = (t.hosts && t.hosts.length) ? t.hosts.length : 0;
	if (!hosts)
		return { ok: null, detail: _('no tunnel hosts configured') };
	var entries = (t.entries || []).length;
	var cronOk = (t.cron != null && t.cron.ok);
	if (entries > 0 && cronOk)
		return { ok: true, detail: null };
	return {
		ok: false,
		detail: _('%d host(s) configured, %d resolved entries, cron %s')
			.format(hosts, entries, cronOk ? 'ok' : _('missing'))
	};
}

function hostlistDetail(h) {
	if (h == null)
		return null;
	if (!h.needed)
		return _('not consumed in this mode');
	return (h.exists) ? null : _('the hostlist file is missing');
}

/* The full row set ALWAYS renders: check rows stay muted (— / Not run yet)
 * until the first Run checks, the tunnel row is live from the status
 * document, and the provider row is a standing muted "Not tested" (active
 * probing is its own backlog stage, #92). */
function buildValidationCard() {
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Validation') ])
	]);

	if (state.checkError != null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The check run failed: %s').format(state.checkError) ])
		]));
	}

	var c = (state.checkDoc != null) ? (state.checkDoc.checks || {}) : null;
	function ck(key) { return (c != null && c[key] != null) ? c[key].ok : null; }
	function det(key) { return (c != null && c[key] != null) ? c[key].detail : null; }

	var table = E('table', { 'class': 'wg-ad-table' });
	table.appendChild(checkRow(_('Configuration syntax'), ck('config'), det('config')));
	table.appendChild(checkRow(_('Scope table (nft)'), ck('nft'), det('nft')));
	table.appendChild(checkRow(_('routing-mark'), ck('mark'), det('mark')));
	table.appendChild(checkRow(_('Engine running'), ck('engine'), det('engine')));
	table.appendChild(checkRow(_('Hostlist'), ck('hostlist'), hostlistDetail(c != null ? c.hostlist : null)));
	var tc = tunnelCheck();
	table.appendChild(checkRow(_('Tunnel exclusions'), tc.ok, tc.detail));
	table.appendChild(checkRow(_('Provider effectiveness'), null,
		_('Not tested - active probing arrives in a later release')));
	card.appendChild(table);

	if (state.checkDoc == null && state.checkError == null)
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Not run yet.') ]));

	card.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, runChecks),
			'disabled': state.checkBusy ? '' : null
		}, [ _('Run checks') ])
	]));
	return card;
}

function runChecks() {
	state.busy = true;
	state.checkBusy = true;
	renderBody();
	return callCli(CLI, [ 'apply', '--check', '--json' ]).then(function(res) {
		var doc = null;
		if (res && typeof res.stdout == 'string' && res.stdout.length) {
			try {
				doc = JSON.parse(res.stdout);
			}
			catch (e) {}
		}
		if (doc != null && doc.checks != null) {
			state.checkDoc = doc;
			state.checkError = null;
		}
		else {
			/* keep a previous document visible; surface the failure */
			state.checkError = (res && typeof res.stderr == 'string' && res.stderr.length)
				? res.stderr.split('\n')[0].trim()
				: _('the output is not a check report');
		}
		state.checkBusy = false;
		state.busy = false;
		renderBody();
	}).catch(function() {
		state.checkBusy = false;
		state.busy = false;
		state.checkError = _('the check could not be executed');
		renderBody();
	});
}

/* ---------- overview: pending-change bar (#81) ---------- */

function buildPendingBar(p) {
	var sections = (p.sections && p.sections.length) ? p.sections.join(', ') : null;
	return E('div', { 'class': 'wg-ad-panel wg-ad-bar' }, [
		E('strong', {}, [ _('Review configuration before applying') ]),
		E('p', {}, [ (sections != null)
			? _('%d staged change(s) in: %s').format(p.count, sections)
			: _('%d staged change(s)').format(p.count) ]),
		E('div', { 'class': 'wg-ad-actions' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'click': ui.createHandlerFn(null, discardPending),
				'disabled': state.discardBusy ? '' : null
			}, [ _('Discard') ]),
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(null, reviewApply),
				'disabled': state.applyBusy ? '' : null
			}, [ _('Review & Apply') ])
		])
	]);
}

/* Discard: clear the staged UCI deltas of THIS config only (rpcd uci revert,
 * config-scoped). Idempotent by construction (nothing staged = no-op). The
 * editor's client-side staged edits are dropped with the same intent - the
 * uci client's unload+reload re-reads the committed truth. */
function discardPending() {
	state.busy = true;
	state.discardBusy = true;
	renderBody();
	return callUciRevert('wanguard-antidpi').then(function() {
		state.discardBusy = false;
		state.busy = false;
		uci.unload('wanguard-antidpi');
		state.configChanged = true;
		domainsAfterConfigChange();
		tunnelAfterConfigChange();
		profilesAfterConfigChange();
		policiesAfterConfigChange();
		testsAfterConfigChange();
		ui.changes.init();
		return refresh().then(update);
	}).catch(function(e) {
		state.discardBusy = false;
		state.busy = false;
		ui.addNotification(null, E('p', {}, _('Discarding the staged changes failed (%s).')
			.format((e && e.message) || 'error')), 'error');
		renderBody();
	});
}

/* Review & Apply: commit the staged UCI first (the ucode CLI reads COMMITTED
 * config only - proven in the container: a staged delta is invisible to the
 * render), then run the idempotent #77 apply. uci.apply(5) is the luci-app-
 * wanguard idiom (rollback window + client-driven confirm). */
function reviewApply() {
	state.busy = true;
	state.applyBusy = true;
	renderBody();
	return uci.save().then(function() {
		return uci.apply(5);
	}).then(function() {
		return callCli(CLI, [ 'apply', '--json' ]);
	}).then(function(res) {
		state.applyBusy = false;
		state.busy = false;
		ui.addNotification(null, E('p', {}, [ applyNotice(res) ]), applySeverity(res));
		ui.changes.init();
		state.configChanged = true;
		domainsAfterConfigChange();
		tunnelAfterConfigChange();
		profilesAfterConfigChange();
		policiesAfterConfigChange();
		testsAfterConfigChange();
		return refresh().then(update);
	}).catch(function(e) {
		state.applyBusy = false;
		state.busy = false;
		ui.addNotification(null, E('p', {}, _('Applying the configuration failed (%s).')
			.format((e && e.message) || 'error')), 'error');
		return refresh().then(update);
	});
}

/* { ok, partial, steps } on exit 0/1/2; anything else = the output could
 * not be parsed (the honest error line) */
function applyNotice(res) {
	var doc = null;
	if (res && typeof res.stdout == 'string' && res.stdout.length) {
		try {
			doc = JSON.parse(res.stdout);
		}
		catch (e) {}
	}
	if (doc == null || doc.steps == null)
		return _('The apply output could not be parsed - check the system log.');
	var steps = [];
	for (var k in doc.steps)
		steps.push('%s:%s'.format(k, doc.steps[k]));
	if (doc.ok != true)
		return _('Apply FAILED (steps: %s).').format(steps.join(', '));
	if (doc.partial)
		return _('Apply PARTIAL (steps: %s).').format(steps.join(', '));
	return _('Configuration applied: %s.').format(steps.join(', '));
}

function applySeverity(res) {
	var doc = null;
	if (res && typeof res.stdout == 'string' && res.stdout.length) {
		try {
			doc = JSON.parse(res.stdout);
		}
		catch (e) {}
	}
	if (doc == null || doc.ok != true)
		return 'error';
	if (doc.partial)
		return 'warning';
	return 'info';
}

/* ---------- overview assembly (#81) ---------- */

function renderOverview() {
	var frag = E([]);

	/* defensive: LuCI always calls load() (the refresh) before render(), but
	 * a direct renderBody() before the first tick must not throw (#80 rule) */
	if (!state.status) {
		frag.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading status…') ]));
		return frag;
	}

	/* the concept's standing notice */
	frag.appendChild(E('div', { 'class': 'alert-message' }, [
		E('p', {}, [ _('Only mihomo DIRECT traffic is eligible. Proxy tunnel and local destinations remain excluded.') ])
	]));

	var p = state.status.pending;
	if (p != null && p.count != null && p.count > 0)
		frag.appendChild(buildPendingBar(p));

	frag.appendChild(buildStrategyCard());
	frag.appendChild(buildTunnelCard());
	frag.appendChild(buildValidationCard());

	return frag;
}

/* ---------- domain lists tab (#82) ---------- */

/* strict-DNS validation - the exact mirror of the CLI's valid_hostname
 * (ucode): labels of letters/digits/hyphens, at least two labels, 253-octet
 * presentation limit. Invalid input NEVER reaches the staged config, so the
 * render-time loud fail of #70 stays unreachable from the UI. */
function domainIsValid(d) {
	if (typeof d != 'string' || d.length == 0 || d.length > 253)
		return false;
	return /^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/.test(d);
}

/* how many policies reference this list by section name (design §2). The
 * policy schema ships with its own stage (#87) - today this is always 0. */
function domainsPolicyUse(sid) {
	return (uci.sections('wanguard-antidpi', 'policy') || [])
		.filter(function(p) { return p.domainlist == sid; }).length;
}

/* the tab's view model: legacy whitelist.domains + every domainlist section
 * (the LuCI uci client merges committed values, router-staged deltas and
 * the client's own staged edits - the same staged-first contract the
 * pending bar applies) plus the merged effective count the CLI renders. */
function domainsModel() {
	var lists = (uci.sections('wanguard-antidpi', 'domainlist') || []).map(function(s) {
		return {
			sid: s['.name'],
			label: (typeof s.name == 'string' && s.name.length) ? s.name : s['.name'],
			domains: (Array.isArray(s.domains) ? s.domains : []).slice(),
			legacy: false,
			policies: domainsPolicyUse(s['.name'])
		};
	});
	var legacy = {
		sid: 'whitelist',
		label: _('Legacy list'),
		domains: (function(v) { return (Array.isArray(v) ? v : []).slice(); })(uci.get('wanguard-antidpi', 'whitelist', 'domains')),
		legacy: true,
		policies: 0
	};
	var seen = {}, mergedCount = 0;
	[ legacy ].concat(lists).forEach(function(l) {
		l.domains.forEach(function(d) {
			if (!seen[d]) { seen[d] = 1; mergedCount++; }
		});
	});
	var enabled = (uci.get('wanguard-antidpi', 'whitelist', 'enabled') == '1');
	return {
		enabled: enabled,
		enabledStaged: (state.domains.origEnabled != null && enabled != state.domains.origEnabled),
		legacy: legacy,
		lists: lists,
		mergedCount: mergedCount
	};
}

/* the whitelist section is soft (blanket = section absent); stage a named
 * create before mutating options on it (uci.set silently no-ops on a
 * section that is neither committed nor client-created) */
function domainsEnsureSection() {
	if (!uci.get('wanguard-antidpi', 'whitelist'))
		uci.add('wanguard-antidpi', 'whitelist', 'whitelist');
}

function domainsMarkDirty() {
	state.domains.dirty = true;
}

/* 'list_video_domains'-style stable section id derived from the label (the
 * design contract: refs go by section name, the label is editable) */
function domainsSlug(label) {
	var base = ('list_' + label.toLowerCase().replace(/[^a-z0-9]+/g, '_')
		.replace(/^_+|_+$/g, '')).replace(/^list_list/, 'list').slice(0, 48);
	var sid = base, n = 2;
	while (uci.get('wanguard-antidpi', sid) != null) {
		sid = base + '_' + n;
		n++;
	}
	return sid;
}

function domainsFindList(model, sid) {
	if (sid == 'whitelist')
		return model.legacy;
	return model.lists.filter(function(l) { return l.sid == sid; })[0] || null;
}

function domainsSetMode(on) {
	domainsEnsureSection();
	uci.set('wanguard-antidpi', 'whitelist', 'enabled', on ? '1' : '0');
	domainsMarkDirty();
	renderDomains();
}

function domainsAddDomain(sid) {
	var d = (state.domains.inputs[sid] || '').trim();
	var err = null;
	if (d.length == 0)
		err = _('Enter a domain name.');
	else if (!domainIsValid(d))
		err = _('Not a valid DNS hostname (no wildcards, commas or spaces; at least two labels).');
	else if (domainsFindList(domainsModel(), sid).domains.indexOf(d) >= 0)
		err = _('"%s" is already in this list.'.format(d));
	if (err != null) {
		state.domains.errors[sid] = err;
		renderDomains();
		return;
	}
	delete state.domains.errors[sid];
	if (sid == 'whitelist')
		domainsEnsureSection();
	var next = (function(v) { return (Array.isArray(v) ? v : []).slice(); })(uci.get('wanguard-antidpi', sid, 'domains'));
	next.push(d);
	uci.set('wanguard-antidpi', sid, 'domains', next);
	state.domains.inputs[sid] = '';
	domainsMarkDirty();
	renderDomains();
}

function domainsRemoveDomain(sid, idx) {
	if (sid == 'whitelist')
		domainsEnsureSection();
	var next = (function(v) { return (Array.isArray(v) ? v : []).slice(); })(uci.get('wanguard-antidpi', sid, 'domains'));
	if (idx < 0 || idx >= next.length)
		return;
	next.splice(idx, 1);
	uci.set('wanguard-antidpi', sid, 'domains', next);
	delete state.domains.errors[sid];
	domainsMarkDirty();
	renderDomains();
}

function domainsCreateList() {
	var label = (state.domains.newName || '').trim();
	if (label.length == 0) {
		state.domains.errors['__new'] = _('Enter a list name.');
		renderDomains();
		return;
	}
	delete state.domains.errors['__new'];
	var sid = domainsSlug(label);
	uci.add('wanguard-antidpi', 'domainlist', sid);
	uci.set('wanguard-antidpi', sid, 'name', label);
	uci.set('wanguard-antidpi', sid, 'domains', []);
	state.domains.newName = '';
	domainsMarkDirty();
	renderDomains();
}

function domainsDeleteList(sid) {
	/* policy-ref guard (#87): a delete must never orphan a policy - the
	 * render would die loudly at apply time (the #86 contract) */
	var used = domainsPolicyUse(sid);
	if (used > 0) {
		state.domains.errors[sid] = _('Referenced by %d policy(s) - unlink them first.').format(used);
		state.domains.deleteArm = null;
		renderDomains();
		return;
	}
	if (state.domains.deleteArm != sid) {
		state.domains.deleteArm = sid;
		renderDomains();
		return;
	}
	uci.remove('wanguard-antidpi', sid);
	state.domains.deleteArm = null;
	domainsMarkDirty();
	renderDomains();
}

/* drop the client-side staged edits without touching the router (the
 * pending bar's Discard covers the router-side deltas); unload+load is the
 * uci client's reset for one config */
function domainsDiscardEdits() {
	state.domains.dirty = false;
	state.domains.origEnabled = null;
	state.domains.deleteArm = null;
	state.domains.errors = {};
	state.domains.inputs = {};
	state.domains.newName = '';
	uci.unload('wanguard-antidpi');
	renderDomains();
}

/* after the shared apply pipeline committed (or the router deltas were
 * reverted), the editor starts clean from the committed truth */
function domainsAfterConfigChange() {
	state.domains.dirty = false;
	state.domains.origEnabled = null;
	state.domains.deleteArm = null;
	state.domains.errors = {};
	state.domains.inputs = {};
	state.domains.newName = '';
	if (state.activeTab == 'domains')
		renderDomains();
}

/* the shared pipeline with the editor's one client-side guard: a staged
 * whitelist mode with an empty merged set would die at render time (the
 * #70 loud fail) - block it here with an inline explanation instead */
function domainsApply() {
	var m = domainsModel();
	if (m.enabled && m.mergedCount == 0) {
		ui.addNotification(null, E('p', {},
			_('Whitelist mode needs at least one domain - add domains or switch back to blanket mode first.')), 'error');
		return;
	}
	reviewApply();
}

function domainsListPanel(model, l) {
	var panel = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ l.label, ' ',
			(l.legacy) ? chipEl({ cls: 'wg-ad-chip-muted', label: _('legacy'),
				title: _('Pre-domainlist storage (whitelist.domains) - kept for compatibility') }) : E([]),
			' ',
			chipEl({ cls: 'wg-ad-chip-muted', label: '%d domain(s)'.format(l.domains.length) })
		])
	]);
	panel.appendChild(kvRow(_('Used by policies'), [
		(l.policies > 0) ? '%d'.format(l.policies) : _('—')
	]));

	if (l.domains.length == 0) {
		panel.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Empty list - contributes no domains.') ]));
	}
	l.domains.forEach(function(d, idx) {
		panel.appendChild(E('div', { 'class': 'wg-ad-domrow' }, [
			E('span', {}, [ d ]),
			E('button', {
				'class': 'wg-ad-domremove',
				'title': _('Remove from list'),
				'click': ui.createHandlerFn(null, function() { domainsRemoveDomain(l.sid, idx); })
			}, [ '✕' ])
		]));
	});

	var err = state.domains.errors[l.sid];
	if (err != null)
		panel.appendChild(E('div', { 'class': 'wg-ad-error' }, [ err ]));
	var input = E('input', {
		'type': 'text',
		'placeholder': _('domain.example'),
		'input': function(ev) { state.domains.inputs[l.sid] = ev.target.value; }
	});
	input.value = state.domains.inputs[l.sid] || '';
	panel.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [
		input,
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() { domainsAddDomain(l.sid); })
		}, [ _('Add domain') ])
	]));

	if (!l.legacy) {
		var armed = (state.domains.deleteArm == l.sid);
		panel.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
			E('button', {
				'class': 'btn cbi-button' + (armed ? ' cbi-button-negative' : ''),
				'click': ui.createHandlerFn(null, function() { domainsDeleteList(l.sid); })
			}, [ armed ? _('Confirm delete') : _('Delete list') ])
		]));
	}
	return panel;
}

function buildDomainsView() {
	var m = domainsModel();
	var frag = E([]);

	/* mode card */
	var modeCard = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Desync mode') ])
	]);
	modeCard.appendChild(chipEl((m.enabled)
		? { cls: 'wg-ad-chip-ok', label: _('Whitelist mode'), title: _('Desync is applied only to the listed hosts (SNI suffix match)') }
		: { cls: 'wg-ad-chip-muted', label: _('Blanket mode'), title: _('Desync for every queued target') }));
	if (m.enabledStaged)
		modeCard.appendChild(chipEl({ cls: 'wg-ad-chip-warn',
			label: _('Mode change staged - requires engine restart'),
			title: _('SIGHUP re-reads list files only; adding or dropping the --hostlist binding needs a restart') }));
	modeCard.appendChild(kvRow(_('Effective hostlist'), [
		'%d'.format(m.mergedCount), ' ', _('unique domain(s)')
	]));
	if (m.enabled && m.mergedCount == 0)
		modeCard.appendChild(E('div', { 'class': 'wg-ad-error' }, [
			_('Whitelist mode with no domains fails at render time - add domains or switch back to blanket mode.')
		]));
	modeCard.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button' + (!m.enabled ? ' wg-ad-modebtn-active' : ''),
			'click': ui.createHandlerFn(null, function() { domainsSetMode(false); })
		}, [ _('Blanket') ]),
		E('button', {
			'class': 'btn cbi-button' + (m.enabled ? ' wg-ad-modebtn-active' : ''),
			'click': ui.createHandlerFn(null, function() { domainsSetMode(true); })
		}, [ _('Whitelist') ])
	]));
	frag.appendChild(modeCard);

	/* the lists: legacy first (compat display), then the named sections */
	frag.appendChild(domainsListPanel(m, m.legacy));
	m.lists.forEach(function(l) {
		frag.appendChild(domainsListPanel(m, l));
	});

	/* new list */
	var newCard = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('New domain list') ])
	]);
	if (state.domains.errors['__new'] != null)
		newCard.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.domains.errors['__new'] ]));
	var nameInput = E('input', {
		'type': 'text',
		'placeholder': _('List name (e.g. Video domains)'),
		'input': function(ev) { state.domains.newName = ev.target.value; }
	});
	nameInput.value = state.domains.newName || '';
	newCard.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [
		nameInput,
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, domainsCreateList)
		}, [ _('Create list') ])
	]));
	frag.appendChild(newCard);

	/* apply block: the shared pipeline + the honest application badges */
	var applyCard = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Apply') ])
	]);
	if (state.domains.dirty) {
		if (m.enabledStaged)
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-warn', label: _('Requires engine restart') }));
		else
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-ok',
				label: _('Applies via reload - live connections stay up'),
				title: _('SIGHUP re-reads the hostlist files without dropping the queue or connections') }));
	}
	else {
		applyCard.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('No unsaved edits.') ]));
	}
	applyCard.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, domainsApply),
			'disabled': (!state.domains.dirty || state.applyBusy) ? '' : null
		}, [ _('Apply changes') ]),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(null, domainsDiscardEdits),
			'disabled': (!state.domains.dirty) ? '' : null
		}, [ _('Discard edits') ])
	]));
	frag.appendChild(applyCard);

	return frag;
}

/* the tab body renders once per switch (and after applies) - NOT per poll
 * tick: a rebuild would blow away in-progress edits. The LuCI uci client is
 * read through a lazy load; a failure renders the honest warn card. */
function renderDomains() {
	var node = state.bodyNode;
	if (!node)
		return;
	node.setAttribute('data-unavail', 'false');
	node.innerHTML = '';
	node.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading configuration…') ]));
	uci.load('wanguard-antidpi').then(function() {
		if (state.activeTab != 'domains' || !state.bodyNode)
			return;
		if (state.domains.origEnabled == null)
			state.domains.origEnabled = (uci.get('wanguard-antidpi', 'whitelist', 'enabled') == '1');
		state.domains.loaded = true;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(buildDomainsView());
	}).catch(function(e) {
		if (state.activeTab != 'domains' || !state.bodyNode)
			return;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The configuration could not be read (%s).').format((e && e.message) || 'error') ])
		]));
	});
}

/* ---------- tunnel protection tab (#83) ---------- */

/* strict 'a.b.c.d' or 'a.b.c.d/nn' - the exact mirror of the CLI's
 * valid_addr_entry (ucode): four decimal octets 0-255, no leading zeros
 * (keeps the nft render canonical), optional /0-32 mask. Pins land inside a
 * generated nft file and in the engine's --ipset-exclude-ip CSV, so
 * anything unusual must be rejected, not escaped. Invalid input NEVER
 * reaches the staged config (the #61 render contract stays unreachable
 * from the UI). */
function validAddrEntry(e) {
	if (typeof e != 'string' || e.length == 0)
		return false;
	var host = e;
	var sl = e.indexOf('/');
	if (sl >= 0) {
		var mask = e.slice(sl + 1);
		if (!/^[0-9]+$/.test(mask) || parseInt(mask, 10) > 32)
			return false;
		host = e.slice(0, sl);
	}
	var parts = host.split('.');
	if (parts.length != 4)
		return false;
	for (var i = 0; i < 4; i++) {
		var p = parts[i];
		if (!/^[0-9]+$/.test(p) || p.length > 3 || parseInt(p, 10) > 255)
			return false;
		if (p.length > 1 && p.charAt(0) == '0')
			return false;
	}
	return true;
}

function tunnelList(opt) {
	var v = uci.get('wanguard-antidpi', 'tunnel', opt);
	return (Array.isArray(v) ? v : []).slice();
}

/* the tab's view model: the staged UCI editor values (client-side) plus the
 * committed state document (#76 status) for the resolved-entries table */
function tunnelModel() {
	var t = (state.status != null) ? state.status.tunnel : null;
	var pins = tunnelList('proxy_servers');
	return {
		status: t,
		sectionExists: (uci.get('wanguard-antidpi', 'tunnel') != null),
		pins: pins,
		hosts: tunnelList('tunnel_hosts'),
		interval: uci.get('wanguard-antidpi', 'tunnel', 'update_interval'),
		expire: uci.get('wanguard-antidpi', 'tunnel', 'expire_hours'),
		pinsChanged: (state.tunnel.origPins != null &&
			pins.join(',') != state.tunnel.origPins.join(','))
	};
}

/* the tunnel section is soft (missing = no protection configured); stage a
 * named create before mutating options on it (the #82 rule: uci.set silently
 * no-ops on a section that is neither committed nor client-created) */
function tunnelEnsureSection() {
	if (!uci.get('wanguard-antidpi', 'tunnel'))
		uci.add('wanguard-antidpi', 'tunnel', 'tunnel');
}

function tunnelMarkDirty() {
	state.tunnel.dirty = true;
}

function tunnelAddPin() {
	var v = (state.tunnel.inputs.pin || '').trim();
	var err = null;
	if (v.length == 0)
		err = _('Enter an address or CIDR.');
	else if (!validAddrEntry(v))
		err = _('Not a valid IPv4 address or CIDR (four octets 0-255, no leading zeros, mask /0-32).');
	else if (tunnelList('proxy_servers').indexOf(v) >= 0)
		err = _('"%s" is already pinned.'.format(v));
	if (err != null) {
		state.tunnel.errors.pin = err;
		renderTunnel();
		return;
	}
	delete state.tunnel.errors.pin;
	tunnelEnsureSection();
	var next = tunnelList('proxy_servers');
	next.push(v);
	uci.set('wanguard-antidpi', 'tunnel', 'proxy_servers', next);
	state.tunnel.inputs.pin = '';
	tunnelMarkDirty();
	renderTunnel();
}

function tunnelRemovePin(idx) {
	var next = tunnelList('proxy_servers');
	if (idx < 0 || idx >= next.length)
		return;
	next.splice(idx, 1);
	tunnelEnsureSection();
	uci.set('wanguard-antidpi', 'tunnel', 'proxy_servers', next);
	tunnelMarkDirty();
	renderTunnel();
}

function tunnelAddHost() {
	var v = (state.tunnel.inputs.host || '').trim();
	var err = null;
	if (v.length == 0)
		err = _('Enter a hostname.');
	else if (!domainIsValid(v))
		err = _('Not a valid DNS hostname (labels of letters/digits/hyphens, at least two labels).');
	else if (tunnelList('tunnel_hosts').indexOf(v) >= 0)
		err = _('"%s" is already configured.'.format(v));
	if (err != null) {
		state.tunnel.errors.host = err;
		renderTunnel();
		return;
	}
	delete state.tunnel.errors.host;
	tunnelEnsureSection();
	var next = tunnelList('tunnel_hosts');
	next.push(v);
	uci.set('wanguard-antidpi', 'tunnel', 'tunnel_hosts', next);
	state.tunnel.inputs.host = '';
	tunnelMarkDirty();
	renderTunnel();
}

function tunnelRemoveHost(idx) {
	var next = tunnelList('tunnel_hosts');
	if (idx < 0 || idx >= next.length)
		return;
	next.splice(idx, 1);
	tunnelEnsureSection();
	uci.set('wanguard-antidpi', 'tunnel', 'tunnel_hosts', next);
	tunnelMarkDirty();
	renderTunnel();
}

/* numeric options with published defaults: update_interval >= 1 h (the cron
 * cadence), expire_hours >= 0 (0 = resolved entries never expire) */
function tunnelSetNum(opt, min) {
	var v = (state.tunnel.inputs[opt] || '').trim();
	var err = null;
	if (v.length == 0)
		err = _('Enter a number of hours.');
	else if (!/^[0-9]+$/.test(v) || parseInt(v, 10) < min)
		err = _('Whole hours, at least %d.'.format(min));
	if (err != null) {
		state.tunnel.errors[opt] = err;
		renderTunnel();
		return;
	}
	delete state.tunnel.errors[opt];
	tunnelEnsureSection();
	uci.set('wanguard-antidpi', 'tunnel', opt, v);
	tunnelMarkDirty();
	renderTunnel();
}

/* drop the client-side staged edits (committed truth untouched); the shared
 * pending-bar Discard covers the router-side deltas */
function tunnelDiscardEdits() {
	state.tunnel.dirty = false;
	state.tunnel.origPins = null;
	state.tunnel.errors = {};
	state.tunnel.inputs = {};
	uci.unload('wanguard-antidpi');
	renderTunnel();
}

/* after the shared pipeline committed (or the router deltas were reverted),
 * the editor starts clean from the committed truth */
function tunnelAfterConfigChange() {
	state.tunnel.dirty = false;
	state.tunnel.origPins = null;
	state.tunnel.errors = {};
	state.tunnel.inputs = {};
	if (state.activeTab == 'tunnel')
		renderTunnel();
}

function tunnelApply() {
	reviewApply();
}

function tunnelStatusCard(m) {
	var t = m.status;
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Protection status') ])
	]);
	if (t == null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The tunnel protection surface is unavailable.') ])
		]));
		return card;
	}
	var hosts = (t.hosts && t.hosts.length) ? t.hosts.join(', ') : null;
	var entries = (t.entries || []).length;
	var cronOk = (t.cron != null && t.cron.ok);
	var badge;
	if (!hosts && !entries)
		badge = chipEl({ cls: 'wg-ad-chip-muted', label: _('Not configured') });
	else if (entries > 0 && cronOk)
		badge = chipEl({ cls: 'wg-ad-chip-ok', label: _('Protected'),
			title: (hosts && hosts.length > 60) ? hosts : '' });
	else
		badge = chipEl({ cls: 'wg-ad-chip-warn', label: _('Unprotected') });
	card.appendChild(badge);
	card.appendChild(kvRow(_('Hostname(s)'), [ hosts || _('—') ]));
	card.appendChild(kvRow(_('Mode'), [ _('Static pins + auto-resolved addresses') ]));
	var refreshTxt = (t.update_interval_h != null)
		? _('every %d h').format(t.update_interval_h) : _('unknown');
	refreshTxt += (cronOk) ? ' · ' + _('cron active') : ' · ' + _('cron MISSING');
	card.appendChild(kvRow(_('Refresh'), [ refreshTxt ]));
	card.appendChild(kvRow(_('Expire entries after'), [
		(t.expire_hours != null)
			? ((t.expire_hours > 0) ? _('%d h').format(t.expire_hours) : _('never'))
			: _('unknown')
	]));
	return card;
}

function tunnelSetCard(m) {
	var t = m.status;
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Exclusion set') ]),
		E('p', { 'class': 'wg-ad-hint' }, [
			_('Committed state: pins and resolved addresses the engine and the nft table actually use. Staged edits appear here after Apply.')
		])
	]);
	if (t == null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The tunnel protection surface is unavailable.') ])
		]));
		return card;
	}
	card.appendChild(chipEl({ cls: 'wg-ad-chip-muted',
		label: '%d exclusion(s)'.format((t.entries || []).length) }));
	card.appendChild(buildExclusionsPanel(t));
	return card;
}

function tunnelEditorCard(m) {
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Configuration') ])
	]);

	/* static pins */
	card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('Static pins stay in the exclusion set permanently; resolved addresses are managed by the updater.')
	]));
	if (m.pins.length == 0)
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('No pins configured.') ]));
	m.pins.forEach(function(p, idx) {
		card.appendChild(E('div', { 'class': 'wg-ad-domrow' }, [
			E('span', {}, [ p ]),
			E('button', {
				'class': 'wg-ad-domremove',
				'title': _('Remove pin'),
				'click': ui.createHandlerFn(null, function() { tunnelRemovePin(idx); })
			}, [ '✕' ])
		]));
	});
	if (state.tunnel.errors.pin != null)
		card.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.tunnel.errors.pin ]));
	var pinInput = E('input', {
		'type': 'text',
		'placeholder': _('203.0.113.0/24'),
		'input': function(ev) { state.tunnel.inputs.pin = ev.target.value; }
	});
	pinInput.value = state.tunnel.inputs.pin || '';
	card.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [
		pinInput,
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, tunnelAddPin)
		}, [ _('Add pin') ])
	]));

	/* tunnel hosts */
	var hostsTitle = E('h3', {}, [ _('Updater hosts') ]);
	card.appendChild(hostsTitle);
	card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('The updater resolves these hostnames on a schedule and keeps every observed address in the exclusion set.')
	]));
	if (m.hosts.length == 0)
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('No hosts configured.') ]));
	m.hosts.forEach(function(h, idx) {
		card.appendChild(E('div', { 'class': 'wg-ad-domrow' }, [
			E('span', {}, [ h ]),
			E('button', {
				'class': 'wg-ad-domremove',
				'title': _('Remove host'),
				'click': ui.createHandlerFn(null, function() { tunnelRemoveHost(idx); })
			}, [ '✕' ])
		]));
	});
	if (state.tunnel.errors.host != null)
		card.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.tunnel.errors.host ]));
	var hostInput = E('input', {
		'type': 'text',
		'placeholder': _('cdn.example.net'),
		'input': function(ev) { state.tunnel.inputs.host = ev.target.value; }
	});
	hostInput.value = state.tunnel.inputs.host || '';
	card.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [
		hostInput,
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, tunnelAddHost)
		}, [ _('Add host') ])
	]));

	/* the two numeric options */
	var numErr = function(key) {
		return (state.tunnel.errors[key] != null)
			? E('div', { 'class': 'wg-ad-error' }, [ state.tunnel.errors[key] ]) : null;
	};
	var intervalInput = E('input', {
		'type': 'text',
		'placeholder': _('6'),
		'input': function(ev) { state.tunnel.inputs.update_interval = ev.target.value; }
	});
	intervalInput.value = state.tunnel.inputs.update_interval || '';
	var expireInput = E('input', {
		'type': 'text',
		'placeholder': _('24'),
		'input': function(ev) { state.tunnel.inputs.expire_hours = ev.target.value; }
	});
	expireInput.value = state.tunnel.inputs.expire_hours || '';
	card.appendChild(E('table', { 'class': 'wg-ad-table' }, [
		E('tr', {}, [
			E('td', {}, [ _('Refresh interval (h)'), intervalInput,
				numErr('update_interval') ]),
			E('td', {}, [ E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(null, function() { tunnelSetNum('update_interval', 1); })
			}, [ _('Set') ]) ]),
			E('td', {}, [ _('Expire entries after (h, 0 = never)'), expireInput,
				numErr('expire_hours') ]),
			E('td', {}, [ E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(null, function() { tunnelSetNum('expire_hours', 0); })
			}, [ _('Set') ]) ])
		])
	]));
	return card;
}

function buildTunnelView() {
	var m = tunnelModel();
	var frag = E([]);

	frag.appendChild(tunnelStatusCard(m));
	frag.appendChild(tunnelSetCard(m));
	frag.appendChild(tunnelEditorCard(m));

	/* apply block: the shared pipeline + the honest application badges */
	var applyCard = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Apply') ])
	]);
	if (state.tunnel.dirty) {
		if (m.pinsChanged)
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-warn',
				label: _('Exclusion set changed - apply re-renders the table and restarts the engine'),
				title: _('The pin set rides in the engine argv (--ipset-exclude-ip): any pin change needs a restart to take effect') }));
		else
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-ok',
				label: _('Applies via tunnel-update + nft reload - the engine restarts only if the set changes'),
				title: _('The updater refreshes the resolved addresses first; a hostname-only edit usually re-resolves into the same table') }));
	}
	else {
		applyCard.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('No unsaved edits.') ]));
	}
	applyCard.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, tunnelApply),
			'disabled': (!state.tunnel.dirty || state.applyBusy) ? '' : null
		}, [ _('Apply changes') ]),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(null, tunnelDiscardEdits),
			'disabled': (!state.tunnel.dirty) ? '' : null
		}, [ _('Discard edits') ])
	]));
	frag.appendChild(applyCard);
	return frag;
}

/* the tab body renders once per switch (and after applies) - NOT per poll
 * tick: a rebuild would blow away in-progress edits (the #82 rule). The
 * LuCI uci client is read through a lazy load; a failure renders the honest
 * warn card. */
function renderTunnel() {
	var node = state.bodyNode;
	if (!node)
		return;
	node.setAttribute('data-unavail', 'false');
	node.innerHTML = '';
	node.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading configuration…') ]));
	uci.load('wanguard-antidpi').then(function() {
		if (state.activeTab != 'tunnel' || !state.bodyNode)
			return;
		if (state.tunnel.origPins == null)
			state.tunnel.origPins = tunnelList('proxy_servers');
		state.tunnel.loaded = true;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(buildTunnelView());
	}).catch(function(e) {
		if (state.activeTab != 'tunnel' || !state.bodyNode)
			return;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The configuration could not be read (%s).').format((e && e.message) || 'error') ])
		]));
	});
}

/* ---------- profiles tab (#84/#85) ---------- */

/* named strategy profiles (config profile): one section = one nfqws2
 * profile block on the render, in section file order; the section id is
 * the stable ref target (policies #86 will reference it), the label is
 * editable. The editor stages client-side through the uci client (the
 * #82/#83 lifecycle) and applies through the shared save -> apply(5) ->
 * CLI apply pipeline; strategy/enabled edits drift the engine argv, so
 * the honest badge is a restart. The #85 concept adds the list view
 * (color dot, protocol badges, policy counter) and a New/Edit drawer
 * with generic presets. */

/* color palette (design contract: the dot, same keys as the wanguard
 * group colors; `option color` is pure UI identity metadata) */
var PROFILE_COLORS = {
	blue: '#2563EB',
	green: '#22C55E',
	purple: '#7C3AED',
	orange: '#EA580C',
	gray: '#6B7280'
};

/* generic strategy presets (#85): STARTING POINTS for the words editor,
 * not tuned strategies - each word is engine-valid and the combination
 * follows the README tuning section (the canonical --payload types and
 * a bare desync function). No provider-specific tuning lives here (the
 * private-strategy policy). tests/test-profiles.sh starts the engine on
 * BOTH presets byte-exactly, and tests/test-luci.sh pins the same words
 * in this file - the three stay in sync by construction. */
var PROFILE_PRESETS = [
	{
		id: 'tls-split',
		label: _('TLS over TCP (generic)'),
		proto: 'tcp',
		words: [ '--filter-tcp=443', '--payload=tls_client_hello',
			'--lua-desync=multisplit:pos=midsld' ]
	},
	{
		id: 'quic-fake',
		label: _('QUIC over UDP (generic)'),
		proto: 'quic',
		words: [ '--filter-udp=443', '--payload=quic_initial',
			'--lua-desync=fake:repeats=2' ]
	}
];

/* how many policy sections reference this profile (the #86 ref contract:
 * `option profile <sid>`; zero while no policies exist, but the guard
 * must be live from day one so a delete can never orphan a policy) */
function profilesPolicyUse(sid) {
	var n = 0;
	(uci.sections('wanguard-antidpi', 'policy') || []).forEach(function(s) {
		if (s.profile == sid)
			n++;
	});
	return n;
}

/* protocol badges are derived from the WORDS (the engine truth: the
 * --filter flags scope the desync), not from the proto metadata option
 * (design: the engine renders by words, proto is advisory) */
function profilesProtoOfWords(words) {
	var out = [];
	words.forEach(function(w) {
		if (w.indexOf('--filter-tcp=') == 0 && out.indexOf('TCP') < 0)
			out.push('TCP');
		if (w.indexOf('--filter-udp=') == 0 && out.indexOf('QUIC') < 0)
			out.push('QUIC');
	});
	return out;
}

function profilesModel() {
	var legacy = (function(v) { return (Array.isArray(v) ? v : []).slice(); })(
		uci.get('wanguard-antidpi', 'engine', 'nfqws2_opt'));
	var sections = (uci.sections('wanguard-antidpi', 'profile') || []).map(function(s) {
		return {
			sid: s['.name'],
			name: (typeof s.name == 'string' && s.name.length) ? s.name : s['.name'],
			proto: (function(v) {
				var out = [];
				(typeof v == 'string' ? v.split(' ') : []).forEach(function(t) {
					if (t.length) out.push(t);
				});
				return out;
			})(s.proto),
			words: (Array.isArray(s.strategy_words) ? s.strategy_words : []).slice(),
			enabled: (s.enabled != null) ? (s.enabled == '1') : true,
			color: (typeof s.color == 'string' && PROFILE_COLORS[s.color]) ? s.color : 'gray',
			policies: profilesPolicyUse(s['.name'])
		};
	});
	return {
		sections: sections,
		legacyWords: legacy,
		/* profiles replace the legacy opt while any section exists (#84):
		 * the UI must show that loudly, the CLI warns on every render */
		legacyIgnored: (sections.length > 0 && legacy.length > 0)
	};
}

/* the derived strategy key: enabled profiles with words, in section order,
 * joined with --new separators - the exact mirror of the CLI's
 * profile_strategy_words (an empty-word profile is skipped there too) */
function profilesStrategyKey(m) {
	var words = [];
	var any = false;
	m.sections.forEach(function(p) {
		if (!p.enabled || !p.words.length)
			return;
		if (any)
			words.push('--new');
		any = true;
		p.words.forEach(function(w) { words.push(w); });
	});
	return words.join('\u0001');
}

/* 'prof_balanced'-style stable section id derived from the label (same
 * contract as the domainlist slug: refs go by section name) */
function profilesSlug(label) {
	var base = ('prof_' + label.toLowerCase().replace(/[^a-z0-9]+/g, '_')
		.replace(/^_+|_+$/g, '')).replace(/^prof_prof/, 'prof').slice(0, 48);
	var sid = base, n = 2;
	while (uci.get('wanguard-antidpi', sid) != null) {
		sid = base + '_' + n;
		n++;
	}
	return sid;
}

function profilesMarkDirty() {
	state.profiles.dirty = true;
}

/* parse the words textarea: one strategy word per line; a word rides in
 * the engine argv, so whitespace inside it can never be staged (the CLI
 * dies loudly on it - the UI keeps that state unreachable) */
function profilesParseWords(text) {
	var words = [];
	var bad = [];
	(text || '').split(/\r?\n/).forEach(function(line) {
		var w = line.trim();
		if (!w.length)
			return;
		if (/\s/.test(w))
			bad.push(w);
		else
			words.push(w);
	});
	return { words: words, bad: bad };
}

/* proto tokens ride in a single space-separated option (design contract;
 * policy matching #86 reads them) */
function profilesToggleProto(sid, token, on) {
	var cur = uci.get('wanguard-antidpi', sid, 'proto') || '';
	var toks = [];
	cur.split(' ').forEach(function(t) {
		if (t.length && toks.indexOf(t) < 0 && t != token)
			toks.push(t);
	});
	if (on)
		toks.push(token);
	toks.sort();
	uci.set('wanguard-antidpi', sid, 'proto', toks.join(' '));
	profilesMarkDirty();
	renderProfiles();
}

function profilesSetName(sid, text) {
	uci.set('wanguard-antidpi', sid, 'name', text);
	profilesMarkDirty();
	/* no re-render: the input keeps the focus while typing */
}

function profilesSetWords(sid) {
	var text = state.profiles.inputs[sid + '.words'] || '';
	var parsed = profilesParseWords(text);
	if (parsed.bad.length) {
		state.profiles.errors[sid] = _('Each strategy word must be a single argv word (no whitespace): %s').format(parsed.bad.join(', '));
		renderProfiles();
		return;
	}
	delete state.profiles.errors[sid];
	uci.set('wanguard-antidpi', sid, 'strategy_words', parsed.words);
	profilesMarkDirty();
	renderProfiles();
}

function profilesSetEnabled(sid, on) {
	uci.set('wanguard-antidpi', sid, 'enabled', on ? '1' : '0');
	profilesMarkDirty();
	renderProfiles();
}

/* the dot color (UI identity metadata - never enters the engine argv) */
function profilesSetColor(sid, color) {
	uci.set('wanguard-antidpi', sid, 'color', color);
	profilesMarkDirty();
	renderProfiles();
}

/* create a profile from the drawer draft (name required, words must pass
 * the one-word-per-line validation - invalid input is never staged) */
function profilesAddProfile() {
	var d = state.profiles.draft || {};
	var label = (d.name || '').trim();
	if (label.length == 0) {
		state.profiles.errors.editor = _('Enter a profile name.');
		renderProfiles();
		return;
	}
	var parsed = profilesParseWords(d.wordsText);
	if (parsed.bad.length) {
		state.profiles.errors.editor = _('Each strategy word must be a single argv word (no whitespace): %s').format(parsed.bad.join(', '));
		renderProfiles();
		return;
	}
	delete state.profiles.errors.editor;
	var sid = profilesSlug(label);
	uci.add('wanguard-antidpi', 'profile', sid);
	uci.set('wanguard-antidpi', sid, 'name', label);
	uci.set('wanguard-antidpi', sid, 'strategy_words', parsed.words);
	uci.set('wanguard-antidpi', sid, 'enabled', '1');
	if (d.proto && d.proto.length)
		uci.set('wanguard-antidpi', sid, 'proto', d.proto.slice().sort().join(' '));
	if (d.color && PROFILE_COLORS[d.color])
		uci.set('wanguard-antidpi', sid, 'color', d.color);
	state.profiles.editor = null;
	state.profiles.draft = null;
	profilesMarkDirty();
	renderProfiles();
}

function profilesDeleteProfile(sid) {
	/* policy-ref guard (#85): a delete must never orphan a policy - the
	 * user unlinks the policies first (the #86 editor owns that flow) */
	var used = profilesPolicyUse(sid);
	if (used > 0) {
		state.profiles.errors[sid] = _('Referenced by %d policy(s) - unlink them first.').format(used);
		state.profiles.deleteArm = null;
		renderProfiles();
		return;
	}
	if (state.profiles.deleteArm != sid) {
		state.profiles.deleteArm = sid;
		renderProfiles();
		return;
	}
	uci.remove('wanguard-antidpi', sid);
	state.profiles.deleteArm = null;
	if (state.profiles.editor && state.profiles.editor.sid == sid)
		state.profiles.editor = null;
	profilesMarkDirty();
	renderProfiles();
}

/* ---------- profiles drawer (#85) ---------- */

function profilesOpenEditor(sid) {
	state.profiles.deleteArm = null;
	if (sid == 'new')
		state.profiles.draft = { name: '', proto: [], wordsText: '', color: 'blue' };
	else
		delete state.profiles.inputs[sid + '.words'];
	state.profiles.editor = { sid: sid, presetArm: false };
	delete state.profiles.errors.editor;
	renderProfiles();
}

function profilesCloseEditor() {
	state.profiles.editor = null;
	state.profiles.draft = null;
	delete state.profiles.errors.editor;
	renderProfiles();
}

/* apply a preset's words+proto onto the drawer target. In the new-profile
 * draft it just fills the form; on an existing profile it is a two-step
 * action when words are already staged (no silent overwrite). */
function profilesApplyPreset(pid) {
	var preset = null;
	PROFILE_PRESETS.forEach(function(p) {
		if (p.id == pid)
			preset = p;
	});
	if (!preset)
		return;
	var ed = state.profiles.editor;
	if (!ed)
		return;
	if (ed.sid == 'new') {
		state.profiles.draft.wordsText = preset.words.join('\n');
		state.profiles.draft.proto = preset.proto.split(' ').slice();
		renderProfiles();
		return;
	}
	var cur = uci.get('wanguard-antidpi', ed.sid, 'strategy_words');
	var hasWords = (Array.isArray(cur) && cur.length > 0);
	if (hasWords && !ed.presetArm) {
		ed.presetArm = true;
		renderProfiles();
		return;
	}
	uci.set('wanguard-antidpi', ed.sid, 'strategy_words', preset.words.slice());
	uci.set('wanguard-antidpi', ed.sid, 'proto', preset.proto);
	delete state.profiles.inputs[ed.sid + '.words'];
	ed.presetArm = false;
	profilesMarkDirty();
	renderProfiles();
}

/* section order = render order (first match wins semantics); the uci
 * client's move() stages an order delta (the save() pipeline sends it) */
function profilesMove(sid, dir) {
	var sids = profilesModel().sections.map(function(p) { return p.sid; });
	var i = sids.indexOf(sid);
	var j = i + dir;
	if (i < 0 || j < 0 || j >= sids.length)
		return;
	uci.move('wanguard-antidpi', sid, sids[j], dir > 0);
	profilesMarkDirty();
	renderProfiles();
}

/* adopt the legacy engine.nfqws2_opt into a fresh profile (the migration
 * path: profiles replace the legacy words on the next apply); the proto
 * tokens are derived from the words' filter flags */
function profilesAdoptLegacy() {
	var m = profilesModel();
	if (!m.legacyWords.length)
		return;
	var sid = profilesSlug(_('Adopted legacy'));
	uci.add('wanguard-antidpi', 'profile', sid);
	uci.set('wanguard-antidpi', sid, 'name', _('Adopted legacy'));
	uci.set('wanguard-antidpi', sid, 'strategy_words', m.legacyWords.slice());
	var proto = [];
	m.legacyWords.forEach(function(w) {
		if (w.indexOf('--filter-tcp=') == 0 && proto.indexOf('tcp') < 0)
			proto.push('tcp');
		if (w.indexOf('--filter-udp=') == 0 && proto.indexOf('quic') < 0)
			proto.push('quic');
	});
	if (proto.length)
		uci.set('wanguard-antidpi', sid, 'proto', proto.join(' '));
	uci.set('wanguard-antidpi', sid, 'enabled', '1');
	profilesMarkDirty();
	renderProfiles();
}

/* drop the client-side staged edits (committed truth untouched); the
 * shared pending-bar Discard covers the router-side deltas */
function profilesDiscardEdits() {
	state.profiles.dirty = false;
	state.profiles.origStrategy = null;
	state.profiles.deleteArm = null;
	state.profiles.editor = null;
	state.profiles.draft = null;
	state.profiles.errors = {};
	state.profiles.inputs = {};
	uci.unload('wanguard-antidpi');
	renderProfiles();
}

/* after the shared pipeline committed (or the router deltas were reverted),
 * the editor starts clean from the committed truth */
function profilesAfterConfigChange() {
	state.profiles.dirty = false;
	state.profiles.origStrategy = null;
	state.profiles.deleteArm = null;
	state.profiles.editor = null;
	state.profiles.draft = null;
	state.profiles.errors = {};
	state.profiles.inputs = {};
	if (state.activeTab == 'profiles')
		renderProfiles();
}

function profilesApply() {
	reviewApply();
}

/* legacy strategy card: without profiles the legacy words ARE the
 * strategy (active); with profiles they are ignored (#84 render contract)
 * - the card must say which, and offer the adopt migration path */
function profilesLegacyCard(m) {
	if (!m.legacyWords.length)
		return null;
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Legacy strategy (engine.nfqws2_opt)'), ' ',
			chipEl(m.sections.length
				? { cls: 'wg-ad-chip-warn', label: _('ignored while profiles exist'),
					title: _('Strategy profile sections replace the legacy words on the render') }
				: { cls: 'wg-ad-chip-ok', label: _('active') }) ]),
		E('p', { 'class': 'wg-ad-hint' }, [
			_('Pre-profile storage: one UCI list item per strategy word.')
		])
	]);
	var row = E('div', { 'class': 'wg-ad-chips' });
	m.legacyWords.forEach(function(w) {
		row.appendChild(E('span', { 'class': 'wg-ad-chip wg-ad-word' }, [ w ]));
	});
	card.appendChild(row);
	card.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, profilesAdoptLegacy)
		}, [ _('Adopt into a profile') ])
	]));
	return card;
}

/* one list row (the #85 concept): color dot, name, protocol badges
 * derived from the words, word-count hint, policy counter, and the
 * row actions (order / edit / guarded delete) */
function profilesListRow(m, p, idx) {
	var armed = (state.profiles.deleteArm == p.sid);
	var protoBadges = profilesProtoOfWords(p.words);
	var row = E('div', { 'class': 'wg-ad-profrow' + (p.enabled ? '' : ' wg-ad-profrow-off') });
	row.appendChild(E('span', {
		'class': 'wg-ad-dot wg-ad-dot-' + p.color,
		'title': _('Color: %s').format(p.color)
	}));
	row.appendChild(E('strong', {}, [ p.name ]));
	if (!p.enabled)
		row.appendChild(chipEl({ cls: 'wg-ad-chip-muted', label: _('disabled') }));
	protoBadges.forEach(function(b) {
		row.appendChild(chipEl({ cls: 'wg-ad-chip-muted', label: b }));
	});
	if (!p.enabled)
		row.appendChild(E('span', { 'class': 'wg-ad-hint' }, [ _('skipped on the render') ]));
	else if (p.words.length == 0)
		row.appendChild(E('span', { 'class': 'wg-ad-hint' }, [ _('no words - contributes nothing to the strategy') ]));
	if (p.policies > 0)
		row.appendChild(chipEl({ cls: 'wg-ad-chip-muted', label: '%d policy(s)'.format(p.policies) }));
	else
		row.appendChild(E('span', { 'class': 'wg-ad-hint' }, [ _('No policies') ]));
	var actions = E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'title': _('Move up'),
			'disabled': (idx == 0) ? '' : null,
			'click': ui.createHandlerFn(null, function() { profilesMove(p.sid, -1); })
		}, [ '↑' ]),
		E('button', {
			'class': 'btn cbi-button',
			'title': _('Move down'),
			'disabled': (idx == m.sections.length - 1) ? '' : null,
			'click': ui.createHandlerFn(null, function() { profilesMove(p.sid, 1); })
		}, [ '↓' ]),
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() { profilesOpenEditor(p.sid); })
		}, [ _('Edit') ]),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'title': (p.policies > 0) ? _('Unlink the policies first.') : null,
			'disabled': (p.policies > 0) ? '' : null,
			'click': ui.createHandlerFn(null, function() { profilesDeleteProfile(p.sid); })
		}, [ armed ? _('Confirm delete?') : _('Delete') ])
	]);
	row.appendChild(actions);
	var wrap = E('div', {}, [ row ]);
	if (state.profiles.errors[p.sid] != null) {
		wrap.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.profiles.errors[p.sid] ]));
		delete state.profiles.errors[p.sid];
	}
	return wrap;
}

/* color picker row (shared by the drawer modes): the palette keys render
 * as dots; the active key gets the active button style */
function profilesColorRow(current, onPick) {
	var row = E('div', { 'class': 'wg-ad-chips' }, [
		E('span', { 'class': 'wg-ad-hint' }, [ _('Color dot:') ])
	]);
	Object.keys(PROFILE_COLORS).forEach(function(k) {
		row.appendChild(E('button', {
			'class': 'btn cbi-button' + ((current == k) ? ' wg-ad-modebtn-active' : ''),
			'click': ui.createHandlerFn(null, function() { onPick(k); })
		}, [ E('span', { 'class': 'wg-ad-dot wg-ad-dot-' + k }), ' ' + k ]));
	});
	return row;
}

/* proto toggle row (shared): the tokens are UI metadata for the future
 * policy matching (#86); the badges on the list derive from the words */
function profilesProtoRowOf(current, onToggle) {
	var row = E('div', { 'class': 'wg-ad-chips' }, [
		E('span', { 'class': 'wg-ad-hint' }, [ _('Protocols (UI metadata):') ])
	]);
	[ 'tcp', 'udp', 'quic' ].forEach(function(tok) {
		row.appendChild(E('button', {
			'class': 'btn cbi-button' + ((current.indexOf(tok) >= 0) ? ' wg-ad-modebtn-active' : ''),
			'click': ui.createHandlerFn(null, function() { onToggle(tok); })
		}, [ tok.toUpperCase() ]));
	});
	return row;
}

function profilesPresetRow(armed) {
	var row = E('div', { 'class': 'wg-ad-presetrow' }, [
		E('span', { 'class': 'wg-ad-hint' }, [ _('Generic presets (starting points - tune in the words editor):') ])
	]);
	PROFILE_PRESETS.forEach(function(p) {
		row.appendChild(E('button', {
			'class': 'btn cbi-button',
			'title': p.words.join('\n'),
			'click': ui.createHandlerFn(null, function() { profilesApplyPreset(p.id); })
		}, [ (armed && ed().sid != 'new')
			? _('Confirm: replace words with "%s"?').format(p.label)
			: p.label ]));
	});
	return row;
}

/* the drawer target: either the new-profile draft or an existing section */
function ed() {
	return state.profiles.editor || {};
}

function profilesEditorPanel(m) {
	var edv = state.profiles.editor;
	var isNew = (edv.sid == 'new');
	var p = null;
	if (!isNew) {
		m.sections.forEach(function(s) {
			if (s.sid == edv.sid)
				p = s;
		});
		if (!p) /* the section vanished (deleted from another view) */
			return null;
	}

	var panel = E('div', { 'class': 'wg-ad-editor' }, [
		E('h3', {}, [ isNew ? _('New profile') : _('Edit profile: %s').format(p.name) ])
	]);

	/* name */
	var nameVal, onName;
	if (isNew) {
		nameVal = function() { return state.profiles.draft.name; };
		onName = function(v) { state.profiles.draft.name = v; };
	}
	else {
		nameVal = function() { return state.profiles.inputs[p.sid + '.name'] || p.name; };
		onName = function(v) {
			state.profiles.inputs[p.sid + '.name'] = v;
			profilesSetName(p.sid, v);
		};
	}
	var nameInput = E('input', {
		'type': 'text',
		'placeholder': _('Profile name'),
		'input': function(ev) { onName(ev.target.value); }
	});
	nameInput.value = nameVal();
	panel.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [ nameInput ]));

	/* proto + presets */
	var protoVal = isNew
		? function() { return state.profiles.draft.proto; }
		: function() { return p.proto; };
	var protoToggle = isNew
		? function(tok) {
			var a = state.profiles.draft.proto;
			var i = a.indexOf(tok);
			if (i >= 0) a.splice(i, 1); else a.push(tok);
			renderProfiles();
		}
		: function(tok) { profilesToggleProto(p.sid, tok, p.proto.indexOf(tok) < 0); };
	panel.appendChild(profilesProtoRowOf(protoVal(), protoToggle));
	panel.appendChild(profilesPresetRow(edv.presetArm));

	/* words */
	var wordsVal = isNew
		? function() { return state.profiles.draft.wordsText; }
		: function() {
			var t = state.profiles.inputs[p.sid + '.words'];
			return (t == null) ? p.words.join('\n') : t;
		};
	var wordsInput = E('textarea', {
		'class': 'wg-ad-words',
		'spellcheck': 'false',
		'placeholder': _('--filter-tcp=443\n--payload=tls_client_hello\n--lua-desync=…'),
		'input': function(ev) {
			if (isNew)
				state.profiles.draft.wordsText = ev.target.value;
			else
				state.profiles.inputs[p.sid + '.words'] = ev.target.value;
		},
		'change': function(ev) {
			if (isNew) {
				state.profiles.draft.wordsText = ev.target.value;
				renderProfiles();
			}
			else {
				state.profiles.inputs[p.sid + '.words'] = ev.target.value;
				profilesSetWords(p.sid);
			}
		}
	});
	wordsInput.value = wordsVal();
	panel.appendChild(wordsInput);
	panel.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('One strategy word per line (the nfqws2 argv grammar - each line becomes one engine argument).')
	]));

	/* color + enabled */
	var colorVal = isNew ? state.profiles.draft.color : p.color;
	var colorPick = isNew
		? function(k) { state.profiles.draft.color = k; renderProfiles(); }
		: function(k) { profilesSetColor(p.sid, k); };
	panel.appendChild(profilesColorRow(colorVal, colorPick));
	if (!isNew) {
		var enabledCheck = E('input', { 'type': 'checkbox' });
		enabledCheck.checked = p.enabled;
		enabledCheck.addEventListener('change', function(ev) {
			profilesSetEnabled(p.sid, ev.target.checked);
		});
		panel.appendChild(E('div', { 'class': 'wg-ad-chips' }, [
			E('label', { 'class': 'wg-ad-hint' }, [ enabledCheck, ' ' + _('enabled') ])
		]));
	}

	if (state.profiles.errors.editor != null)
		panel.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.profiles.errors.editor ]));

	/* footer actions */
	var footer = [];
	if (isNew) {
		footer.push(E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, profilesAddProfile)
		}, [ _('Create profile') ]));
	}
	footer.push(E('button', {
		'class': 'btn cbi-button',
		'click': ui.createHandlerFn(null, profilesCloseEditor)
	}, [ isNew ? _('Cancel') : _('Close') ]));
	panel.appendChild(E('div', { 'class': 'wg-ad-actions' }, footer));
	return panel;
}

function buildProfilesView() {
	var m = profilesModel();
	var frag = E([]);

	var legacyCard = profilesLegacyCard(m);
	if (legacyCard != null)
		frag.appendChild(legacyCard);

	/* the list panel (#85 concept): rows + New profile */
	var list = E('div', { 'class': 'wg-ad-panel' });
	var head = E('div', { 'class': 'wg-ad-head' }, [
		E('h3', {}, [ _('Strategy profiles') ]),
		E('div', { 'class': 'wg-ad-actions' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(null, function() { profilesOpenEditor('new'); })
			}, [ _('New profile') ])
		])
	]);
	list.appendChild(head);
	if (m.sections.length == 0)
		list.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
			_('No profiles configured - the legacy strategy words drive the engine.')
		]));
	m.sections.forEach(function(p, idx) {
		list.appendChild(profilesListRow(m, p, idx));
	});
	frag.appendChild(list);

	/* the drawer (New/Edit) */
	var panel = (state.profiles.editor != null) ? profilesEditorPanel(m) : null;
	if (panel != null)
		frag.appendChild(panel);

	/* apply block: the honest badges (strategy/enabled/order edits drift the
	 * engine argv -> restart; name/proto are metadata -> no restart) */
	var applyCard = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Apply') ])
	]);
	if (state.profiles.dirty) {
		var strategyChanged = (profilesStrategyKey(profilesModel()) != state.profiles.origStrategy);
		if (strategyChanged)
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-warn',
				label: _('Strategy changed - apply restarts the engine'),
				title: _('The strategy words ride in the engine argv: any word/enabled/order change needs a restart to take effect') }));
		else
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-ok',
				label: _('Metadata only - the engine stays untouched'),
				title: _('Name and protocol edits do not appear in the engine argv') }));
	}
	else {
		applyCard.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('No unsaved edits.') ]));
	}
	applyCard.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, profilesApply),
			'disabled': (!state.profiles.dirty || state.applyBusy) ? '' : null
		}, [ _('Apply changes') ]),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(null, profilesDiscardEdits),
			'disabled': (!state.profiles.dirty) ? '' : null
		}, [ _('Discard edits') ])
	]));
	frag.appendChild(applyCard);
	return frag;
}

/* the tab body renders once per switch (and after applies) - NOT per poll
 * tick: a rebuild would blow away in-progress edits (the #82 rule). */
function renderProfiles() {
	var node = state.bodyNode;
	if (!node)
		return;
	node.setAttribute('data-unavail', 'false');
	node.innerHTML = '';
	node.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading configuration…') ]));
	uci.load('wanguard-antidpi').then(function() {
		if (state.activeTab != 'profiles' || !state.bodyNode)
			return;
		if (state.profiles.origStrategy == null)
			state.profiles.origStrategy = profilesStrategyKey(profilesModel());
		state.profiles.loaded = true;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(buildProfilesView());
	}).catch(function(e) {
		if (state.activeTab != 'profiles' || !state.bodyNode)
			return;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The configuration could not be read (%s).').format((e && e.message) || 'error') ])
		]));
	});
}

/* ---------- policies tab (#87) ---------- */

/* ordered match -> action policies (config policy, the #86 render
 * contract): the sections render as the FIRST engine profile blocks,
 * ordered by `option priority` ascending (ties keep the section file
 * order), the global strategy catch-all last; first match wins. The
 * editor stages client-side through the uci client (the #82/#83/#85
 * lifecycle) and applies through the shared save -> apply(5) -> CLI apply
 * pipeline. Priority/order/action/protocol/ref/enabled edits drift the
 * engine argv -> the honest badge is a restart; name and device_group are
 * metadata (never in the argv). `device_group` is staged-future (#86):
 * stored and shown, ignored by the render - no client identity survives
 * in the queue (the foot-note says so). */

var POLICY_ACTIONS = [ 'strategy', 'bypass', 'none' ];
var POLICY_PROTOS = [ 'tcp', 'udp', 'quic' ];

function policiesMarkDirty() {
	state.policies.dirty = true;
}

/* the tab's view model: the staged UCI sections (client-side staging
 * included - the same staged-first contract as every editor) plus the
 * reference targets for the drawer (domain lists / profiles) and the
 * committed render count from the status document */
function policiesModel() {
	var lists = (uci.sections('wanguard-antidpi', 'domainlist') || []).map(function(s) {
		return {
			sid: s['.name'],
			label: (typeof s.name == 'string' && s.name.length) ? s.name : s['.name']
		};
	});
	var profiles = (uci.sections('wanguard-antidpi', 'profile') || []).map(function(s) {
		return {
			sid: s['.name'],
			name: (typeof s.name == 'string' && s.name.length) ? s.name : s['.name']
		};
	});
	var sections = (uci.sections('wanguard-antidpi', 'policy') || []).map(function(s) {
		return {
			sid: s['.name'],
			name: (typeof s.name == 'string' && s.name.length) ? s.name : s['.name'],
			priority: (typeof s.priority == 'string' && /^[0-9]+$/.test(s.priority))
				? s.priority : '100',
			domainlist: (typeof s.domainlist == 'string') ? s.domainlist : '',
			proto: (function(v) {
				var out = [];
				(typeof v == 'string' ? v.split(' ') : []).forEach(function(t) {
					if (t.length && POLICY_PROTOS.indexOf(t) >= 0 && out.indexOf(t) < 0)
						out.push(t);
				});
				return out;
			})(s.proto),
			device_group: (typeof s.device_group == 'string') ? s.device_group : '',
			action: (POLICY_ACTIONS.indexOf(s.action) >= 0) ? s.action : '',
			profile: (typeof s.profile == 'string') ? s.profile : '',
			enabled: (s.enabled != null) ? (s.enabled == '1') : true
		};
	});
	/* render order = priority ascending, ties keep the section file order -
	 * the exact mirror of the CLI's policy_render insertion sort */
	var ordered = sections.slice();
	for (var i = 1; i < ordered.length; i++) {
		var p = ordered[i];
		var j = i - 1;
		while (j >= 0 && parseInt(ordered[j].priority, 10) > parseInt(p.priority, 10)) {
			ordered[j + 1] = ordered[j];
			j--;
		}
		ordered[j + 1] = p;
	}
	var rendered = 0;
	if (state.status != null && state.status.engine != null &&
	    state.status.engine.policies != null)
		rendered = state.status.engine.policies;
	return {
		lists: lists,
		profiles: profiles,
		sections: sections,
		ordered: ordered,
		rendered: rendered
	};
}

/* the derived argv key: the ENABLED policies in priority order, each block
 * identified by [action, list-ref, protocol, profile-ref] - the exact
 * mirror of what engine_argv renders (disabled policies render nothing,
 * the priority NUMBER itself is not in the argv, only the block ORDER is;
 * a same-content reorder therefore flips the key exactly like the engine
 * decision does) */
function policiesArgvKey(m) {
	var parts = [];
	m.ordered.forEach(function(p) {
		if (!p.enabled)
			return;
		parts.push([ p.action, p.domainlist,
			p.proto.slice().sort().join(','), p.profile ].join('|'));
	});
	return parts.join('\u0001');
}

/* 'pol_media'-style stable section id derived from the label (the #82/#85
 * slug contract: refs go by section name) */
function policiesSlug(label) {
	var base = ('pol_' + label.toLowerCase().replace(/[^a-z0-9]+/g, '_')
		.replace(/^_+|_+$/g, '')).replace(/^pol_pol/, 'pol').slice(0, 48);
	var sid = base, n = 2;
	while (uci.get('wanguard-antidpi', sid) != null) {
		sid = base + '_' + n;
		n++;
	}
	return sid;
}

/* the drawer's ref validation - the exact mirror of the CLI's policy_render
 * checks, run BEFORE anything is staged (the issue criterion: a missing
 * list/profile is an inline error, never a staged ref) */
function policiesValidateDraft(d, m) {
	if (POLICY_ACTIONS.indexOf(d.action) < 0)
		return _('Choose an action (strategy, bypass or none).');
	if (!d.domainlist || !m.lists.some(function(l) { return l.sid == d.domainlist; }))
		return _('The domain list does not exist - pick one from the Domain lists tab.');
	if (!d.proto.length)
		return _('Pick at least one protocol (TCP/UDP/QUIC).');
	if (d.action == 'strategy') {
		if (!d.profile)
			return _('Strategy policies need a strategy profile.');
		if (!m.profiles.some(function(p) { return p.sid == d.profile; }))
			return _('The strategy profile does not exist - pick one from the Profiles tab.');
	}
	return null;
}

/* one drawer field change on an existing policy: validated BEFORE staging
 * (refs must exist), otherwise an inline error and nothing staged */
function policiesSetField(sid, field, value) {
	var m = policiesModel();
	var p = m.sections.filter(function(s) { return s.sid == sid; })[0];
	if (!p)
		return;
	var err = null;
	if (field == 'action') {
		if (POLICY_ACTIONS.indexOf(value) < 0)
			err = _('Choose an action (strategy, bypass or none).');
	}
	else if (field == 'domainlist') {
		if (!m.lists.some(function(l) { return l.sid == value; }))
			err = _('The domain list does not exist - pick one from the Domain lists tab.');
	}
	else if (field == 'profile') {
		if (!m.profiles.some(function(x) { return x.sid == value; }))
			err = _('The strategy profile does not exist - pick one from the Profiles tab.');
	}
	if (err != null) {
		state.policies.errors[sid] = err;
		renderPolicies();
		return;
	}
	delete state.policies.errors[sid];
	uci.set('wanguard-antidpi', sid, field, value);
	policiesMarkDirty();
	renderPolicies();
}

/* protocol toggles ride in one space-separated option (the same staging
 * contract as the profile proto); the last remaining protocol cannot be
 * unchecked (the render dies on an empty proto - keep it unreachable) */
function policiesToggleProto(sid, token) {
	var cur = uci.get('wanguard-antidpi', sid, 'proto') || '';
	var has = [];
	cur.split(' ').forEach(function(t) {
		if (t.length && POLICY_PROTOS.indexOf(t) >= 0 && has.indexOf(t) < 0)
			has.push(t);
	});
	var next = has.filter(function(t) { return t != token; });
	if (next.length == has.length)
		next.push(token);
	if (!next.length) {
		state.policies.errors[sid] = _('At least one protocol is required.');
		renderPolicies();
		return;
	}
	delete state.policies.errors[sid];
	next.sort();
	uci.set('wanguard-antidpi', sid, 'proto', next.join(' '));
	policiesMarkDirty();
	renderPolicies();
}

/* metadata fields stage silently (never in the argv); the priority is
 * numeric with the documented default fallback */
function policiesSetName(sid, text) {
	uci.set('wanguard-antidpi', sid, 'name', text);
	policiesMarkDirty();
	/* no re-render: the input keeps the focus while typing (the #85 rule) */
}

function policiesSetDeviceGroup(sid, text) {
	uci.set('wanguard-antidpi', sid, 'device_group', text);
	policiesMarkDirty();
	/* no re-render (typing) */
}

function policiesSetPriority(sid, text) {
	if (!/^[0-9]+$/.test(text)) {
		state.policies.errors[sid] = _('Priority must be a whole number.');
		renderPolicies();
		return;
	}
	delete state.policies.errors[sid];
	uci.set('wanguard-antidpi', sid, 'priority', text);
	policiesMarkDirty();
	renderPolicies();
}

/* enable/disable without deletion - a plain staged option flip (a disabled
 * policy renders no block, so the toggle drifts the argv exactly when the
 * policy was contributing one) */
function policiesSetEnabled(sid, on) {
	uci.set('wanguard-antidpi', sid, 'enabled', on ? '1' : '0');
	policiesMarkDirty();
	renderPolicies();
}

/* reorder plumbing: the ordered-table sequence is rebuilt and the
 * priorities are RENUMBERED in the step-10 convention (design §2: the
 * priority value is UI-owned; distinct values keep the render order
 * unambiguous). Both the up/down fallback buttons and the drag drop land
 * here. */
function policiesRenumber(sids) {
	sids.forEach(function(s, i) {
		uci.set('wanguard-antidpi', s, 'priority', String((i + 1) * 10));
	});
	policiesMarkDirty();
	renderPolicies();
}

function policiesReorder(sid, dir) {
	var sids = policiesModel().ordered.map(function(p) { return p.sid; });
	var i = sids.indexOf(sid);
	var j = i + dir;
	if (i < 0 || j < 0 || j >= sids.length)
		return;
	var t = sids[i];
	sids[i] = sids[j];
	sids[j] = t;
	policiesRenumber(sids);
}

/* HTML5 drag reorder: the dragged row lands BEFORE the drop target (the
 * same one-direction semantics as the up button) */
function policiesDrop(sid, targetSid) {
	var sids = policiesModel().ordered.map(function(p) { return p.sid; });
	var from = sids.indexOf(sid);
	var to = sids.indexOf(targetSid);
	if (from < 0 || to < 0 || from == to)
		return;
	sids.splice(from, 1);
	to = sids.indexOf(targetSid);
	sids.splice(to, 0, sid);
	policiesRenumber(sids);
}

function policiesNextPriority(m) {
	var max = 0;
	m.sections.forEach(function(p) {
		var v = parseInt(p.priority, 10);
		if (v > max)
			max = v;
	});
	return max + 10;
}

/* create a policy from the drawer draft (the full validation runs first -
 * invalid input is never staged, the #86 render contract stays reachable
 * only through hand-edited UCI) */
function policiesAddPolicy() {
	var d = state.policies.draft || {};
	var m = policiesModel();
	var label = (d.name || '').trim();
	if (label.length == 0) {
		state.policies.errors.editor = _('Enter a policy name.');
		renderPolicies();
		return;
	}
	var err = policiesValidateDraft(d, m);
	if (err != null) {
		state.policies.errors.editor = err;
		renderPolicies();
		return;
	}
	delete state.policies.errors.editor;
	var sid = policiesSlug(label);
	uci.add('wanguard-antidpi', 'policy', sid);
	uci.set('wanguard-antidpi', sid, 'name', label);
	uci.set('wanguard-antidpi', sid, 'priority', String(policiesNextPriority(m)));
	uci.set('wanguard-antidpi', sid, 'domainlist', d.domainlist);
	uci.set('wanguard-antidpi', sid, 'proto', d.proto.slice().sort().join(' '));
	uci.set('wanguard-antidpi', sid, 'action', d.action);
	if (d.action == 'strategy')
		uci.set('wanguard-antidpi', sid, 'profile', d.profile);
	if (typeof d.device_group == 'string' && d.device_group.length)
		uci.set('wanguard-antidpi', sid, 'device_group', d.device_group);
	uci.set('wanguard-antidpi', sid, 'enabled', (d.enabled === false) ? '0' : '1');
	state.policies.editor = null;
	state.policies.draft = null;
	policiesMarkDirty();
	renderPolicies();
}

function policiesDeletePolicy(sid) {
	if (state.policies.deleteArm != sid) {
		state.policies.deleteArm = sid;
		renderPolicies();
		return;
	}
	uci.remove('wanguard-antidpi', sid);
	state.policies.deleteArm = null;
	if (state.policies.menuOpen == sid)
		state.policies.menuOpen = null;
	if (state.policies.editor && state.policies.editor.sid == sid)
		state.policies.editor = null;
	policiesMarkDirty();
	renderPolicies();
}

/* ---------- policies drawer (#87) ---------- */

function policiesOpenEditor(sid) {
	state.policies.deleteArm = null;
	state.policies.menuOpen = null;
	if (sid == 'new')
		state.policies.draft = {
			name: '', device_group: '', domainlist: '',
			proto: [ 'tcp' ], action: 'bypass', profile: '', enabled: true
		};
	else
		delete state.policies.inputs[sid + '.priority'];
	state.policies.editor = { sid: sid, advanced: false };
	delete state.policies.errors.editor;
	renderPolicies();
}

function policiesCloseEditor() {
	state.policies.editor = null;
	state.policies.draft = null;
	delete state.policies.errors.editor;
	renderPolicies();
}

function policiesToggleAdvanced() {
	if (state.policies.editor)
		state.policies.editor.advanced = !state.policies.editor.advanced;
	renderPolicies();
}

/* ---------- policies apply ---------- */

/* the shared pipeline with the editor's one client-side guard: a staged
 * enabled policy with a broken ref/action/proto would die at render time
 * (the #86 loud fail) - block it here with a named explanation instead */
function policiesApply() {
	var m = policiesModel();
	var broken = null;
	m.sections.forEach(function(p) {
		if (!p.enabled || broken != null)
			return;
		if (POLICY_ACTIONS.indexOf(p.action) < 0)
			broken = _('Policy "%s": the action is not set.').format(p.name);
		else if (!p.domainlist || !m.lists.some(function(l) { return l.sid == p.domainlist; }))
			broken = _('Policy "%s": the domain list is missing.').format(p.name);
		else if (!p.proto.length)
			broken = _('Policy "%s": pick at least one protocol.').format(p.name);
		else if (p.action == 'strategy' &&
		    (!p.profile || !m.profiles.some(function(x) { return x.sid == p.profile; })))
			broken = _('Policy "%s": the strategy profile is missing.').format(p.name);
	});
	if (broken != null) {
		ui.addNotification(null, E('p', {}, broken), 'error');
		return;
	}
	reviewApply();
}

/* drop the client-side staged edits (committed truth untouched); the
 * shared pending-bar Discard covers the router-side deltas */
function policiesDiscardEdits() {
	state.policies.dirty = false;
	state.policies.origArgvKey = null;
	state.policies.deleteArm = null;
	state.policies.menuOpen = null;
	state.policies.editor = null;
	state.policies.draft = null;
	state.policies.dragSid = null;
	state.policies.errors = {};
	state.policies.inputs = {};
	state.policies.search = '';
	uci.unload('wanguard-antidpi');
	renderPolicies();
}

/* after the shared pipeline committed (or the router deltas were reverted),
 * the editor starts clean from the committed truth */
function policiesAfterConfigChange() {
	state.policies.dirty = false;
	state.policies.origArgvKey = null;
	state.policies.deleteArm = null;
	state.policies.menuOpen = null;
	state.policies.editor = null;
	state.policies.draft = null;
	state.policies.dragSid = null;
	state.policies.errors = {};
	state.policies.inputs = {};
	if (state.activeTab == 'policies')
		renderPolicies();
}

/* ---------- policies view (#87) ---------- */

/* the client-side table filter: name/id/action/refs/protocols against the
 * search box (case-insensitive substring) */
function policiesFilter(m) {
	var q = (state.policies.search || '').trim().toLowerCase();
	if (!q.length)
		return m.ordered;
	return m.ordered.filter(function(p) {
		return [ p.name, p.sid, p.action, p.domainlist, p.profile,
			p.proto.join(' ') ].join(' ').toLowerCase().indexOf(q) >= 0;
	});
}

function policiesSelectField(label, current, entries, onPick, allowEmpty, emptyLabel) {
	/* the drawer's select: validated staging happens in onPick; the value
	 * assignment keeps the rendered selection in sync across re-renders */
	var sel = E('select', {
		'change': function(ev) { onPick(ev.target.value); }
	});
	if (allowEmpty)
		sel.appendChild(E('option', { 'value': '' }, [ emptyLabel || _('—') ]));
	entries.forEach(function(e) {
		sel.appendChild(E('option', { 'value': e.sid }, [ e.label || e.name ]));
	});
	sel.value = current || '';
	return E('div', { 'class': 'wg-ad-addrow' }, [
		E('span', { 'class': 'wg-ad-kv-label' }, [ label ]),
		sel
	]);
}

function policiesStrategyCellText(p, m) {
	if (p.action == 'bypass')
		return _('pass unmodified');
	if (p.action == 'none')
		return _('—');
	if (p.action == 'strategy') {
		var prof = m.profiles.filter(function(x) { return x.sid == p.profile; })[0];
		return (prof != null) ? prof.name : _('missing profile');
	}
	return _('not set');
}

function policiesRow(m, p) {
	var menuOpen = (state.policies.menuOpen == p.sid);
	var armed = (state.policies.deleteArm == p.sid);
	var list = m.lists.filter(function(l) { return l.sid == p.domainlist; })[0];
	var wrap = E([]);
	var tr = E('tr', { 'class': 'wg-ad-polrow', 'draggable': 'true' });
	tr.addEventListener('dragstart', function() { state.policies.dragSid = p.sid; });
	tr.addEventListener('dragover', function(ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();
	});
	tr.addEventListener('drop', function() {
		if (state.policies.dragSid != null && state.policies.dragSid != p.sid)
			policiesDrop(state.policies.dragSid, p.sid);
		state.policies.dragSid = null;
	});
	tr.appendChild(E('td', {}, [
		E('span', { 'class': 'wg-ad-chip wg-ad-chip-muted' }, [ p.priority ])
	]));
	/* match: the policy name + the scoped list + the protocol badges (the
	 * block filters come from the policy proto - one filter source per
	 * block, #86) */
	var matchCell = E('td', {}, [
		E('strong', {}, [ p.name ]),
		' ',
		(list != null) ? list.label : _('missing list')
	]);
	p.proto.forEach(function(t) {
		matchCell.appendChild(E('span', { 'class': 'wg-ad-chip wg-ad-chip-muted' },
			[ t.toUpperCase() ]));
	});
	tr.appendChild(matchCell);
	tr.appendChild(E('td', {}, [ policiesStrategyCellText(p, m) ]));
	/* state: the honest enabled badge (staged flips show immediately) */
	tr.appendChild(E('td', {}, [ chipEl(p.enabled
		? { cls: 'wg-ad-chip-ok', label: _('Enabled') }
		: { cls: 'wg-ad-chip-muted', label: _('Disabled') }) ]));
	/* the «…» column: a per-row actions menu */
	tr.appendChild(E('td', {}, [
		E('button', {
			'class': 'btn cbi-button',
			'title': _('Row actions'),
			'click': ui.createHandlerFn(null, function() {
				state.policies.menuOpen = menuOpen ? null : p.sid;
				renderPolicies();
			})
		}, [ '⋯' ])
	]));
	wrap.appendChild(tr);
	if (menuOpen) {
		var menu = E('div', { 'class': 'wg-ad-rowmenu' });
		menu.appendChild(E('button', {
			'class': 'btn cbi-button',
			'title': _('Move up (drag fallback)'),
			'disabled': (m.ordered[0] && m.ordered[0].sid == p.sid) ? '' : null,
			'click': ui.createHandlerFn(null, function() { policiesReorder(p.sid, -1); })
		}, [ '↑ ' + _('Move up') ]));
		menu.appendChild(E('button', {
			'class': 'btn cbi-button',
			'title': _('Move down (drag fallback)'),
			'disabled': (m.ordered[m.ordered.length - 1] &&
				m.ordered[m.ordered.length - 1].sid == p.sid) ? '' : null,
			'click': ui.createHandlerFn(null, function() { policiesReorder(p.sid, 1); })
		}, [ '↓ ' + _('Move down') ]));
		menu.appendChild(E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() { policiesOpenEditor(p.sid); })
		}, [ _('Edit') ]));
		menu.appendChild(E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() {
				policiesSetEnabled(p.sid, !p.enabled);
			})
		}, [ p.enabled ? _('Disable') : _('Enable') ]));
		menu.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(null, function() { policiesDeletePolicy(p.sid); })
		}, [ armed ? _('Confirm delete?') : _('Delete') ]));
		wrap.appendChild(menu);
	}
	if (state.policies.errors[p.sid] != null) {
		wrap.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.policies.errors[p.sid] ]));
		delete state.policies.errors[p.sid];
	}
	return wrap;
}

function policiesEditorPanel(m) {
	var edv = state.policies.editor;
	var isNew = (edv.sid == 'new');
	var p = null;
	if (!isNew) {
		m.sections.forEach(function(s) {
			if (s.sid == edv.sid)
				p = s;
		});
		if (!p) /* the section vanished (deleted from another view) */
			return null;
	}
	var panel = E('div', { 'class': 'wg-ad-editor' }, [
		E('h3', {}, [ isNew ? _('New policy') : _('Edit policy: %s').format(p.name) ])
	]);

	/* name */
	var nameVal = isNew
		? function() { return state.policies.draft.name; }
		: function() { return state.policies.inputs[p.sid + '.name'] || p.name; };
	var nameInput = E('input', {
		'type': 'text',
		'placeholder': _('Policy name'),
		'input': function(ev) {
			if (isNew)
				state.policies.draft.name = ev.target.value;
			else {
				state.policies.inputs[p.sid + '.name'] = ev.target.value;
				policiesSetName(p.sid, ev.target.value);
			}
		}
	});
	nameInput.value = nameVal();
	panel.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [ nameInput ]));

	/* device group (staged-future: stored and shown, ignored by the render) */
	var dgVal = isNew
		? function() { return state.policies.draft.device_group; }
		: function() { return state.policies.inputs[p.sid + '.dg'] || p.device_group; };
	var dgInput = E('input', {
		'type': 'text',
		'placeholder': _('Device group (optional)'),
		'input': function(ev) {
			if (isNew)
				state.policies.draft.device_group = ev.target.value;
			else {
				state.policies.inputs[p.sid + '.dg'] = ev.target.value;
				policiesSetDeviceGroup(p.sid, ev.target.value);
			}
		}
	});
	dgInput.value = dgVal();
	panel.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [
		dgInput,
		chipEl({ cls: 'wg-ad-chip-muted', label: _('stored, ignored by the current render'),
			title: _('Staged-future: the field is kept in UCI for group targeting when the queue learns client identity') })
	]));

	/* domain list select (the match scope) */
	var listPick = isNew
		? function(v) { state.policies.draft.domainlist = v; renderPolicies(); }
		: function(v) { policiesSetField(p.sid, 'domainlist', v); };
	panel.appendChild(policiesSelectField(_('Domain list'),
		isNew ? state.policies.draft.domainlist : p.domainlist,
		m.lists, listPick, true, _('Pick a list…')));

	/* protocol toggles */
	var protoRow = E('div', { 'class': 'wg-ad-chips' }, [
		E('span', { 'class': 'wg-ad-hint' }, [ _('Protocols (block filters):') ])
	]);
	var protoCurrent = isNew ? state.policies.draft.proto : p.proto;
	POLICY_PROTOS.forEach(function(tok) {
		protoRow.appendChild(E('button', {
			'class': 'btn cbi-button' + ((protoCurrent.indexOf(tok) >= 0) ? ' wg-ad-modebtn-active' : ''),
			'click': ui.createHandlerFn(null, function() {
				if (isNew) {
					var a = state.policies.draft.proto;
					var i = a.indexOf(tok);
					if (i >= 0) {
						if (a.length == 1) {
							state.policies.errors.editor = _('At least one protocol is required.');
							renderPolicies();
							return;
						}
						a.splice(i, 1);
					}
					else
						a.push(tok);
					delete state.policies.errors.editor;
					renderPolicies();
				}
				else
					policiesToggleProto(p.sid, tok);
			})
		}, [ tok.toUpperCase() ]));
	});
	panel.appendChild(protoRow);

	/* action select */
	var actionPick = isNew
		? function(v) { state.policies.draft.action = v; renderPolicies(); }
		: function(v) { policiesSetField(p.sid, 'action', v); };
	panel.appendChild(policiesSelectField(_('Action'),
		isNew ? state.policies.draft.action : p.action,
		POLICY_ACTIONS.map(function(a) {
			return { sid: a, label: (a == 'strategy') ? _('strategy - desync with a profile')
				: (a == 'bypass') ? _('bypass - pass unmodified')
				: _('none - no block (fall through)') };
		}), actionPick, false));

	/* strategy profile select (visible for strategy actions only) */
	var actionCur = isNew ? state.policies.draft.action : p.action;
	if (actionCur == 'strategy') {
		var profPick = isNew
			? function(v) { state.policies.draft.profile = v; renderPolicies(); }
			: function(v) { policiesSetField(p.sid, 'profile', v); };
		var profCur = isNew ? state.policies.draft.profile : p.profile;
		panel.appendChild(policiesSelectField(_('Strategy profile'),
			profCur, m.profiles, profPick, true, _('Pick a profile…')));
		if (!profCur)
			panel.appendChild(E('div', { 'class': 'wg-ad-error' }, [
				_('Strategy policies need a strategy profile.')
			]));
	}

	/* enable policy */
	var enabledCheck = E('input', { 'type': 'checkbox' });
	enabledCheck.checked = isNew ? state.policies.draft.enabled : p.enabled;
	enabledCheck.addEventListener('change', function(ev) {
		if (isNew)
			state.policies.draft.enabled = ev.target.checked;
		else
			policiesSetEnabled(p.sid, ev.target.checked);
	});
	panel.appendChild(E('div', { 'class': 'wg-ad-chips' }, [
		E('label', { 'class': 'wg-ad-hint' }, [ enabledCheck, ' ' + _('Enable policy') ])
	]));

	/* advanced (collapse): the manual priority override - normal
	 * reordering happens through drag / the up-down fallback */
	panel.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, policiesToggleAdvanced)
		}, [ edv.advanced ? _('Hide advanced') : _('Advanced') ])
	]));
	if (edv.advanced && !isNew) {
		var prInput = E('input', {
			'type': 'text',
			'placeholder': _('Priority (lower = earlier)'),
			'input': function(ev) { state.policies.inputs[p.sid + '.priority'] = ev.target.value; }
		});
		prInput.value = state.policies.inputs[p.sid + '.priority'] || p.priority;
		panel.appendChild(E('div', { 'class': 'wg-ad-addrow' }, [
			prInput,
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(null, function() {
					policiesSetPriority(p.sid, (state.policies.inputs[p.sid + '.priority'] != null)
						? state.policies.inputs[p.sid + '.priority'] : String(p.priority));
				})
			}, [ _('Set') ])
		]));
		panel.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
			_('Manual priority override - normal reordering happens by dragging rows or with the row menu arrows.')
		]));
	}

	if (state.policies.errors.editor != null)
		panel.appendChild(E('div', { 'class': 'wg-ad-error' }, [ state.policies.errors.editor ]));

	/* footer actions */
	var footer = [];
	if (isNew) {
		footer.push(E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, policiesAddPolicy)
		}, [ _('Create policy') ]));
	}
	footer.push(E('button', {
		'class': 'btn cbi-button',
		'click': ui.createHandlerFn(null, policiesCloseEditor)
	}, [ isNew ? _('Cancel') : _('Close') ]));
	panel.appendChild(E('div', { 'class': 'wg-ad-actions' }, footer));
	return panel;
}

function buildPoliciesView() {
	var m = policiesModel();
	var frag = E([]);

	/* the concept's standing notice */
	frag.appendChild(E('div', { 'class': 'alert-message' }, [
		E('p', {}, [ _('Only mihomo DIRECT traffic is eligible. Proxy tunnel and local destinations remain excluded.') ])
	]));

	/* the processing table (concept: Priority / Match / Strategy / State /
	 * «…»): drag-priority with the up/down fallback in the row menu */
	var list = E('div', { 'class': 'wg-ad-panel' });
	var searchInput = E('input', {
		'type': 'text',
		'class': 'wg-ad-search',
		'placeholder': _('Search policies'),
		'input': function(ev) { state.policies.search = ev.target.value; },
		'change': function(ev) {
			state.policies.search = ev.target.value;
			renderPolicies();
		}
	});
	searchInput.value = state.policies.search || '';
	list.appendChild(E('div', { 'class': 'wg-ad-head' }, [
		E('h3', {}, [ _('Processing policies'), ' ',
			chipEl({ cls: 'wg-ad-chip-muted', label: '%d rendered'.format(m.rendered),
				title: _('Committed block count from the status document - first match wins, catch-all last') }),
			(m.rendered > 0) ? chipEl({ cls: 'wg-ad-chip-ok', label: _('Desync scoped by policies') }) : E([]) ]),
		E('div', { 'class': 'wg-ad-actions' }, [
			searchInput,
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(null, function() { policiesOpenEditor('new'); })
			}, [ _('Add policy') ])
		])
	]));
	var filtered = policiesFilter(m);
	var table = E('table', { 'class': 'wg-ad-table' }, [
		E('tr', {}, [
			E('th', {}, [ _('Priority') ]),
			E('th', {}, [ _('Match') ]),
			E('th', {}, [ _('Strategy') ]),
			E('th', {}, [ _('State') ]),
			E('th', {}, [ '⋯' ])
		])
	]);
	if (filtered.length == 0)
		table.appendChild(E('tr', {}, [
			E('td', { 'colspan': '5' }, [
				(m.sections.length == 0)
					? _('No policies configured - all eligible traffic follows the global strategy (the catch-all).')
					: _('No policies match the search.')
			])
		]));
	filtered.forEach(function(p) {
		table.appendChild(policiesRow(m, p));
	});
	list.appendChild(table);
	list.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('Device groups are identifiers for future group targeting; mihomo DIRECT filtering does not preserve client identity.')
	]));
	list.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('Order = priority (lower first); the first matching policy wins. Drag rows to reorder or use the row menu arrows. Order/action changes need an engine restart; domain list CONTENT edits apply via reload.')
	]));
	frag.appendChild(list);

	/* the drawer (New/Edit) */
	var panel = (state.policies.editor != null) ? policiesEditorPanel(m) : null;
	if (panel != null)
		frag.appendChild(panel);

	/* apply block: the honest badges (order/action/proto/ref/enabled edits
	 * drift the engine argv -> restart; name/device_group are metadata;
	 * staged domain-list content edits from the Domain lists tab ride the
	 * same apply via reload) */
	var applyCard = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Apply') ])
	]);
	var argvChanged = (policiesArgvKey(m) != state.policies.origArgvKey);
	var anyDirty = state.policies.dirty || state.domains.dirty;
	if (state.policies.dirty) {
		if (argvChanged)
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-warn',
				label: _('Policy order or actions changed - apply restarts the engine'),
				title: _('Policy blocks ride in the engine argv: order/action/protocol/ref/enabled changes need a restart to take effect') }));
		else {
			applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-ok',
				label: _('Metadata only - the engine stays untouched'),
				title: _('Name and device-group edits do not appear in the engine argv') }));
			if (state.domains.dirty)
				applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-ok',
					label: _('Domain list edits apply via reload - live connections stay up'),
					title: _('SIGHUP re-reads the hostlist files without dropping the queue or connections') }));
		}
	}
	else if (state.domains.dirty) {
		applyCard.appendChild(chipEl({ cls: 'wg-ad-chip-ok',
			label: _('Domain list edits apply via reload - live connections stay up'),
			title: _('SIGHUP re-reads the hostlist files without dropping the queue or connections') }));
	}
	else {
		applyCard.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('No unsaved edits.') ]));
	}
	applyCard.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, policiesApply),
			'disabled': (!anyDirty || state.applyBusy) ? '' : null
		}, [ _('Apply changes') ]),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(null, policiesDiscardEdits),
			'disabled': (!state.policies.dirty) ? '' : null
		}, [ _('Discard edits') ])
	]));
	frag.appendChild(applyCard);
	return frag;
}

/* the tab body renders once per switch (and after applies) - NOT per poll
 * tick: a rebuild would blow away in-progress edits (the #82 rule). The
 * LuCI uci client is read through a lazy load; a failure renders the
 * honest warn card. */
function renderPolicies() {
	var node = state.bodyNode;
	if (!node)
		return;
	node.setAttribute('data-unavail', 'false');
	node.innerHTML = '';
	node.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading configuration…') ]));
	uci.load('wanguard-antidpi').then(function() {
		if (state.activeTab != 'policies' || !state.bodyNode)
			return;
		if (state.policies.origArgvKey == null)
			state.policies.origArgvKey = policiesArgvKey(policiesModel());
		state.policies.loaded = true;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(buildPoliciesView());
	}).catch(function(e) {
		if (state.activeTab != 'policies' || !state.bodyNode)
			return;
		state.bodyNode.innerHTML = '';
		state.bodyNode.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The configuration could not be read (%s).').format((e && e.message) || 'error') ])
		]));
	});
}

/* ---------- tests & logs tab (#88) ---------- */

/* Observability of the engine: the queue counters with the per-tick delta
 * (the measurement window that backs the header's "Processing active"
 * chip), the full validation panel (the same Run checks surface as the
 * Overview - buildValidationCard is reused, provider effectiveness stays
 * the honest "Not tested" row, #92), the engine.debug toggle (a staged
 * UCI edit through the shared apply pipeline - the flag rides the engine
 * argv, so a flip is a restart; nfqws2 accepts ONLY 0/1, the #70 fact) and
 * the log viewer (an on-demand `events --json` fetch - the filter and the
 * tail bound run on the router, the browser never pulls the raw ring).
 * Per-tick only the counters card is patched; the log snapshot and the
 * debug editor survive ticks. */

var LOG_FILTERS = [
	{ id: 'engine', label: 'Engine (nfqws2 + wanguard-antidpi)' },
	{ id: 'nfqws2', label: 'nfqws2 verdicts' },
	{ id: 'antidpi', label: 'wanguard-antidpi service' },
	{ id: 'mihomo', label: 'mihomo warnings' }
];
var LOG_TAIL = 50; /* the UI's tail request (the CLI clamps to [1, 200]) */

/* clipboard helper: navigator.clipboard is unavailable on the router's
 * http:// LuCI (no secure context) - the execCommand fallback keeps the
 * copy buttons alive (the luci-app-wanguard pattern); every failure path
 * degrades to a toast, never throws */
function copyText(text) {
	var done = function(okflag) {
		ui.addNotification(null, E('p', {},
			okflag ? _('Log copied to the clipboard') : _('Copy failed')),
			okflag ? 'info' : 'error');
	};
	try {
		if (typeof navigator != 'undefined' && navigator.clipboard &&
			typeof navigator.clipboard.writeText == 'function') {
			navigator.clipboard.writeText(text).then(function() { done(true); },
				function() { copyFallback(text, done); });
			return;
		}
	}
	catch (e) { /* fall through to the fallback */ }
	copyFallback(text, done);
}

function copyFallback(text, done) {
	var okflag = false;
	try {
		if (typeof document != 'undefined' && typeof document.createElement == 'function' &&
			document.body) {
			var ta = document.createElement('textarea');
			ta.value = text;
			ta.setAttribute('readonly', '');
			ta.style.position = 'fixed';
			ta.style.opacity = '0';
			document.body.appendChild(ta);
			ta.select();
			try { okflag = (document.execCommand('copy') === true); }
			catch (e) { okflag = false; }
			document.body.removeChild(ta);
		}
	}
	catch (e) { okflag = false; }
	done(okflag);
}

function counterVal(c, rule, field) {
	if (c == null || c[rule] == null || c[rule][field] == null)
		return null;
	return c[rule][field];
}

/* the counters card: the two queue-rule counters (TCP/UDP 443) with the
 * delta over the last tick window; first window renders muted deltas */
function testsCountersCard() {
	var st = state.status;
	var c = (st.nft && st.nft.counters) ? st.nft.counters : null;
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Queue counters'), ' ',
			((st.nft && st.nft.table_present) && c == null)
				? chipEl({ cls: 'wg-ad-chip-muted', label: _('no counters') }) : E([]) ])
	]);
	if (c == null) {
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
			(st.nft && st.nft.table_present)
				? _('The scope table reports no counter objects.')
				: _('The scope table is absent - it arrives with the service start (or `wanguard-antidpi nft-apply`).')
		]));
		return card;
	}
	var prev = state.prevCounters;
	var row = function(name, rule) {
		var p = counterVal(c, rule, 'packets');
		var b = counterVal(c, rule, 'bytes');
		var dP = null, dB = null;
		/* the delta needs a PREVIOUS-tick snapshot: the same object (the
		 * same status document, e.g. at tab open) means no window was
		 * measured yet - muted is the honest render */
		if (prev != null && prev !== c) {
			var op = counterVal(prev, rule, 'packets');
			var ob = counterVal(prev, rule, 'bytes');
			if (p != null && op != null)
				dP = p - op;
			if (b != null && ob != null)
				dB = b - ob;
		}
		return E('tr', {}, [
			E('td', {}, [ name ]),
			E('td', {}, [ (p != null) ? String(p) : '—' ]),
			E('td', {}, [ (dP != null) ? '+' + dP : '—' ]),
			E('td', {}, [ (b != null) ? String(b) : '—' ]),
			E('td', {}, [ (dB != null) ? '+' + dB : '—' ])
		]);
	};
	card.appendChild(E('table', { 'class': 'wg-ad-table' }, [
		E('tr', {}, [
			E('th', {}, [ _('Rule') ]),
			E('th', {}, [ _('Packets') ]),
			E('th', {}, [ _('Δ packets') ]),
			E('th', {}, [ _('Bytes') ]),
			E('th', {}, [ _('Δ bytes') ])
		]),
		row(_('TCP (443) queue'), 'tcp'),
		row(_('UDP (443) queue'), 'udp')
	]));
	card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('Δ = between the last two polls - the same window the Processing chip reads.')
	]));
	return card;
}

/* the per-tick patch: rebuild ONLY the counters card - the log pre and the
 * debug editor keep their DOM (a rebuild would blow away the snapshot the
 * user is reading) */
function testsUpdateCounters() {
	if (state.activeTab != 'tests' || !state.bodyNode || !state.tests.countersHost)
		return;
	state.tests.countersHost.innerHTML = '';
	state.tests.countersHost.appendChild(testsCountersCard());
}

/* the on-demand log fetch: one `events --json` exec per Refresh click,
 * never in the poll tick */
function testsFetchLog() {
	if (state.tests.logBusy)
		return;
	state.tests.logBusy = true;
	state.tests.logError = null;
	renderTests();
	return callCli(CLI, [ 'events', '--json',
		'--filter=' + state.tests.logFilter, '--tail=' + LOG_TAIL
	]).then(function(res) {
		var doc = null;
		if (res && typeof res.stdout == 'string' && res.stdout.length) {
			try { doc = JSON.parse(res.stdout); } catch (e) {}
		}
		if (doc != null && doc.lines != null && doc.available != null) {
			state.tests.logLines = doc.lines;
			state.tests.logAvail = doc.available;
			state.tests.logError = null;
		}
		else {
			/* keep a previous snapshot visible; surface the failure */
			state.tests.logError = (res && typeof res.stderr == 'string' && res.stderr.length)
				? res.stderr.split('\n')[0].trim()
				: _('the output is not an events report');
		}
		state.tests.logBusy = false;
		renderTests();
	}).catch(function(e) {
		state.tests.logBusy = false;
		state.tests.logError = (e && e.message) || 'error';
		renderTests();
	});
}

function testsLogCard() {
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Syslog tail') ])
	]);
	if (state.tests.logError != null)
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The log fetch failed: %s').format(state.tests.logError) ])
		]));

	/* the filter select + Refresh (+ Copy when a snapshot exists) */
	var sel = E('select', {
		'change': function(ev) {
			state.tests.logFilter = ev.target.value;
			renderTests();
		}
	});
	LOG_FILTERS.forEach(function(f) {
		sel.appendChild(E('option', { 'value': f.id }, [ f.label ]));
	});
	sel.value = state.tests.logFilter;

	var actions = E('div', { 'class': 'wg-ad-actions' }, [
		E('span', { 'class': 'wg-ad-kv-label' }, [ _('Filter:') ]),
		sel,
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, testsFetchLog),
			'disabled': state.tests.logBusy ? '' : null
		}, [ state.tests.logBusy ? _('Fetching…') : _('Refresh') ])
	]);
	if (state.tests.logLines != null && state.tests.logLines.length)
		actions.appendChild(E('button', {
			'class': 'wg-ad-copy',
			'click': ui.createHandlerFn(null, function() {
				copyText(state.tests.logLines.join('\n'));
			})
		}, [ _('Copy') ]));
	card.appendChild(actions);
	card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('The filter and the %d-line bound run on the router; the browser never pulls the raw log.').format(LOG_TAIL)
	]));

	if (state.tests.logLines == null) {
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Not fetched yet.') ]));
		return card;
	}
	if (!state.tests.logAvail) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('logread is unavailable on this system (no running syslogd).') ])
		]));
		return card;
	}
	if (!state.tests.logLines.length) {
		card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
			_('No matching lines in the syslog tail.')
		]));
		return card;
	}
	/* one text node - log lines are data, never HTML (the #80 discipline) */
	card.appendChild(E('pre', { 'class': 'wg-ad-log' },
		[ state.tests.logLines.join('\n') ]));
	return card;
}

function testsToggleDebug() {
	var cur = uci.get('wanguard-antidpi', 'engine', 'debug');
	if (cur == null)
		return;
	uci.set('wanguard-antidpi', 'engine', 'debug', (cur == '1') ? '0' : '1');
	renderTests();
}

/* the debug toggle card: a staged UCI edit through the shared pipeline.
 * The flip is honest about its cost (--debug rides the argv -> restart)
 * and about its nature: a diagnostic surface, not a resting state. */
function testsDebugCard(loadError) {
	var card = E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ _('Engine verbose logging') ])
	]);
	if (loadError != null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The configuration could not be read (%s).')
				.format((loadError && loadError.message) || 'error') ])
		]));
		return card;
	}
	var staged = uci.get('wanguard-antidpi', 'engine', 'debug');
	if (staged == null) {
		card.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The engine section is missing from the configuration - the toggle needs it.') ])
		]));
		return card;
	}
	var stagedOn = (staged == '1');
	if (stagedOn)
		card.appendChild(chipEl({ cls: 'wg-ad-chip-warn',
			label: _('Verbose logging is ON - turn it off when done'),
			title: _('nfqws2 logs every verdict: the syslog ring fills within minutes under load') }));
	else
		card.appendChild(chipEl({ cls: 'wg-ad-chip-muted',
			label: _('Verbose logging is off') }));
	if (state.tests.origDebug != null && staged != state.tests.origDebug)
		card.appendChild(chipEl({ cls: 'wg-ad-chip-warn',
			label: _('The debug flag rides the engine argv - apply restarts the engine'),
			title: _('nfqws2 --debug accepts only 0 or 1 (no levels); the restart re-reads the argv') }));
	card.appendChild(E('div', { 'class': 'wg-ad-actions' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, testsToggleDebug)
		}, [ stagedOn ? _('Turn off verbose logging') : _('Turn on verbose logging') ]),
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(null, reviewApply),
			'disabled': (staged == state.tests.origDebug || state.applyBusy) ? '' : null
		}, [ _('Apply changes') ])
	]));
	card.appendChild(E('p', { 'class': 'wg-ad-hint' }, [
		_('Diagnostic surface, not a resting state: verbose logging fills the syslog ring quickly.')
	]));
	return card;
}

function buildTestsView(node, loadError) {
	/* the counters holder - patched per tick (testsUpdateCounters) */
	var countersHost = E([]);
	state.tests.countersHost = countersHost;
	countersHost.appendChild(testsCountersCard());
	node.appendChild(countersHost);
	/* the validation panel: the Overview card reused verbatim (issue: a
	 * duplicate or a link - the duplicate keeps Run checks reachable from
	 * both tabs; provider effectiveness stays "Not tested", #92) */
	node.appendChild(buildValidationCard());
	node.appendChild(testsDebugCard(loadError));
	node.appendChild(testsLogCard());
}

/* the tab body: uci.load covers the debug option only - a failure degrades
 * that card while the rest of the tab (counters/validation/log) stays
 * alive. The log snapshot and the debug editor survive poll ticks; only
 * the counters card is patched per tick. */
function renderTests() {
	var node = state.bodyNode;
	if (!node)
		return;
	node.innerHTML = '';
	node.appendChild(E('p', { 'class': 'wg-ad-hint' }, [ _('Loading configuration…') ]));
	uci.load('wanguard-antidpi').then(function() {
		if (state.activeTab != 'tests' || !state.bodyNode)
			return;
		if (state.tests.origDebug == null)
			state.tests.origDebug = uci.get('wanguard-antidpi', 'engine', 'debug');
		state.bodyNode.innerHTML = '';
		buildTestsView(state.bodyNode);
	}).catch(function(e) {
		if (state.activeTab != 'tests' || !state.bodyNode)
			return;
		state.bodyNode.innerHTML = '';
		buildTestsView(state.bodyNode, e);
	});
}

/* after the shared pipeline committed (or the deltas were reverted), the
 * debug toggle restarts from the committed truth */
function testsAfterConfigChange() {
	state.tests.origDebug = null;
	state.tests.countersHost = null;
	if (state.activeTab == 'tests')
		renderTests();
}

/* ---------- tab frame (issue #80) ---------- */

function buildTabbar() {
	var bar = E('div', { 'class': 'wg-tabs' });
	TABS.forEach(function(id) {
		bar.appendChild(E('button', {
			'class': 'wg-tab' + (id == state.activeTab ? ' wg-tab-active' : ''),
			'data-tab': id,
			'click': function() { switchTab(id); }
		}, [ tabLabel(id) ]));
	});
	return bar;
}

function switchTab(id) {
	if (state.activeTab == id)
		return;
	state.activeTab = id;
	if (state.tabsNode) {
		state.tabsNode.querySelectorAll('.wg-tab').forEach(function(b) {
			b.classList[b.getAttribute('data-tab') == id ? 'add' : 'remove']('wg-tab-active');
		});
	}
	renderBody();
}

/* the tab body: the unavailable section (missing/pre-status CLI) or the
 * active tab's content. Overview rebuilds per tick (data-driven); the not
 * yet staged tabs stay placeholder panels. */
function renderBody() {
	var node = state.bodyNode;
	if (!node)
		return;
	node.setAttribute('data-unavail', String(!!state.unavailable));
	node.innerHTML = '';

	if (state.unavailable) {
		node.appendChild(E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, [ _('The Anti-DPI status interface is unavailable: the installed wanguard-antidpi package is missing or predates the status command.') ]),
			E('p', {}, [ _('Update the package from the wanguard apk feed:') ]),
			E('p', {}, [ E('code', {}, [ 'apk update && apk upgrade wanguard-antidpi' ]) ])
		]));
		return;
	}

	if (state.activeTab == 'overview') {
		node.appendChild(renderOverview());
		return;
	}
	if (state.activeTab == 'profiles') {
		renderProfiles();
		return;
	}
	if (state.activeTab == 'policies') {
		renderPolicies();
		return;
	}
	if (state.activeTab == 'domains') {
		renderDomains();
		return;
	}
	if (state.activeTab == 'tunnel') {
		renderTunnel();
		return;
	}
	if (state.activeTab == 'tests') {
		renderTests();
		return;
	}

	node.appendChild(E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ tabLabel(state.activeTab) ]),
		E('p', { 'class': 'wg-ad-hint' }, [ _('This section arrives in a later package update.') ])
	]));
}

/* poll tick: refetch the status document, refresh the chips, rebuild the
 * body on an availability flip, while the data-driven Overview is open, or
 * right after a config-change cycle (the after-config renders of the
 * editor tabs used the PRE-refresh status - one fresh rebuild is safe
 * there: the cycle already reset every editor). The Tests & Logs tab gets
 * the lighter touch: only its counters card is patched per tick. */
function update() {
	var wasUnavailable = (state.bodyNode != null &&
		state.bodyNode.getAttribute('data-unavail') == 'true');
	/* the Tests & Logs counters window is measured BEFORE updateChips
	 * advances the processing snapshot: the card's delta = the previous
	 * tick's counters vs the freshly fetched ones */
	testsUpdateCounters();
	updateChips();
	if (!state.bodyNode)
		return;
	var availChanged = ((!!state.unavailable) != wasUnavailable);
	var rebuild = availChanged || state.configChanged;
	state.configChanged = false;
	if (rebuild || state.activeTab == 'overview')
		renderBody();
}

/* The LuCI module loader requires every module factory to yield a CLASS
 * (Class.isSubclass check) and instantiates it: `require
 * wanguard-antidpi.core as ad` binds the INSTANCE - all logic lives in
 * closures above, so the instance is a stateless facade over `state`
 * (the luci-app-wanguard core pattern, reused for the #89 view tests). */
return L.Class.extend({
	__name__: 'LuCI.wanguard-antidpi.core',

	__init__() {},

	state: state,
	CLI: CLI,
	CSS: CSS,
	TABS: TABS,
	tabLabel: tabLabel,
	refresh: refresh,
	update: update,
	buildTabbar: buildTabbar,
	switchTab: switchTab,
	renderBody: renderBody,
	updateChips: updateChips,
	renderOverview: renderOverview,
	parseStrategy: parseStrategy,
	runChecks: runChecks,
	reviewApply: reviewApply,
	discardPending: discardPending,
	applyNotice: applyNotice,
	applySeverity: applySeverity,
	domainIsValid: domainIsValid,
	domainsModel: domainsModel,
	renderDomains: renderDomains,
	buildDomainsView: buildDomainsView,
	domainsAddDomain: domainsAddDomain,
	domainsSetMode: domainsSetMode,
	domainsAfterConfigChange: domainsAfterConfigChange,
	validAddrEntry: validAddrEntry,
	tunnelModel: tunnelModel,
	renderTunnel: renderTunnel,
	buildTunnelView: buildTunnelView,
	tunnelAddPin: tunnelAddPin,
	tunnelAddHost: tunnelAddHost,
	tunnelSetNum: tunnelSetNum,
	tunnelAfterConfigChange: tunnelAfterConfigChange,
	profilesModel: profilesModel,
	profilesStrategyKey: profilesStrategyKey,
	profilesPolicyUse: profilesPolicyUse,
	profilesProtoOfWords: profilesProtoOfWords,
	PROFILE_PRESETS: PROFILE_PRESETS,
	renderProfiles: renderProfiles,
	buildProfilesView: buildProfilesView,
	profilesOpenEditor: profilesOpenEditor,
	profilesCloseEditor: profilesCloseEditor,
	profilesApplyPreset: profilesApplyPreset,
	profilesAddProfile: profilesAddProfile,
	profilesSetEnabled: profilesSetEnabled,
	profilesSetColor: profilesSetColor,
	profilesSetWords: profilesSetWords,
	profilesMove: profilesMove,
	profilesAdoptLegacy: profilesAdoptLegacy,
	profilesAfterConfigChange: profilesAfterConfigChange,
	policiesModel: policiesModel,
	policiesArgvKey: policiesArgvKey,
	POLICY_ACTIONS: POLICY_ACTIONS,
	renderPolicies: renderPolicies,
	buildPoliciesView: buildPoliciesView,
	policiesOpenEditor: policiesOpenEditor,
	policiesCloseEditor: policiesCloseEditor,
	policiesAddPolicy: policiesAddPolicy,
	policiesSetEnabled: policiesSetEnabled,
	policiesSetField: policiesSetField,
	policiesToggleProto: policiesToggleProto,
	policiesReorder: policiesReorder,
	policiesDrop: policiesDrop,
	policiesApply: policiesApply,
	policiesValidateDraft: policiesValidateDraft,
	policiesAfterConfigChange: policiesAfterConfigChange,
	LOG_FILTERS: LOG_FILTERS,
	renderTests: renderTests,
	buildTestsView: buildTestsView,
	testsCountersCard: testsCountersCard,
	testsUpdateCounters: testsUpdateCounters,
	testsFetchLog: testsFetchLog,
	testsToggleDebug: testsToggleDebug,
	testsAfterConfigChange: testsAfterConfigChange,
	copyText: copyText
});
