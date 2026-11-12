/* luci-app-wanguard-antidpi core — the shared engine behind the Anti-DPI
 * page (view/wanguard/antidpi.js, issue #80). Thin client over the
 * `wanguard-antidpi status --json` surface (issue #76): ONE rpc file exec
 * per refresh — the same pattern as the luci-app-wanguard core module.
 * The browser never touches nft/uci/logread directly.
 *
 * Degradation contract (#76/#80): nothing throws on missing surfaces. An
 * old or missing CLI (the pre-status packages, a denied ACL) resolves to
 * the page's "unavailable — update the package" section plus muted chips;
 * a present CLI renders its stable keys. Partial degradations surface as
 * the status document's "degraded" map (a muted hint line under the chips
 * — the per-surface cards belong to their own stages #81–#88).
 *
 * This is the SCAFFOLD issue (#80): the header actions, the chips row and
 * the six sub-tab frames (Overview / Profiles / Policies / Domain lists /
 * Tunnel protection / Tests & Logs). The per-tab content lands with its
 * own stage into the same holders. No innerHTML with CLI data: only
 * static strings from THIS file's tables/chips ever reach innerHTML
 * (the status fields go through E() text nodes), same discipline as the
 * luci-app-wanguard core.
 */
'use strict';
'require rpc';

var callCli = rpc.declare({
	object: 'file',
	method: 'exec',
	params: [ 'command', 'params' ],
	expect: { '': {} }
});

var CLI = '/usr/bin/wanguard-antidpi';

/* per-page session state (module closure; one page load = one instance) */
var state = {
	status: null,       /* parsed `status --json` document (#76 contract) */
	unavailable: null,  /* null = loading, false = live, 'exec'/'parse' = degraded */
	prevPkts: null,     /* queue packets of the previous tick (processing delta) */
	activeTab: 'overview',
	tabsNode: null,     /* tab bar holder, set by the view render */
	chipsNode: null,    /* chips row holder, set by the view render */
	bodyNode: null,     /* tab body holder, set by the view render */
	busy: false
};

/* sub-tab frame (issue #80): the order of the concept mock; the content of
 * each tab lands with its own stage (#81 overview, #82 domain lists,
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
	".wg-ad-degraded { font-size:.82em; opacity:.65; margin:0 0 .75em; }",
	".wg-ad-panel { background:rgba(128,128,128,.06); border:1px solid rgba(128,128,128,.3); border-radius:6px; padding:1em; }",
	".wg-ad-panel h3 { margin:0 0 .4em; }",
	".wg-ad-hint { opacity:.55; margin:0; }"
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

/* never rejects: every caller can .then() unconditionally (issue #80
 * "без throw") */
function refresh() {
	return callCli(CLI, [ 'status', '--json' ]).then(function(res) {
		parseStatus(res);
	}).catch(function() {
		state.status = null;
		state.unavailable = 'exec';
	});
}

/* ---------- chips row (issue #80): Engine / Processing / Scope / Pending ---------- */

function chipEl(def) {
	return E('span', { 'class': 'wg-ad-chip ' + def.cls, 'title': def.title || '' }, [
		E('span', { 'class': 'wg-ad-dot' }, []),
		' ',
		def.label
	]);
}

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
 * stage placeholder of the active tab. Availability flips are the only
 * rebuild trigger for the poll loop (the scaffold bodies are static). */
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

	node.appendChild(E('div', { 'class': 'wg-ad-panel' }, [
		E('h3', {}, [ tabLabel(state.activeTab) ]),
		E('p', { 'class': 'wg-ad-hint' }, [ _('This section arrives in a later package update.') ])
	]));
}

/* poll tick: refetch the status document, refresh the chips, rebuild the
 * body only when availability flipped */
function update() {
	var wasUnavailable = (state.bodyNode != null &&
		state.bodyNode.getAttribute('data-unavail') == 'true');
	updateChips();
	if (state.bodyNode && (!!state.unavailable) != wasUnavailable)
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
	updateChips: updateChips
});
