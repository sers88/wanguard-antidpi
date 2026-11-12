/* WAN Guard Anti-DPI page (issue #80) — the real tab rendered when the
 * wanguard-antidpi add-on is installed. Its menu.d node (wanguard-antidpi.json)
 * merges OVER the luci-app-wanguard placeholder stub (#78/#79 merge contract),
 * so this view replaces the placeholder as soon as both packages are
 * installed; in standalone mode this package owns the only menu content.
 *
 * Scaffold shape (issue #80): header with the two placeholder actions
 * (Service settings / + New profile — disabled until their own stages),
 * the chips row fed by ONE `wanguard-antidpi status --json` exec (#76) and
 * the six sub-tab frames (Overview / Profiles / Policies / Domain lists /
 * Tunnel protection / Tests & Logs — content per tab lands with #81–#88).
 * A missing or pre-status CLI renders the "unavailable — update the
 * package" section and muted chips instead of throwing. All logic lives
 * in the shared wanguard-antidpi.core module (the luci-app-wanguard
 * pattern), so the #89 view tests can drive the page headless. */
'use strict';
'require view';
'require poll';
'require wanguard-antidpi.core as ad';

return view.extend({
	load: function() {
		/* refresh() never rejects: a dead CLI resolves into the
		 * unavailable state instead of failing the page load */
		return ad.refresh();
	},

	render: function() {
		/* header (concept mock): title + subtitle on the left, the two
		 * stage-placeholder actions on the right */
		var header = E('div', { 'class': 'wg-ad-head' }, [
			E('div', {}, [
				E('h2', { 'style': 'margin:0; display:inline' }, [ _('Anti-DPI') ]),
				E('span', { 'class': 'wg-ad-sub' },
					[ _('Strategies, targeting and traffic diagnostics') ])
			]),
			E('div', { 'class': 'wg-ad-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'disabled': '',
					'title': _('Service settings arrive in a later release')
				}, [ _('Service settings') ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'disabled': '',
					'title': _('Profile management arrives in a later release')
				}, [ '+ ' + _('New profile') ])
			])
		]);

		ad.state.tabsNode = ad.buildTabbar();
		ad.state.chipsNode = E('div', { 'class': 'wg-ad-chips' });
		ad.state.bodyNode = E('div', {});
		ad.renderBody();

		var root = E([
			E('style', { 'type': 'text/css' }, [ ad.CSS ]),
			header,
			ad.state.tabsNode,
			ad.state.chipsNode,
			ad.state.bodyNode
		]);

		/* the chips follow the status document (the Processing chip reads
		 * the queue-counter delta between ticks); the body rebuilds on
		 * availability flips and while the data-driven Overview is open.
		 * A busy tick is skipped: an in-flight Discard/Apply/Check must
		 * not race its own rebuild (the luci-app-wanguard pattern). */
		poll.add(function() {
			if (ad.state.busy)
				return;
			return ad.refresh().then(function() {
				ad.update();
			});
		}, 10);

		ad.update();
		return root;
	}
});
