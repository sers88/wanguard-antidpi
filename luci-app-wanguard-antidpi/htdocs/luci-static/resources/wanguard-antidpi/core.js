/* luci-app-wanguard-antidpi core — the shared engine behind the Anti-DPI
 * page (view/wanguard/antidpi.js, issues #80/#81/#82). Thin client over the
 * `wanguard-antidpi` CLI surfaces (#76 status, #77 apply): ONE status exec
 * per refresh plus the strategy-words exec (engine-cmdline), with the
 * heavier probes (apply --check, apply) strictly on-demand behind their
 * buttons. The browser never touches nft/logread directly; its only direct
 * UCI verbs are the Domain lists editor's staging (#82 - client-side via
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
	domains: {          /* Domain lists tab (#82): client-side staged editor */
		loaded: false,    /* the uci config has been read at least once */
		dirty: false,     /* staged edits awaiting the apply pipeline */
		origEnabled: null,  /* committed enabled at load time (mode-flip detect) */
		deleteArm: null,  /* sid armed for the two-step list delete */
		errors: {},       /* inline validation errors, per-list (and '__new') */
		inputs: {},       /* per-list add-domain input text (survives re-renders) */
		newName: ''       /* new-list label input text */
	},
	busy: false
};

/* sub-tab frame (issue #80): the order of the concept mock; the content of
 * each tab lands with its own stage (#81 overview done, #82 domain lists,
 * #83 tunnel protection, #85 profiles, #87 policies, #88 tests & logs) */
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
	".wg-ad-addrow input { flex:1; min-width:14em; }"
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
 * is a degraded surface -> Table absent. */
function processingChip() {
	var st = state.status;
	var c = (st.nft && st.nft.counters) ? st.nft.counters : null;
	if (c == null)
		return { cls: 'wg-ad-chip-warn',
			label: (st.nft && st.nft.table_present) ? _('Processing unknown') : _('Table absent') };
	var pkts = ((c.tcp && c.tcp.packets != null) ? c.tcp.packets : 0) +
		((c.udp && c.udp.packets != null) ? c.udp.packets : 0);
	var active = (state.prevPkts != null && pkts > state.prevPkts);
	state.prevPkts = pkts;
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

	var table = E('table', { 'class': 'wg-ad-table' }, [
		E('tr', {}, [
			E('th', {}, [ _('Profile') ]),
			E('th', {}, [ _('Protocols') ]),
			E('th', {}, [ _('Words') ]),
			E('th', {}, [ _('Policies') ])
		])
	]);
	parseStrategy(s.words).forEach(function(p) {
		table.appendChild(E('tr', {}, [
			E('td', {}, [ p.name ]),
			E('td', {}, [ p.proto.join(' ') || _('—') ]),
			E('td', {}, [ '%d'.format(p.words.length) ]),
			E('td', {}, [ '%d'.format(p.desync) ])
		]));
	});
	card.appendChild(table);

	var meta = [];
	if (st.engine && st.engine.version != null)
		meta.push(st.engine.version);
	meta.push(_('Read-only: profile management arrives in a later release.'));
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
		domainsAfterConfigChange();
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
		domainsAfterConfigChange();
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
		(l.policies > 0) ? '%d'.format(l.policies) : _('—'),
		' ',
		E('span', { 'class': 'wg-ad-hint' }, [ _('(policy references arrive in a later release)') ])
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
	if (state.activeTab == 'domains') {
		renderDomains();
		return;
	}

	node.appendChild(E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ tabLabel(state.activeTab) ]),
		E('p', { 'class': 'wg-ad-hint' }, [ _('This section arrives in a later package update.') ])
	]));
}

/* poll tick: refetch the status document, refresh the chips, rebuild the
 * body on an availability flip or while the data-driven Overview is open */
function update() {
	var wasUnavailable = (state.bodyNode != null &&
		state.bodyNode.getAttribute('data-unavail') == 'true');
	updateChips();
	if (!state.bodyNode)
		return;
	var availChanged = ((!!state.unavailable) != wasUnavailable);
	if (availChanged || state.activeTab == 'overview')
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
	domainsAfterConfigChange: domainsAfterConfigChange
});
