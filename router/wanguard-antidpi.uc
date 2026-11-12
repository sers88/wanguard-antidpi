#!/usr/bin/ucode
// wanguard-antidpi - control CLI (ucode-first base, issue #67).
// Single control surface for the nfqws2 engine: the init script (a thin sh
// shim - the rc.common contract forces sh there) drives it, the container
// test matrix (#63) asserts against it, blockcheck sessions read the exact
// engine command line.
//
// Language policy: all router-side logic lives here, in ucode (see
// docs/ARCHITECTURE.md). POSIX sh remains only in the init shim and in the
// host/CI tooling that never runs on the router.
//
// Subcommands (ARGV):
//   version         package version stamp (default action)
//   engine-version  first line of `nfqws2 --version`
//   engine-cmdline  full nfqws2 argv, one argument per line (frozen contract:
//                   exactly what the init shim starts, byte-for-byte)
//   nft-render      print the rendered nft ruleset (template + UCI engine/
//                   tunnel options: qnum, fwmark, proxy_servers set elements)
//   nft-apply       apply the table (idempotent; DRYRUN-aware)
//   nft-flush       delete the table (idempotent; DRYRUN-aware)
//   mark-install    inject routing-mark into the mihomo config (issue #60):
//                   backup -> one root-level line -> mihomo -t -> live REST
//                   reload when mihomo is running; idempotent; DRYRUN-aware
//   mark-ensure     non-fatal mark-install used by the init shim (respects
//                   the no-mark disarm stamp)
//   mark-remove     restore the config (backup default, surgical line removal
//                   when no backup) + live reload; arms the disarm stamp so
//                   the next start does not re-inject; DRYRUN-aware
//   mark-status     machine-readable state: mark / install-on-start / backup /
//                   mihomo / config / api (one `key: value` per line)
//   tunnel-update   resolve tunnel.hosts (nslookup), refresh the resolver-
//                   managed proxy_resolved UCI list with per-IP expiry
//                   (state file), re-apply the table only when the set really
//                   changed and the table lives (issue #62); DRYRUN-aware
//   tunnel-status   machine-readable tunnel state (hosts/resolved/cron/table)
//   cron-install    ensure the periodic tunnel-update line in /etc/crontabs/
//                   root (busybox crond reloads changed files itself)
//   cron-remove     drop the cron line (service stop)
//   whitelist-refresh  render the merged domain set (whitelist.domains +
//                      domainlist sections, #82) into the engine hostlist file
//                   (issue #70); whitelist mode off -> removes the file
//                   (blanket mode); DRYRUN-aware
//   whitelist-reload   whitelist-refresh + SIGHUP to a running engine (nfqws2
//                   re-reads its lists on HUP - no restart, no dropped
//                   connections; verified against the pinned binary)
//   whitelist-status   machine-readable whitelist state
//   apply [--check]  idempotent orchestration behind the LuCI page (issue
//                   #77): mark-ensure -> tunnel-update -> nft-apply ->
//                   whitelist-refresh -> engine (restart-vs-SIGHUP per the
//                   #70 evidence: list content = HUP, strategy words =
//                   restart through the init script). Exit codes: 0 ok,
//                   1 validation failure, 2 partial (a non-fatal step kept
//                   a fallback). --check = read-only preflight (human or
//                   --json report); repeated apply without config changes
//                   = no-op
//   status [--json]  read-only state surface for the LuCI page (issue #76):
//                   service/engine/nft/tunnel/whitelist/mihomo/pending/events
//                   in one call; --json = one JSON document (stable keys),
//                   default = human key: value lines. Every surface degrades
//                   explicitly (null/false + a "degraded" reason in JSON) -
//                   the page renders "unavailable" from the same keys
//
// DRYRUN contract: WANGUARD_ANTIDPI_DRYRUN=1 makes every state-changing
// command print what it would do, touch nothing, exit 0. This is how the
// container matrix tests the CLI without live nft/queue state.
//
// Config: UCI /etc/config/wanguard-antidpi, sections engine and mihomo (see
// the shipped template). Unknown/missing options fall back to the published
// defaults. The mihomo REST secret is parsed from the mihomo config itself
// and passed to curl via a header file - never through argv.

'use strict';

import { access, popen, readfile, stat, writefile, unlink } from 'fs';
import * as uci from 'uci';

const BASE = '/usr/share/wanguard-antidpi';
const NFT_TEMPLATE = BASE + '/wanguard-antidpi.nft';
const TABLE = 'wanguard_antidpi';
const CONF = 'wanguard-antidpi';
const ENGINE = '/usr/bin/nfqws2';
const STAMP = BASE + '/version';

// mihomo routing-mark integration (issue #60): the scope mark is a frozen
// contract (docs/ARCHITECTURE.md) - it belongs to wanguard-antidpi and is
// not claimed by anything else on the system
const MIHOMO_BIN = '/usr/bin/mihomo';
const MARK_HEX = '0x10000000';
const MARK_DEC = '268435456';
const MARK_LINE = 'routing-mark: ' + MARK_DEC;
const BACKUP_SUFFIX = '.bak-wanguard-antidpi';
const NOSTAMP = BASE + '/no-mark';
const AUTH_TMP = '/tmp/wanguard-antidpi.auth';

// tunnel resolver updater (issue #62): the state file keeps a per-IP
// last-seen timestamp so entries that stop appearing in DNS answers age
// out (the tunnel daddr ROTATES - issue #61 finding), while the UCI list
// stays the single render source
const STATE = BASE + '/tunnel-resolved.state';
const CRONTAB = '/etc/crontabs/root';
const CRON_TAG = 'wanguard-antidpi-tunnel-update';

// SNI whitelist (issue #70): the engine refuses to start when the hostlist
// file is missing, and re-reads its lists on SIGHUP only (no mtime auto-
// reload) - both verified in the container against the pinned binary. The
// file must stay world-readable: the HUP-time reload happens under the
// dropped engine user.
const HOSTLIST = BASE + '/whitelist.hosts';
const INIT = '/etc/init.d/wanguard-antidpi';
const CLI_SELF = '/usr/bin/wanguard-antidpi';

function die(msg) {
	warn('wanguard-antidpi: ' + msg + '\n');
	exit(1);
}

function dryrun() {
	return getenv('WANGUARD_ANTIDPI_DRYRUN') == '1';
}

function load_config() {
	let s = uci.cursor().get_all(CONF, 'engine');
	if (type(s) != 'object')
		die('uci config section missing: ' + CONF + '.engine (is /etc/config/' + CONF + ' installed?)');
	let c = {
		qnum: (s.qnum == null) ? '300' : s.qnum,
		fwmark: (s.fwmark == null) ? '0x40000000' : s.fwmark,
		user: (s.user == null) ? 'daemon' : s.user,
		debug: (s.debug == null) ? '0' : s.debug,
		opt: (type(s.nfqws2_opt) == 'array') ? s.nfqws2_opt : []
	};
	// qnum is substituted into the nft ruleset and into shell commands - keep
	// it strictly numeric; fwmark goes into both the engine argv and the nft
	// anti-loop match, keep it a strict hex word (render-injection safety)
	if (!match(c.qnum, /^[0-9]+$/))
		die('config qnum must be numeric, got: ' + c.qnum);
	if (!match(c.fwmark, /^0x[0-9a-fA-F]+$/))
		die('config fwmark must be hex (0x...), got: ' + c.fwmark);
	return c;
}

function load_tunnel() {
	// soft section (issues #61/#62 contract): missing section/options render an
	// empty proxy set; entries are validated at render/update time
	let s = uci.cursor().get_all(CONF, 'tunnel');
	// numeric option with a published default; garbage falls back loudly
	let num = function(orig, def, name) {
		if (orig == null)
			return def;
		if (type(orig) != 'string' || match(orig, /^[0-9]+$/) == null) {
			warn('wanguard-antidpi: tunnel.' + name + ' is not numeric ("' +
				orig + '") - using the default ' + def + '\n');
			return def;
		}
		return orig;
	};
	return {
		proxy_servers: (s == null || type(s.proxy_servers) != 'array') ? [] : s.proxy_servers,
		proxy_resolved: (s == null || type(s.proxy_resolved) != 'array') ? [] : s.proxy_resolved,
		tunnel_hosts: (s == null || type(s.tunnel_hosts) != 'array') ? [] : s.tunnel_hosts,
		update_interval: num((s == null) ? null : s.update_interval, '6', 'update_interval'),
		expire_hours: num((s == null) ? null : s.expire_hours, '24', 'expire_hours')
	};
}

function load_profiles() {
	// named strategy profile sections (issue #84): refs go by the section
	// name (stable id), the label is editable; render order = section file
	// order (uci foreach). Missing section/options degrade softly - an empty
	// list means "no profiles" and keeps the legacy nfqws2_opt contract.
	let out = [];
	uci.cursor().foreach(CONF, 'profile', function(s) {
		// proto is UI metadata (tcp/udp/quic); the strategy words themselves
		// carry the --filter-tcp/--filter-udp flags on the render
		let proto = [];
		if (type(s.proto) == 'string') {
			let toks = split(s.proto, ' ');
			if (type(toks) == 'array') {
				for (let i = 0; i < length(toks); i++)
					if (length(toks[i]) > 0)
						push(proto, toks[i]);
			}
		}
		push(out, {
			id: s['.name'],
			name: (type(s.name) == 'string' && length(s.name) > 0) ? s.name : s['.name'],
			proto: proto,
			words: (type(s.strategy_words) == 'array') ? s.strategy_words : [],
			enabled: (s.enabled == null || s.enabled != '0') ? true : false
		});
	});
	return out;
}

function profile_strategy_words() {
	// the profile-driven strategy (issue #84): enabled sections in file
	// order, joined with --new separators; null = NO profile sections at all
	// (the legacy engine.nfqws2_opt renders verbatim - the r9 byte-golden
	// contract). Each word lands in the engine argv, so it must be a single
	// argv word: anything containing whitespace fails the render loudly
	// (named section in the message), not silently.
	let ps = load_profiles();
	if (length(ps) == 0)
		return null;
	let words = [];
	let any_words = false;
	for (let i = 0; i < length(ps); i++) {
		let p = ps[i];
		if (!p.enabled)
			continue;
		if (length(p.words) == 0) {
			warn('wanguard-antidpi: profile "' + p.id + '" is enabled but has no strategy words - skipped\n');
			continue;
		}
		if (any_words)
			push(words, '--new');
		any_words = true;
		for (let j = 0; j < length(p.words); j++) {
			let w = p.words[j];
			if (type(w) != 'string' || length(w) == 0 ||
			    index(w, ' ') >= 0 || index(w, '\t') >= 0)
				die('profile "' + p.id + '": strategy word "' + w +
					'" must be a single argv word (no whitespace)');
			push(words, w);
		}
	}
	if (!any_words) {
		warn('wanguard-antidpi: profile sections present but none renders strategy words - no-op strategy\n');
		return [];
	}
	return words;
}

function load_whitelist() {
	// soft section (issue #70, same contract as tunnel): a missing section is
	// the blanket mode (desync for every queued target). Only the literal '1'
	// enables whitelist mode - anything else is off, loudly when it is not
	// '0' either
	let s = uci.cursor().get_all(CONF, 'whitelist');
	let enabled = (s == null) ? null : s.enabled;
	if (enabled != null && enabled != '0' && enabled != '1') {
		warn('wanguard-antidpi: whitelist.enabled is not 0/1 ("' + enabled + '") - treating as disabled\n');
		enabled = '0';
	}
	return {
		enabled: enabled,
		domains: (s == null || type(s.domains) != 'array') ? [] : s.domains
	};
}

function valid_hostname(h) {
	// strict DNS hostname for shell exec via nslookup: letters/digits/hyphen
	// labels, at least two labels (single labels cannot resolve via DNS
	// anyway), 253-octet presentation limit
	if (h == null || length(h) == 0 || length(h) > 253)
		return false;
	return match(h, /^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/) != null;
}

function load_domainlists() {
	// named domainlist sections (issue #82, design §2): `config domainlist`
	// with an editable `name` label + a `domains` list. Soft: no sections =
	// the legacy-only whitelist of #70 (byte-identical render). The section
	// NAME is the stable id (policies reference it per design §2), `name` is
	// just the label.
	let lists = [];
	uci.cursor().foreach(CONF, 'domainlist', function(s) {
		push(lists, {
			sid: s['.name'],
			name: (s.name == null) ? '' : '' + s.name,
			domains: (type(s.domains) == 'array') ? s.domains : []
		});
	});
	return lists;
}

function whitelist_sources() {
	// the unmerged hostlist source set (diagnostic-safe: NO validation here,
	// so status surfaces can display broken configs without dying)
	let w = load_whitelist();
	return { enabled: w.enabled, legacy: w.domains, lists: load_domainlists() };
}

function whitelist_merged(src) {
	// legacy whitelist.domains UNION every domainlist section (#82), deduped,
	// canonical order - one pipeline shared by the render (engine_argv), the
	// hostlist file render (whitelist_refresh_run / apply_hostlist_wouldbe)
	// and the human whitelist-status surface
	let seen = {};
	let doms = [];
	let sets = [src.legacy];
	for (let li = 0; li < length(src.lists); li++)
		push(sets, src.lists[li].domains);
	for (let si = 0; si < length(sets); si++) {
		let list = sets[si];
		for (let i = 0; i < length(list); i++) {
			let d = list[i];
			if (seen[d] == null) {
				seen[d] = true;
				push(doms, d);
			}
		}
	}
	sort(doms);
	return doms;
}

function validate_whitelist_sources(src) {
	// loud per-source validation for the whitelist mode (render-injection
	// safety net behind the UI's inline checks); the die message carries the
	// source so a broken config names its list
	for (let i = 0; i < length(src.legacy); i++)
		if (!valid_hostname(src.legacy[i]))
			die('whitelist.domains entry is not a valid DNS hostname: "' + src.legacy[i] + '"');
	for (let li = 0; li < length(src.lists); li++)
		for (let i = 0; i < length(src.lists[li].domains); i++)
			if (!valid_hostname(src.lists[li].domains[i]))
				die('domainlist "' + src.lists[li].sid + '" entry is not a valid DNS hostname: "' + src.lists[li].domains[i] + '"');
}

// ---------------------------------------------------------------------------
// Policies (issue #86, design §1.2/§2/§3): ordered match -> action rules.
// `config policy` sections reference a domainlist (match scope) and render
// as FIRST nfqws2 profile blocks, before the global strategy catch-all;
// first match wins (nfqws2 profile semantics, verified in spike-75 §1.2).
//   action=strategy: the block carries the referenced profile's desync
//     words (the --filter-*/--payload words are EXCLUDED - the policy's own
//     proto drives the filters of the block, one filter source per block);
//   action=bypass: filters + hostlist and NO desync words - the engine
//     passes matching traffic unmodified (spike-75 §1.2 verdict);
//   action=none: the policy renders no block (falls through to the global
//     strategy like a disabled rule, but stays validated loudly).
// The order = `option priority` ascending (UCI section order is unstable
// under editing, design §2), ties keep the section file order. Tunnel/
// proxy exclusions stay ABOVE any policy: the nft set and the engine
// --ipset-exclude-ip are independent of the profile blocks ("only mihomo
// DIRECT eligible" - issue contract).
// ---------------------------------------------------------------------------

const POLICY_LISTS_DIR = BASE + '/lists';

function policy_hostlist_path(list_sid) {
	// one hostlist file per referenced domainlist section (design §3):
	// rendered by whitelist-refresh, consumed by the engine argv. The path
	// rides in argv, so the sid must be a safe argv word - section names
	// are UCI identifiers (letters/digits/underscore), but validate anyway:
	// anything unusual dies the render loudly instead of reaching argv.
	if (!match(list_sid, /^[A-Za-z0-9_]+$/))
		die('policy domainlist ref is not a safe section name: "' + list_sid + '"');
	return POLICY_LISTS_DIR + '/' + list_sid + '.hosts';
}

function load_policies() {
	// raw policy sections (diagnostic-safe: NO validation - status surfaces
	// display broken configs; validation happens at render time). Missing/
	// garbage priority falls back to the documented default (design §2:
	// step 10, UI renumbers; 100 = late) with a loud warn on garbage.
	let out = [];
	uci.cursor().foreach(CONF, 'policy', function(s) {
		let priority = '100';
		if (s.priority != null) {
			if (type(s.priority) == 'string' && match(s.priority, /^[0-9]+$/) != null)
				priority = s.priority;
			else
				warn('wanguard-antidpi: policy "' + s['.name'] + '" priority is not numeric ("' +
					s.priority + '") - using the default 100\n');
		}
		let proto = [];
		if (type(s.proto) == 'string') {
			let toks = split(s.proto, ' ');
			if (type(toks) == 'array') {
				for (let i = 0; i < length(toks); i++)
					if (length(toks[i]) > 0)
						push(proto, toks[i]);
			}
		}
		push(out, {
			id: s['.name'],
			name: (type(s.name) == 'string' && length(s.name) > 0) ? s.name : s['.name'],
			priority: priority,
			domainlist: (type(s.domainlist) == 'string') ? s.domainlist : '',
			proto: proto,
			device_group: (type(s.device_group) == 'string') ? s.device_group : '',
			action: (type(s.action) == 'string') ? s.action : '',
			profile: (type(s.profile) == 'string') ? s.profile : '',
			enabled: (s.enabled == null || s.enabled != '0') ? true : false
		});
	});
	return out;
}

function policy_proto_filters(proto) {
	// the proto tokens drive the block filters (design §3.1: one filter
	// source per block - the profile's own --filter words are excluded from
	// the strategy embedding). tcp -> the TLS path, udp|quic -> the QUIC
	// path (both ride UDP/443); the payload declarations follow the #64
	// canon types so the engine can parse the ClientHello for SNI matching.
	let words = [];
	let tcp = false, udp = false;
	for (let i = 0; i < length(proto); i++) {
		let t = proto[i];
		if (t == 'tcp')
			tcp = true;
		else if (t == 'udp' || t == 'quic')
			udp = true;
		else
			die('policy proto token must be tcp, udp or quic, got: "' + t + '"');
	}
	if (tcp) {
		push(words, '--filter-tcp=443');
		push(words, '--payload=tls_client_hello');
	}
	if (udp) {
		push(words, '--filter-udp=443');
		push(words, '--payload=quic_initial');
	}
	return words;
}

function policy_render() {
	// the ordered policy blocks for the engine argv (design §3): null when
	// NO enabled policy section exists (the pure profiles render of #84,
	// byte-identical contract). Enabled policies are validated loudly even
	// when they render no block (action=none): a broken ref must fail the
	// render with the policy named, never silently disappear.
	let ps = load_policies();
	let visible = [];
	for (let i = 0; i < length(ps); i++)
		if (ps[i].enabled)
			push(visible, ps[i]);
	if (length(visible) == 0)
		return null;
	// stable priority sort: ascending `priority`, ties keep the section
	// file order (a tiny insertion sort - ucode sort() is ASCII-only over
	// strings, no comparator contract to lean on)
	for (let i = 1; i < length(visible); i++) {
		let p = visible[i];
		let j = i - 1;
		while (j >= 0 && int(visible[j].priority) > int(p.priority)) {
			visible[j + 1] = visible[j];
			j--;
		}
		visible[j + 1] = p;
	}
	let lists = load_domainlists();
	let profiles = load_profiles();
	let blocks = [];
	let refd = {};
	let refd_order = [];
	for (let i = 0; i < length(visible); i++) {
		let p = visible[i];
		// match scope: the referenced domainlist must exist (refs go by the
		// SECTION name, design §2) - a policy without a scope would match
		// every packet of its proto and silently override the global order
		let dl = null;
		for (let li = 0; li < length(lists); li++)
			if (lists[li].sid == p.domainlist)
				dl = lists[li];
		if (dl == null)
			die('policy "' + p.id + '": domainlist ref "' + p.domainlist +
				'" does not exist (refs go by the section name)');
		if (refd[dl.sid] == null) {
			refd[dl.sid] = true;
			push(refd_order, dl);
		}
		// action: strategy | bypass | none; anything else is a broken
		// config that must fail the render loudly (issue contract)
		if (p.action != 'strategy' && p.action != 'bypass' && p.action != 'none')
			die('policy "' + p.id + '": action must be strategy, bypass or none, got: "' +
				((p.action == '') ? '(empty)' : p.action) + '"');
		let prof = null;
		if (p.action == 'strategy') {
			for (let pi = 0; pi < length(profiles); pi++)
				if (profiles[pi].id == p.profile)
					prof = profiles[pi];
			if (prof == null)
				die('policy "' + p.id + '": action=strategy but profile ref "' + p.profile +
					'" does not exist (refs go by the section name)');
		}
		if (p.action == 'none')
			continue; // validated above; renders no block (falls through)
		if (length(p.proto) == 0)
			die('policy "' + p.id + '": proto is empty - at least one of tcp/udp/quic is required');
		// the block: proto filters + payload, then the hostlist (block
		// start, the same position the whitelist binding uses), then the
		// desync part for strategy actions
		let words = policy_proto_filters(p.proto);
		push(words, '--hostlist=' + policy_hostlist_path(dl.sid));
		if (p.action == 'strategy') {
			for (let wi = 0; wi < length(prof.words); wi++) {
				let w = prof.words[wi];
				// the profile's own --filter-*/--payload words are excluded:
				// the block's filters come from the policy proto (one filter
				// source per block, design §3.1); every other word (desync
				// functions, wssize, ...) rides verbatim and stays a single
				// argv word (the #84 contract)
				if (index(w, '--filter-tcp=') == 0 || index(w, '--filter-udp=') == 0 ||
				    index(w, '--payload=') == 0)
					continue;
				if (type(w) != 'string' || length(w) == 0 ||
				    index(w, ' ') >= 0 || index(w, '\t') >= 0)
					die('policy "' + p.id + '" (profile "' + prof.id + '"): strategy word "' + w +
						'" must be a single argv word (no whitespace)');
				push(words, w);
			}
		}
		push(blocks, { policy: p.id, list: dl.sid, words: words });
	}
	return { blocks: blocks, lists: refd_order };
}

function policy_list_canonical(raw) {
	// the canonical file content source for one list: dedupe + ASCII sort
	// (the whitelist_merged convention, per-list instead of merged)
	let seen = {};
	let doms = [];
	for (let i = 0; i < length(raw); i++)
		if (seen[raw[i]] == null) {
			seen[raw[i]] = true;
			push(doms, raw[i]);
		}
	sort(doms);
	return doms;
}

function valid_addr_entry(e) {
	// strict 'a.b.c.d' or 'a.b.c.d/nn' - entries land inside a generated nft
	// file, so anything unusual must be rejected, not escaped
	if (e == null || length(e) == 0)
		return false;
	let host = e;
	let sl = index(e, '/');
	if (sl != null && sl >= 0) {
		let mask = substr(e, sl + 1);
		if (!match(mask, /^[0-9]+$/) || int(mask) > 32)
			return false;
		host = substr(e, 0, sl);
	}
	let parts = split(host, '.');
	if (length(parts) != 4)
		return false;
	for (let i = 0; i < 4; i++) {
		let p = parts[i];
		if (!match(p, /^[0-9]+$/) || length(p) > 3 || int(p) > 255)
			return false;
		if (length(p) > 1 && substr(p, 0, 1) == '0')
			return false; // no leading zeros: keeps the render canonical
	}
	return true;
}

function merge_proxy_entries(t) {
	// the rendered set = manual pins (tunnel.proxy_servers) UNION resolver-
	// managed answers (tunnel.proxy_resolved, issue #62); strict validation
	// on every entry (render-injection safety), dedupe, canonical order
	let seen = {};
	let els = [];
	let lists = [t.proxy_servers, t.proxy_resolved];
	for (let li = 0; li < length(lists); li++) {
		for (let i = 0; i < length(lists[li]); i++) {
			let e = lists[li][i];
			if (!valid_addr_entry(e))
				die('tunnel proxy entry is not a canonical IPv4/CIDR: "' + e + '"');
			if (seen[e] == null) {
				seen[e] = true;
				push(els, e);
			}
		}
	}
	sort(els);
	return els;
}

function cmd_version() {
	let v = readfile(STAMP);
	if (v == null)
		die('no version stamp installed: ' + STAMP);
	print('wanguard-antidpi ' + v);
}

function cmd_engine_version() {
	if (!access(ENGINE, 'x'))
		die('engine not installed: ' + ENGINE);
	let fp = popen(ENGINE + ' --version 2>/dev/null', 'r');
	let out = (fp != null) ? fp.read('all') : '';
	fp.close();
	let line = split(out, '\n')[0];
	if (length(line) == 0)
		die('engine produced no version output');
	print(line + '\n');
}

function engine_argv() {
	// the exact nfqws2 argv (without the binary path) the init shim starts;
	// cmd_engine_cmdline prints it one word per line (frozen contract), the
	// status surface re-reads it (issue #76)
	let c = load_config();
	// whitelist mode (issue #70/#82): strict validation at render time - the
	// hostlist file is a hard engine dependency (nfqws2 refuses to start
	// without it), and a half-enabled config must fail loudly here instead
	// of silently falling back to the blanket desync
	let src = whitelist_sources();
	let merged = [];
	if (src.enabled == '1') {
		validate_whitelist_sources(src);
		merged = whitelist_merged(src);
		if (length(merged) == 0)
			die('whitelist.enabled=1 but no domains are configured (whitelist.domains and every domainlist section are empty) - add domains or set whitelist.enabled to 0');
	}
	// gzipped lua is supported natively by nfqws2 (--lua-init=@<file>)
	let a = [
		'--qnum=' + c.qnum,
		'--fwmark=' + c.fwmark,
		'--user=' + c.user,
		'--lua-init=@' + BASE + '/lua/zapret-lib.lua.gz',
		'--lua-init=@' + BASE + '/lua/zapret-antidpi.lua.gz'
	];
	if (c.debug == '1')
		push(a, '--debug=1');
	// defense in depth (issues #62/#64): tunnel destinations are excluded at
	// the nft level (primary control) AND at the engine level - desync must
	// never touch tunnel traffic even when a rotated daddr reaches the queue
	// before the nft set is updated. Same merged set as the nft render
	// (validated, deduped, sorted); the CSV is a single safe argv word
	// (strict IPv4/CIDR entries cannot contain commas). Emitted only when the
	// set is non-empty: the default-config golden stays a 6-word no-op.
	let els = merge_proxy_entries(load_tunnel());
	if (length(els) > 0) {
		let csv = els[0];
		for (let i = 1; i < length(els); i++)
			csv = csv + ',' + els[i];
		push(a, '--ipset-exclude-ip=' + csv);
	}
	// whitelist mode emission (issue #70): --hostlist constrains desync to
	// the listed hosts (suffix match, subdomains auto apply). Needs strategy
	// words to make sense (nothing to constrain otherwise) - with an empty
	// strategy the default golden stays untouched. The hostlist binds PER
	// PROFILE (verified in the container: "profile N include hostlist"), so
	// it is re-emitted after every --new profile separator. The FILE content
	// is the merged source set (#82); the binding rides on the mode alone.
	// Strategy source (issue #84): profile sections REPLACE the legacy
	// engine.nfqws2_opt when present; with no profile sections the legacy
	// list renders verbatim and the r9 byte-golden contract stays untouched.
	let strategy = profile_strategy_words();
	if (strategy == null) {
		strategy = c.opt;
	}
	else if (length(c.opt) > 0) {
		warn('wanguard-antidpi: profile sections present - engine.nfqws2_opt (' +
			length(c.opt) + ' words) is IGNORED\n');
	}
	// Policies (issue #86): ordered match -> action blocks BEFORE the global
	// strategy catch-all (design §3; first match wins per nfqws2 profile
	// semantics). Each block scopes itself with its own --hostlist, so the
	// whitelist binding must NOT also constrain every block (whitelist mode
	// IS the single-policy special case - design §3): with rendered policy
	// blocks the whitelist binding is skipped loudly. A null render (no
	// enabled policies) keeps the #70/#82 binding byte-identical.
	let pol = policy_render();
	if (pol != null && length(pol.blocks) > 0 && src.enabled == '1')
		warn('wanguard-antidpi: policy blocks render their own hostlists - the whitelist binding (' +
			HOSTLIST + ') is IGNORED\n');
	let wl_emit = (src.enabled == '1' && length(strategy) > 0 &&
		(pol == null || length(pol.blocks) == 0));
	if (wl_emit)
		push(a, '--hostlist=' + HOSTLIST);
	// the policy blocks, then the catch-all, joined with --new separators.
	// The FIRST block continues the base segment (base words carry no
	// desync/filter words of their own - the spike-75 §1.2 and the #70
	// whitelist render both start the first profile right after the base
	// words): an empty leading segment would count as a filterless profile
	// that matches everything and wins first-match over every policy.
	// A separator is only emitted BETWEEN segments (no dangling --new).
	if (pol != null) {
		for (let bi = 0; bi < length(pol.blocks); bi++) {
			if (bi > 0)
				push(a, '--new');
			let bw = pol.blocks[bi].words;
			for (let wi = 0; wi < length(bw); wi++)
				push(a, bw[wi]);
		}
	}
	// strategy words verbatim: one word = one argv word (the shell word-split
	// contract is gone with the ucode base)
	for (let i = 0; i < length(strategy); i++) {
		if (i == 0 && (pol != null && length(pol.blocks) > 0))
			push(a, '--new');
		push(a, strategy[i]);
		if (wl_emit && strategy[i] == '--new' && i + 1 < length(strategy))
			push(a, '--hostlist=' + HOSTLIST);
	}
	return a;
}

function cmd_engine_cmdline() {
	print(ENGINE + '\n');
	let a = engine_argv();
	for (let i = 0; i < length(a); i++)
		print(a[i] + '\n');
}

function render_nft() {
	// substitutions (issue #61): @QNUM@ queue number, @FWMARK@ the desync
	// anti-loop mark (must equal the engine's --fwmark), @PROXY_ELEMENTS@
	// the rendered set elements for the tunnel exclusion (#62 fills them)
	let c = load_config();
	let t = load_tunnel();
	let tpl = readfile(NFT_TEMPLATE);
	if (tpl == null)
		die('nft template missing: ' + NFT_TEMPLATE);
	let els = merge_proxy_entries(t);
	// manual join: ucode join() returns null (2026.01.16)
	let elsline = '';
	for (let i = 0; i < length(els); i++)
		elsline += ((i > 0) ? ', ' : '') + els[i];
	let r = replace(tpl, /@QNUM@/g, c.qnum);
	r = replace(r, /@FWMARK@/g, c.fwmark);
	r = replace(r, /@PROXY_ELEMENTS@/g, (length(els) > 0) ? '\t\telements = { ' + elsline + ' }\n' : '');
	return r;
}

function cmd_nft_render() {
	print(render_nft());
}

function apply_table() {
	// render + apply; returns the nft exit code (0 = applied). Fixed tmp
	// name: the engine lifecycle is single-instance (procd) and the file is
	// unlinked right after nft -f consumed it. Callers decide logging/exit.
	let tmp = '/tmp/wanguard-antidpi.nft';
	writefile(tmp, render_nft());
	let rc = system('nft -f ' + tmp);
	unlink(tmp);
	return rc;
}

function cmd_nft_apply() {
	let c = load_config();
	if (dryrun()) {
		print('DRYRUN: would apply nft table inet ' + TABLE + ':\n');
		print(render_nft());
		return;
	}
	let rc = apply_table();
	if (rc == 0)
		system('logger -t wanguard-antidpi "nft table inet ' + TABLE + ' applied (queue ' + c.qnum + ')"');
	else
		system('logger -t wanguard-antidpi "nft apply FAILED for table inet ' + TABLE + ' (rc ' + rc + ')"');
	exit((rc == 0) ? 0 : 1);
}

function cmd_nft_flush() {
	let c = load_config();
	if (dryrun()) {
		print('DRYRUN: would delete nft table inet ' + TABLE + '\n');
		return;
	}
	// idempotent: a missing table is not an error on stop
	system('nft delete table inet ' + TABLE + ' 2>/dev/null');
	system('logger -t wanguard-antidpi "nft table inet ' + TABLE + ' flushed"');
}

// ---------------------------------------------------------------------------
// mihomo routing-mark integration (issue #60)
//
// The mark makes ALL mihomo egress (DIRECT relay and tunnel) visible to nft -
// the add-on's scope is built around it. Install: backup -> one root-level
// line in the mihomo YAML (never a rewrite) -> `mihomo -t` -> live reload via
// the mihomo REST API when mihomo is up. The reload recipe follows the
// SAFE_PATHS convention: PUT /configs?force=true only accepts paths under the
// mihomo workdir, so the edited config is copied there first and the copy is
// kept in sync for the next reload. Uninstall: apk has no uninstall scripts
// (verified: apk3 mkpkg rejects pre/post-uninstall), so mark-remove is the
// documented rollback step and arms a stamp file that keeps init's
// mark-ensure from re-injecting.
// ---------------------------------------------------------------------------

function load_mihomo() {
	// soft section: missing UCI section/options fall back to the published
	// defaults (the engine section above is the strict one)
	let s = uci.cursor().get_all(CONF, 'mihomo');
	return {
		conffile: (s == null || s.conffile == null) ? '/etc/mihomo/config.yaml' : s.conffile,
		workdir: (s == null || s.workdir == null) ? '/usr/share/mihomo' : s.workdir
	};
}

function sh_quote(s) {
	// POSIX single-quote escaping for shell exec'd via system()/popen()
	return "'" + replace(replace(s, /\\/g, '\\\\'), /'/g, "'\\''") + "'";
}

function json_str(s) {
	return '"' + replace(replace(s, /\\/g, '\\\\'), /"/g, '\\"') + '"';
}

function log(msg) {
	print('wanguard-antidpi: ' + msg + '\n');
	system('logger -t wanguard-antidpi ' + sh_quote(msg));
}

function root_key_of(line) {
	// 'routing-mark: 268435456' -> 'routing-mark'; null when the line is not
	// a root-level YAML mapping entry (indented, commented, empty, flow...)
	if (line == null || length(line) == 0)
		return null;
	let c0 = substr(line, 0, 1);
	if (c0 == ' ' || c0 == '\t' || c0 == '#')
		return null;
	let i = index(line, ':');
	if (i == null || i < 1)
		return null;
	let key = trim(substr(line, 0, i));
	return (match(key, /^[A-Za-z0-9_-]+$/) != null) ? key : null;
}

function find_root_opt(text, key) {
	// first root-level line defining `key`, or null
	let lines = split(text, '\n');
	for (let i = 0; i < length(lines); i++) {
		if (root_key_of(lines[i]) == key)
			return { idx: i, line: lines[i] };
	}
	return null;
}

function opt_value(line) {
	// scalar value of a mapping line with YAML quoting stripped
	let i = index(line, ':');
	if (i == null || i < 0)
		return null;
	let v = trim(substr(line, i + 1));
	if (length(v) >= 2) {
		let a = substr(v, 0, 1);
		let b = substr(v, length(v) - 1);
		if (a == b && (a == '"' || a == "'"))
			v = substr(v, 1, length(v) - 2);
	}
	return v;
}

function value_is_ours(v) {
	if (v == null)
		return false;
	return v == MARK_DEC || lc(v) == MARK_HEX;
}

function mark_state(text) {
	// returns { state: 'absent'|'installed'|'conflict', value }
	let cur = find_root_opt(text, 'routing-mark');
	if (cur == null)
		return { state: 'absent', value: null };
	let v = opt_value(cur.line);
	return { state: value_is_ours(v) ? 'installed' : 'conflict', value: v };
}

function mihomo_running() {
	return system('pidof mihomo >/dev/null 2>&1') == 0;
}

function api_endpoint(text) {
	// 'host:port' from the mihomo config's external-controller, normalized to
	// the loopback endpoint this CLI reloads; null when unusable for HTTP PUT
	let r = find_root_opt(text, 'external-controller');
	if (r == null)
		return null;
	let v = opt_value(r.line);
	if (v == null || length(v) == 0)
		return null;
	let slash = index(v, '/');
	if (slash != null && slash >= 0)
		return null; // unix-socket controllers are not supported here
	let i = rindex(v, ':');
	if (i == null)
		return null;
	let port = substr(v, i + 1);
	if (match(port, /^[0-9]+$/) == null)
		return null;
	return '127.0.0.1:' + port;
}

function check_write(path, res) {
	// writefile() returns null on failure silently - make it loud
	if (res == null)
		die('write failed: ' + path + ' (permissions? disk full?)');
	return res;
}

function validate_mihomo(m) {
	// `mihomo -t` with the real binary; on hosts without mihomo (test
	// containers, package-only setups) the single-line inject is structurally
	// trivial and validation is skipped - loudly
	if (!access(MIHOMO_BIN, 'x')) {
		log('mihomo binary not found - validation skipped (single root-level line inject)');
		return true;
	}
	let rc = system('mihomo -t -d ' + sh_quote(m.workdir) + ' -f ' + sh_quote(m.conffile) + ' >/dev/null 2>&1');
	if (rc == 0) {
		log('mihomo -t ok');
		return true;
	}
	log('mihomo -t FAILED (rc ' + rc + ')');
	return false;
}

function reload_mihomo(text, workdir) {
	// live reload via the REST API; the secret goes through a header FILE,
	// never through argv/ps. Returns true when mihomo confirmed the reload.
	let ep = api_endpoint(text);
	if (ep == null) {
		log('no usable external-controller in the mihomo config - reload skipped (mark applies on next mihomo restart)');
		return false;
	}
	system('mkdir -p ' + sh_quote(workdir));
	// SAFE_PATHS: PUT accepts only paths under the workdir - sync the copy
	// (kept there for the next reload, same as the manual recipe)
	check_write(workdir + '/config.yaml', writefile(workdir + '/config.yaml', text));
	let hdr = [];
	let sec = find_root_opt(text, 'secret');
	if (sec != null) {
		let sv = opt_value(sec.line);
		if (sv != null && length(sv) > 0)
			push(hdr, 'Authorization: Bearer ' + sv);
	}
	let body = sh_quote('{"path":' + json_str(workdir + '/config.yaml') + '}');
	let base = 'curl -sS -f -m 10 --connect-timeout 3 -X PUT ';
	if (length(hdr) > 0) {
		check_write(AUTH_TMP, writefile(AUTH_TMP, hdr[0] + '\n'));
		base += '-H @' + sh_quote(AUTH_TMP) + ' ';
	}
	// plain PUT first: applies the config and does not disturb live
	// connections (verified live: connections survive, mihomo logs
	// "Initial configuration complete"); force=true as the fallback for
	// cores that refuse a plain path reload
	let out = '';
	let rc = 1;
	let variant = 0;
	let f;
	for (f = 0; f < 2; f++) {
		variant = f;
		let url = 'http://' + ep + '/configs' + ((f == 1) ? '?force=true' : '');
		let fp = popen(base + '-d ' + body + ' ' + sh_quote(url) + ' 2>&1', 'r');
		out = (fp != null) ? fp.read('all') : '';
		rc = (fp != null) ? fp.close() : 1;
		if (rc == 0)
			break;
	}
	unlink(AUTH_TMP);
	if (rc == 0) {
		log('mihomo reloaded via REST (' + ep + ((variant == 1) ? ', force fallback' : '') + ((out == '') ? '' : ': ' + trim(out)) + ') - routing-mark active');
		return true;
	}
	log('mihomo reload FAILED (rc ' + rc + ')' + ((length(out) > 0) ? ': ' + trim(out) : '') + ' - mark applies on next mihomo restart');
	return false;
}

function join_lines(lines) {
	// ucode join() returns null here (2026.01.16) - join manually
	let out = '';
	for (let i = 0; i < length(lines); i++) {
		if (i > 0)
			out += '\n';
		out += lines[i];
	}
	return out;
}

function without_line(text, idx) {
	let lines = split(text, '\n');
	let out = [];
	for (let i = 0; i < length(lines); i++)
		if (i != idx)
			push(out, lines[i]);
	return join_lines(out);
}

function mark_dryrun(action, m) {
	let text = readfile(m.conffile);
	print('DRYRUN: mark-' + action + ' on ' + m.conffile + '\n');
	if (text == null) {
		print('DRYRUN: mihomo config missing - nothing to do (graceful no-op)\n');
		return;
	}
	let st = mark_state(text);
	print('DRYRUN: current routing-mark state: ' + st.state + ((st.value != null) ? ' (' + st.value + ')' : '') + '\n');
	if (action == 'install') {
		if (st.state == 'absent') {
			print('DRYRUN: would back up to ' + m.conffile + BACKUP_SUFFIX + ' (never overwriting an existing backup)\n');
			print('DRYRUN: would prepend ' + json_str(MARK_LINE) + ' as a root-level line\n');
			print('DRYRUN: would run mihomo -t' + (access(MIHOMO_BIN, 'x') ? '' : ' (skipped: no mihomo binary here)') + '\n');
			print('DRYRUN: would reload via REST ' + (mihomo_running() ? ('(mihomo running: ' + ((api_endpoint(text) != null) ? api_endpoint(text) : 'endpoint unknown') + ')') : '(skipped: mihomo not running)') + '\n');
		} else {
			print('DRYRUN: nothing to do (idempotent no-op for state ' + st.state + ')\n');
		}
	} else {
		print('DRYRUN: would restore from backup or surgically remove the injected line\n');
		print('DRYRUN: would validate + reload, and arm ' + NOSTAMP + ' (init stops re-injecting)\n');
	}
}

function cmd_mark_install(strict) {
	let m = load_mihomo();
	if (dryrun())
		return mark_dryrun('install', m);
	let text = readfile(m.conffile);
	if (text == null) {
		// graceful per contract: the add-on stays a no-op without mihomo
		log('mihomo config missing (' + m.conffile + ') - mark integration skipped (graceful no-op)');
		exit(0);
	}
	let st = mark_state(text);
	if (st.state == 'installed') {
		unlink(NOSTAMP); // explicit install re-arms auto-install
		log('routing-mark already installed - nothing to do');
		exit(0);
	}
	if (st.state == 'conflict') {
		let msg = 'routing-mark conflict: ' + m.conffile + ' already has "' + st.value + '" - the add-on needs ' + MARK_LINE + ' and never touches foreign values';
		if (strict)
			die(msg);
		warn('wanguard-antidpi: ' + msg + '\n');
		exit(0);
	}
	let backup = m.conffile + BACKUP_SUFFIX;
	if (!access(backup, 'r'))
		check_write(backup, writefile(backup, text)); // pre-inject original; never overwritten once present
	// root-level key order is free in YAML: prepending is the minimal,
	// deterministic one-line diff
	let newtext = MARK_LINE + '\n' + text;
	check_write(m.conffile, writefile(m.conffile, newtext));
	unlink(NOSTAMP);
	log('routing-mark ' + MARK_HEX + ' injected into ' + m.conffile + ' (backup: ' + backup + ')');
	if (!validate_mihomo(m)) {
		check_write(m.conffile, writefile(m.conffile, text)); // roll back the inject
		log('inject rolled back - config restored to the pre-inject content');
		exit(1);
	}
	if (mihomo_running()) {
		if (!reload_mihomo(newtext, m.workdir)) {
			if (strict)
				exit(1);
			return; // mark-ensure: non-fatal, applies on next mihomo restart
		}
	} else {
		log('mihomo not running - it will start with the mark (config already updated)');
	}
	exit(0);
}

function cmd_mark_ensure() {
	// init shim hook: non-fatal variant, respects the disarm stamp
	if (access(NOSTAMP, 'r')) {
		log('mark integration disabled (' + NOSTAMP + ' present - re-enable with mark-install) - skipped');
		exit(0);
	}
	cmd_mark_install(false);
}

function cmd_mark_remove() {
	let m = load_mihomo();
	if (dryrun())
		return mark_dryrun('remove', m);
	// removal always disarms auto-install (sticky rollback: a plain service
	// restart must not re-inject after an explicit remove)
	system('mkdir -p ' + sh_quote(BASE));
	check_write(NOSTAMP, writefile(NOSTAMP, 'disarmed by mark-remove\n'));
	let text = readfile(m.conffile);
	if (text == null) {
		log('mihomo config missing - nothing to remove (auto-install stays disarmed)');
		exit(0);
	}
	let st = mark_state(text);
	if (st.state == 'absent') {
		log('routing-mark not present - nothing to remove (auto-install stays disarmed)');
		exit(0);
	}
	let backup = m.conffile + BACKUP_SUFFIX;
	let btext = access(backup, 'r') ? readfile(backup) : null;
	let newtext;
	if (btext != null) {
		// spec default: the backup taken at install time is the pre-inject
		// original - restoring it reproduces that config byte-for-byte
		// (user edits made between install and remove are reverted by design;
		// documented in the README rollback section)
		newtext = btext;
		log('restoring ' + backup + ' (pre-install original)');
	} else {
		// fallback: drop exactly the injected root line
		newtext = without_line(text, find_root_opt(text, 'routing-mark').idx);
		log('no backup found - removing the injected line surgically');
	}
	check_write(m.conffile, writefile(m.conffile, newtext));
	log('routing-mark removed from ' + m.conffile);
	if (!validate_mihomo(m)) {
		check_write(m.conffile, writefile(m.conffile, text)); // roll back the removal
		log('removal rolled back - config restored to the pre-remove content');
		exit(1);
	}
	if (mihomo_running()) {
		if (!reload_mihomo(newtext, m.workdir))
			exit(1);
	} else {
		log('mihomo not running - the restored config applies on next start');
	}
	exit(0);
}

function cmd_mark_status() {
	let m = load_mihomo();
	let text = readfile(m.conffile);
	let st = { state: 'no-config', value: null };
	if (text != null)
		st = mark_state(text);
	print('mark: ' + st.state + ((st.state == 'conflict' && st.value != null) ? ' (' + st.value + ')' : '') + '\n');
	print('install-on-start: ' + (access(NOSTAMP, 'r') ? 'disabled' : 'enabled') + '\n');
	print('backup: ' + (access(m.conffile + BACKUP_SUFFIX, 'r') ? 'present' : 'absent') + '\n');
	print('mihomo: ' + (mihomo_running() ? 'running' : 'stopped') + '\n');
	print('config: ' + m.conffile + '\n');
	let ep = (text != null) ? api_endpoint(text) : null;
	print('api: ' + (ep != null ? ep : 'unknown') + '\n');
}


// ---------------------------------------------------------------------------
// tunnel exclusion resolver updater (issue #62)
//
// The nft set proxy_servers is rendered from UCI on every apply (#61
// contract) - the updater therefore maintains the UCI list, never the live
// set. The tunnel daddr ROTATES (issue #61 router finding: one hostname,
// different answers over time), so fresh answers REFRESH a per-IP timestamp
// in a state file and entries that stop appearing in DNS answers age out
// after tunnel.expire_hours. Resilience: when no host resolves, the last
// known set is kept untouched (exit 1, cron/init treat it as non-fatal).
// Triggers: every service start (init shim, best-effort) and periodically
// via cron (cron-install/cron-remove manage one tagged line in
// /etc/crontabs/root; busybox crond reloads changed crontab files itself).
// ---------------------------------------------------------------------------

function resolve_host(host) {
	// busybox nslookup output -> array of IPv4 answers; null on failure or
	// when the answer carries no IPv4 (NXDOMAIN goes to stderr, hence 2>&1;
	// the server header line 'Address:\t<ip>:53' is rejected by the strict
	// IPv4 check, CNAME tails are split off)
	let fp = popen('nslookup ' + sh_quote(host) + ' 2>&1', 'r');
	let out = (fp != null) ? fp.read('all') : '';
	let rc = (fp != null) ? fp.close() : -1;
	if (rc != 0)
		return null;
	let ips = [];
	let lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		let ln = lines[i];
		if (substr(ln, 0, 7) != 'Address')
			continue;
		let c = index(ln, ':');
		if (c == null || c < 0)
			continue;
		let rest = trim(substr(ln, c + 1));
		// first whitespace token only ('Address 1: ip cname'); busybox 1.30+
		// numbers the answers, older builds do not - both shapes parse
		let sp = index(rest, ' ');
		if (sp != null && sp > 0)
			rest = substr(rest, 0, sp);
		// plain A answers only - no CIDR can come out of DNS
		if (valid_addr_entry(rest) && index(rest, '/') < 0)
			push(ips, rest);
	}
	return (length(ips) > 0) ? ips : null;
}

function load_state() {
	// '<ip> <epoch>' lines -> { ip: epoch }; garbage lines ignored
	let m = {};
	let txt = readfile(STATE);
	if (txt == null)
		return m;
	let lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		let ln = trim(lines[i]);
		if (length(ln) == 0 || substr(ln, 0, 1) == '#')
			continue;
		let sp = index(ln, ' ');
		if (sp == null || sp < 1)
			continue;
		let ip = substr(ln, 0, sp);
		let ts = trim(substr(ln, sp + 1));
		if (valid_addr_entry(ip) && index(ip, '/') < 0 && match(ts, /^[0-9]+$/) != null)
			m[ip] = int(ts);
	}
	return m;
}

function save_state(m) {
	// sorted '<ip> <epoch>' lines (deterministic; small file, single writer)
	let ips = [];
	for (let k in m)
		push(ips, k);
	sort(ips);
	let txt = '';
	for (let i = 0; i < length(ips); i++)
		txt += ips[i] + ' ' + m[ips[i]] + '\n';
	check_write(STATE, writefile(STATE, txt));
}

function index_of(arr, v) {
	for (let i = 0; i < length(arr); i++)
		if (arr[i] == v)
			return i;
	return -1;
}

function write_resolved_list(ips) {
	// persist the resolver-managed UCI list. The ucode cursor.add() of this
	// build cannot create NAMED sections (verified 2026-11-02: it returns
	// null and creates nothing) - when the user deleted the tunnel section,
	// the uci CLI binary recreates it first. Empty list -> delete the option.
	if (uci.cursor().get_all(CONF, 'tunnel') == null) {
		system('uci set ' + sh_quote(CONF) + '.tunnel=tunnel');
		system('uci commit ' + sh_quote(CONF));
	}
	let ctx = uci.cursor();
	if (length(ips) > 0)
		ctx.set(CONF, 'tunnel', 'proxy_resolved', ips);
	else
		ctx.delete(CONF, 'tunnel', 'proxy_resolved');
	ctx.save(CONF);
	ctx.commit(CONF);
	// verify-after-write: ucode uci failures are silent (null returns)
	let chk = uci.cursor().get_all(CONF, 'tunnel');
	let got = (chk == null || type(chk.proxy_resolved) != 'array') ? [] : chk.proxy_resolved;
	if (length(got) != length(ips))
		die('tunnel.proxy_resolved write verification failed');
	for (let i = 0; i < length(ips); i++)
		if (got[i] != ips[i])
			die('tunnel.proxy_resolved write verification failed');
}

function cmd_tunnel_update() {
	let t = load_tunnel();
	if (length(t.tunnel_hosts) == 0) {
		print('wanguard-antidpi: no tunnel hosts configured - nothing to resolve\n');
		exit(0);
	}
	for (let i = 0; i < length(t.tunnel_hosts); i++)
		if (!valid_hostname(t.tunnel_hosts[i]))
			die('tunnel.tunnel_hosts entry is not a valid DNS hostname: "' + t.tunnel_hosts[i] + '"');
	let now = time();
	let expire = int(t.expire_hours) * 3600;

	// resolve every host; a fresh answer refreshes that IP's timestamp
	let fresh = {};
	let failed = 0;
	for (let i = 0; i < length(t.tunnel_hosts); i++) {
		let h = t.tunnel_hosts[i];
		let ips = resolve_host(h);
		if (ips == null) {
			warn('wanguard-antidpi: tunnel host did not resolve: ' + h + '\n');
			failed++;
			continue;
		}
		for (let j = 0; j < length(ips); j++)
			fresh[ips[j]] = true;
	}
	if (failed == length(t.tunnel_hosts)) {
		if (dryrun()) {
			print('DRYRUN: no tunnel host resolved - would keep the last known set (exit 1)\n');
			exit(0);
		}
		warn('wanguard-antidpi: no tunnel host resolved - keeping the last known set\n');
		system('logger -t wanguard-antidpi "tunnel-update: no host resolved - keeping the last known set"');
		exit(1);
	}

	let st = load_state();
	// adopt entries already in UCI but missing from the state (first run,
	// state file removed): they expire one window after adoption
	for (let i = 0; i < length(t.proxy_resolved); i++)
		if (valid_addr_entry(t.proxy_resolved[i]) && st[t.proxy_resolved[i]] == null)
			st[t.proxy_resolved[i]] = now;
	for (let k in fresh)
		st[k] = now;
	// expiry: entries not re-observed within the window drop out
	let surv = [];
	for (let k in st)
		if (expire == 0 || now - st[k] < expire)
			push(surv, k);
	sort(surv);

	// compare against the current UCI list (garbage entries cannot come back:
	// the render would die on them, so they are treated as absent here)
	let cur = [];
	for (let i = 0; i < length(t.proxy_resolved); i++)
		if (valid_addr_entry(t.proxy_resolved[i]))
			push(cur, t.proxy_resolved[i]);
	sort(cur);
	let changed = length(surv) != length(cur);
	if (!changed)
		for (let i = 0; i < length(surv); i++)
			if (surv[i] != cur[i]) {
				changed = true;
				break;
			}

	if (dryrun()) {
		print('DRYRUN: hosts=' + length(t.tunnel_hosts) + ' failed=' + failed +
			' fresh=' + length(fresh) + ' survivors=' + length(surv) +
			' current=' + length(cur) + '\n');
		if (changed)
			print('DRYRUN: would write tunnel.proxy_resolved (' + length(surv) + ' entries) and re-apply the table when it lives\n');
		else
			print('DRYRUN: set unchanged - nothing to write\n');
		exit(0);
	}

	// the state file is refreshed on every run (timestamps), set or not -
	// but only with the surviving entries (expired ones must not accumulate
	// forever)
	let st2 = {};
	for (let i = 0; i < length(surv); i++)
		st2[surv[i]] = st[surv[i]];
	save_state(st2);
	if (!changed) {
		print('wanguard-antidpi: tunnel set unchanged (' + length(cur) + ' entries) - nothing to do\n');
		exit(0);
	}

	let added = 0;
	let dropped = 0;
	for (let i = 0; i < length(surv); i++)
		if (index_of(cur, surv[i]) < 0)
			added++;
	for (let i = 0; i < length(cur); i++)
		if (index_of(surv, cur[i]) < 0)
			dropped++;
	write_resolved_list(surv);
	let msg = 'tunnel set updated (+' + added + '/-' + dropped + ' -> ' + length(surv) + ' entries)';
	if (system('nft list table inet ' + TABLE + ' >/dev/null 2>&1') == 0) {
		let rc = apply_table();
		msg += (rc == 0) ? ' - table re-applied' : ' - TABLE APPLY FAILED (rc ' + rc + ')';
		system('logger -t wanguard-antidpi ' + sh_quote(msg));
		print('wanguard-antidpi: ' + msg + '\n');
		if (rc != 0)
			exit(1);
	} else {
		msg += ' - table absent, applies on next start';
		system('logger -t wanguard-antidpi ' + sh_quote(msg));
		print('wanguard-antidpi: ' + msg + '\n');
	}
	exit(0);
}

// ---- cron trigger ----

function cron_line(interval) {
	// busybox crond rereads changed /etc/crontabs/* files itself; stdout is
	// discarded - the updater reports via syslog (logger) on its own
	return '0 */' + interval + ' * * * /usr/bin/wanguard-antidpi tunnel-update >/dev/null 2>&1 # ' + CRON_TAG;
}

function read_crontab_lines() {
	let txt = readfile(CRONTAB);
	return (txt == null) ? [] : split(txt, '\n');
}

function split_cron_lines(lines) {
	// ours (tagged) vs everything else - foreign lines are never touched
	let ours = [];
	let kept = [];
	for (let i = 0; i < length(lines); i++) {
		if (index(lines[i], CRON_TAG) >= 0)
			push(ours, lines[i]);
		else
			push(kept, lines[i]);
	}
	return { kept: kept, ours: ours };
}

function write_crontab_lines(lines) {
	// drop trailing empty lines, single trailing newline
	let n = length(lines);
	while (n > 0 && length(trim(lines[n - 1])) == 0)
		n--;
	let txt = '';
	for (let i = 0; i < n; i++)
		txt += lines[i] + '\n';
	check_write(CRONTAB, writefile(CRONTAB, txt));
}

function cmd_cron_install() {
	let t = load_tunnel();
	let want = cron_line(t.update_interval);
	let parts = split_cron_lines(read_crontab_lines());
	if (dryrun()) {
		if (length(t.tunnel_hosts) == 0 || t.update_interval == '0')
			print('DRYRUN: would remove the ' + CRON_TAG + ' cron line if present (' + length(parts.ours) + ' found)\n');
		else
			print('DRYRUN: would ensure the cron line: ' + want + '\n');
		exit(0);
	}
	// nothing to schedule (no hosts, or periodic updates disabled by config):
	// make sure no stale line survives
	if (length(t.tunnel_hosts) == 0) {
		if (length(parts.ours) == 0) {
			print('wanguard-antidpi: no tunnel hosts - no cron entry\n');
			exit(0);
		}
		write_crontab_lines(parts.kept);
		log('no tunnel hosts configured - removed the stale cron entry');
		exit(0);
	}
	if (t.update_interval == '0') {
		if (length(parts.ours) == 0) {
			print('wanguard-antidpi: periodic updates disabled (update_interval=0) - no cron entry\n');
			exit(0);
		}
		write_crontab_lines(parts.kept);
		log('periodic updates disabled (update_interval=0) - removed the cron entry');
		exit(0);
	}
	if (length(parts.ours) == 1 && parts.ours[0] == want) {
		print('wanguard-antidpi: cron entry already up to date\n');
		exit(0);
	}
	push(parts.kept, want);
	write_crontab_lines(parts.kept);
	log('cron schedule ensured: tunnel-update every ' + t.update_interval + 'h');
	exit(0);
}

function cmd_cron_remove() {
	if (dryrun()) {
		print('DRYRUN: would remove ' + CRON_TAG + ' cron lines from ' + CRONTAB + '\n');
		exit(0);
	}
	let parts = split_cron_lines(read_crontab_lines());
	if (length(parts.ours) == 0) {
		print('wanguard-antidpi: no cron entry - nothing to remove\n');
		exit(0);
	}
	write_crontab_lines(parts.kept);
	system('logger -t wanguard-antidpi "cron entry removed"');
	print('wanguard-antidpi: cron entry removed\n');
	exit(0);
}

function cmd_tunnel_status() {
	let t = load_tunnel();
	let j = function(list) {
		let out = '';
		for (let i = 0; i < length(list); i++)
			out += ((i > 0) ? ', ' : '') + list[i];
		return (length(list) > 0) ? out : 'none';
	};
	let parts = split_cron_lines(read_crontab_lines());
	print('hosts: ' + j(t.tunnel_hosts) + '\n');
	print('static pins: ' + j(t.proxy_servers) + '\n');
	print('resolved: ' + j(t.proxy_resolved) + '\n');
	print('update interval: ' + t.update_interval + 'h\n');
	print('expire: ' + t.expire_hours + 'h\n');
	let crondesc = 'absent';
	if (length(parts.ours) > 0) {
		let h = index(parts.ours[0], '#');
		crondesc = (h != null && h > 0) ? trim(substr(parts.ours[0], 0, h)) : parts.ours[0];
	}
	print('cron: ' + crondesc + '\n');
	print('table: ' + ((system('nft list table inet ' + TABLE + ' >/dev/null 2>&1') == 0) ? 'present' : 'absent') + '\n');
	let st = load_state();
	let n = 0;
	for (let k in st)
		n++;
	print('state entries: ' + n + '\n');
	print('state file: ' + STATE + '\n');
}


// ---------------------------------------------------------------------------
// SNI whitelist (issue #70)
//
// Desync is applied ONLY to the listed hosts (SNI-based, suffix match with
// subdomains auto apply) instead of every queued target. Config is UCI
// `whitelist` (soft section, same contract as tunnel) PLUS named
// `domainlist` sections (issue #82, design §2) - the rendered file
// /usr/share/wanguard-antidpi/whitelist.hosts (the engine's --hostlist)
// holds the merged set: legacy whitelist.domains UNION every domainlist.
// Facts verified in the container against the pinned binary:
//   - a MISSING hostlist file keeps the engine from starting (the init shim
//     therefore refreshes the file before the engine start; a failed refresh
//     keeps the previous file, and a truly absent file fails the start
//     loudly instead of silently desyncing everything)
//   - there is no mtime auto-reload: list changes reach a running engine via
//     SIGHUP ("Lists will be reloaded", queue and connections untouched);
//     the reload happens under the dropped engine user, so the file must
//     stay world-readable
//   - an empty hostlist file starts fine but matches nothing (never produced
//     here: enabled+empty is rejected at render time, disabled removes the
//     file)
// ---------------------------------------------------------------------------

function whitelist_file_refresh() {
	let src = whitelist_sources();
	if (src.enabled != '1') {
		if (dryrun()) {
			print('DRYRUN: whitelist mode off (enabled=' + ((src.enabled == null) ? '0' : src.enabled) +
				') - would remove ' + HOSTLIST + ' if present (blanket mode)\n');
			return;
		}
		if (access(HOSTLIST, 'r')) {
			unlink(HOSTLIST);
			log('whitelist mode off - removed ' + HOSTLIST + ' (blanket mode)');
		} else {
			print('wanguard-antidpi: whitelist mode off - no hostlist file\n');
		}
		return;
	}
	// whitelist mode (#82): validate every source loudly, then render the
	// merged set (legacy whitelist.domains UNION domainlist sections)
	validate_whitelist_sources(src);
	let doms = whitelist_merged(src);
	if (length(doms) == 0) {
		// enabled with an empty source set: the rendered argv still carries
		// --hostlist (engine_argv dies on this config, so a restart fails
		// loudly); removing the file keeps that failure honest instead of
		// desyncing with a stale list
		if (dryrun()) {
			print('DRYRUN: whitelist mode on but no domains configured - would remove ' + HOSTLIST + '\n');
			return;
		}
		if (access(HOSTLIST, 'r')) {
			unlink(HOSTLIST);
			log('no domains configured - removed ' + HOSTLIST + ' (the engine refuses to start until domains are added or the mode is set to 0)');
		} else {
			print('wanguard-antidpi: no domains configured - no hostlist file\n');
		}
		return;
	}
	// dedupe + canonical order: the file content is deterministic (already
	// merged by whitelist_merged)
	let txt = join_lines(doms) + '\n';
	if (dryrun()) {
		print('DRYRUN: would write ' + HOSTLIST + ' (' + length(doms) + ' hosts):\n');
		for (let i = 0; i < length(doms); i++)
			print('DRYRUN:   ' + doms[i] + '\n');
		return;
	}
	system('mkdir -p ' + sh_quote(BASE));
	check_write(HOSTLIST, writefile(HOSTLIST, txt));
	// verify-after-write (ucode failures are silent) and keep the file
	// world-readable: the SIGHUP-time reload runs as the dropped engine user
	if (readfile(HOSTLIST) != txt)
		die('hostlist write verification failed: ' + HOSTLIST);
	if (system('chmod 644 ' + sh_quote(HOSTLIST)) != 0)
		die('chmod 644 failed on ' + HOSTLIST + ' (the engine user must be able to re-read it on SIGHUP)');
	log('whitelist.hosts written (' + length(doms) + ' hosts)');
}

function policy_lists_wouldbe_state() {
	// the snapshot policy_lists_refresh would leave on disk right now
	// (canonical content per referenced list) - the DRYRUN counterpart of
	// policy_lists_disk_state
	let pol = policy_render();
	if (pol == null || length(pol.lists) == 0)
		return '';
	let parts = [];
	for (let i = 0; i < length(pol.lists); i++) {
		let doms = policy_list_canonical(pol.lists[i].domains);
		let txt = join_lines(doms) + '\n';
		push(parts, policy_hostlist_path(pol.lists[i].sid) + '\x00' + txt);
	}
	// manual join: ucode join() returns null (2026.01.16)
	let out = '';
	for (let i = 0; i < length(parts); i++) {
		if (i > 0)
			out += '\x01';
		out += parts[i];
	}
	return out;
}

function policy_lists_disk_state() {
	// a change-detection snapshot of every referenced policy list file
	// (apply compares before/after the refresh to pick reload vs restart);
	// an absent file carries an explicit marker so a created/deleted file
	// registers as a change
	let pol = policy_render();
	if (pol == null || length(pol.lists) == 0)
		return '';
	let parts = [];
	for (let i = 0; i < length(pol.lists); i++) {
		let path = policy_hostlist_path(pol.lists[i].sid);
		let content = access(path, 'r') ? readfile(path) : '<absent>';
		push(parts, path + '\x00' + content);
	}
	// manual join: ucode join() returns null (2026.01.16)
	let out = '';
	for (let i = 0; i < length(parts); i++) {
		if (i > 0)
			out += '\x01';
		out += parts[i];
	}
	return out;
}

function policy_lists_refresh() {
	// per-policy hostlist files (issue #86, design §3): one file per
	// REFERENCED domainlist section under BASE/lists, content = that list's
	// domains only (dedupe + canonical order + LF, 0644 + verify-after-
	// write - the whitelist.hosts conventions). The engine consumes the
	// paths from the policy argv, so a missing file keeps it from starting
	// (the #70 loud-fail contract); this refresh runs before every engine
	// start through the init shim. A broken enabled policy dies HERE loudly
	// (validation before any write). No enabled policies = silent no-op
	// (the no-policy config keeps its byte-identical behavior surface).
	let pol = policy_render();
	if (pol == null || length(pol.lists) == 0)
		return;
	for (let li = 0; li < length(pol.lists); li++) {
		let list = pol.lists[li];
		let doms = (type(list.domains) == 'array') ? list.domains : [];
		for (let i = 0; i < length(doms); i++)
			if (!valid_hostname(doms[i]))
				die('policy list "' + list.sid + '" entry is not a valid DNS hostname: "' + doms[i] + '"');
	}
	if (dryrun()) {
		for (let li = 0; li < length(pol.lists); li++) {
			let doms = policy_list_canonical(pol.lists[li].domains);
			print('DRYRUN: would write ' + policy_hostlist_path(pol.lists[li].sid) +
				' (' + length(doms) + ' hosts)\n');
		}
		return;
	}
	system('mkdir -p ' + sh_quote(POLICY_LISTS_DIR));
	for (let li = 0; li < length(pol.lists); li++) {
		let doms = policy_list_canonical(pol.lists[li].domains);
		let path = policy_hostlist_path(pol.lists[li].sid);
		let txt = join_lines(doms) + '\n';
		check_write(path, writefile(path, txt));
		if (readfile(path) != txt)
			die('policy list write verification failed: ' + path);
		if (system('chmod 644 ' + sh_quote(path)) != 0)
			die('chmod 644 failed on ' + path + ' (the engine user must be able to re-read it on SIGHUP)');
		log('policy list ' + pol.lists[li].sid + '.hosts written (' + length(doms) + ' hosts)');
	}
}

function whitelist_refresh_run() {
	whitelist_file_refresh();
	policy_lists_refresh();
}

function cmd_whitelist_refresh() {
	whitelist_refresh_run();
	exit(0);
}

function engine_pid() {
	let fp = popen('pidof nfqws2 2>/dev/null', 'r');
	let out = trim((fp != null) ? fp.read('all') : '');
	if (fp != null)
		fp.close();
	return out;
}

function cmd_whitelist_reload() {
	whitelist_refresh_run();
	if (dryrun()) {
		print('DRYRUN: would signal a running engine (kill -HUP) to reload its lists\n');
		exit(0);
	}
	let pid = engine_pid();
	if (length(pid) == 0) {
		log('whitelist list updated - engine not running, applies on next start');
		exit(0);
	}
	// SIGHUP: nfqws2 re-reads its hostlist/ipset files without dropping the
	// queue or live connections (verified against the pinned binary)
	if (system('kill -HUP ' + pid) != 0)
		die('failed to signal the engine (' + pid + ')');
	log('whitelist list updated - SIGHUP sent to the engine (pid ' + pid + ') to reload lists');
	exit(0);
}

function cmd_whitelist_status() {
	let src = whitelist_sources();
	let merged = whitelist_merged(src);
	let j = function(list) {
		let out = '';
		for (let i = 0; i < length(list); i++)
			out += ((i > 0) ? ', ' : '') + list[i];
		return (length(list) > 0) ? out : 'none';
	};
	print('enabled: ' + ((src.enabled == '1') ? '1' : '0') + '\n');
	print('domains: ' + j(src.legacy) + '\n');
	// named domainlist sections (issue #82): the rest of the merged set
	let list_total = 0;
	for (let li = 0; li < length(src.lists); li++)
		list_total += length(src.lists[li].domains);
	print('domainlists: ' + length(src.lists) + ' section(s), ' + list_total + ' entr(ies)\n');
	print('merged: ' + length(merged) + ' unique host(s)\n');
	if (access(HOSTLIST, 'r')) {
		let lines = split(readfile(HOSTLIST), '\n');
		let n = 0;
		for (let i = 0; i < length(lines); i++)
			if (length(trim(lines[i])) > 0)
				n++;
		print('file: present (' + n + ' hosts)\n');
	} else {
		print('file: absent\n');
	}
	let c = load_config();
	let wl_argv = (src.enabled == '1' && length(merged) > 0 && length(c.opt) > 0);
	print('engine argv: ' + (wl_argv ? '--hostlist included' : 'not included') + '\n');
	let pid = engine_pid();
	print('engine: ' + ((length(pid) > 0) ? 'running (pid ' + pid + ')' : 'not running') + '\n');
}


// ---------------------------------------------------------------------------
// status (issue #76): the read-only state surface behind the LuCI page.
// ONE subcommand instead of a pile of exec calls from the browser. Every
// surface degrades explicitly - null/false data plus an entry in the
// "degraded" map - and nothing throws on missing surfaces: the page renders
// its "unavailable" states from the same stable keys. Read-only by design:
// no DRYRUN interaction, no config writes, no signaling.
//
// The JSON document (one line, printf %J) mirrors the DESIGN.md contract
// (private tracker, spike-75): service/engine/nft/tunnel/whitelist/mihomo/
// pending/events. The default (non-JSON) output is a human key: value view
// for ops - mark-status style.
// ---------------------------------------------------------------------------

function status_pidof(bin) {
	let fp = popen('pidof ' + sh_quote(bin) + ' 2>/dev/null', 'r');
	let out = trim((fp != null) ? fp.read('all') : '');
	if (fp != null)
		fp.close();
	return (length(out) > 0) ? out : null;
}

function status_proc_cmdline(pid) {
	let txt = readfile('/proc/' + pid + '/cmdline');
	if (txt == null)
		return null;
	let parts = split(txt, '\0');
	let argv = [];
	for (let i = 0; i < length(parts); i++)
		if (length(parts[i]) > 0)
			push(argv, parts[i]);
	return (length(argv) > 0) ? argv : null;
}

function status_proc_uptime(pid, sysup) {
	// seconds since the process started, from /proc/<pid>/stat field 22
	// (starttime, jiffies). Jiffies-per-second is not detectable portably -
	// HZ=100 is the OpenWrt default; a nonsensical result (negative or larger
	// than the system uptime) degrades to null instead of lying to the UI.
	let st = readfile('/proc/' + pid + '/stat');
	if (st == null || sysup == null)
		return null;
	let fields = split(st, ' ');
	if (length(fields) < 22 || match(fields[21], /^[0-9]+$/) == null)
		return null;
	let up = sysup - int(fields[21]) / 100;
	if (up < 0 || up > sysup + 5)
		return null;
	return int(up);
}

function status_service_info() {
	let enabled = false;
	let fp = popen('ls /etc/rc.d/ 2>/dev/null', 'r');
	let out = (fp != null) ? fp.read('all') : '';
	if (fp != null)
		fp.close();
	let lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++)
		if (match(lines[i], /^S[0-9]+wanguard-antidpi$/) != null)
			enabled = true;
	let pid = status_pidof('nfqws2');
	let sysup = null;
	let uptxt = readfile('/proc/uptime');
	if (uptxt != null) {
		let u = trim(split(trim(uptxt), ' ')[0]);
		let dot = index(u, '.');
		if (dot != null && dot > 0)
			u = substr(u, 0, dot);
		if (match(u, /^[0-9]+$/) != null)
			sysup = int(u);
	}
	return {
		enabled: enabled,
		pid: pid,
		uptime_s: (pid != null) ? status_proc_uptime(pid, sysup) : null
	};
}

function status_engine_info() {
	// the RENDERED argv (engine_argv) is the source of truth for what the
	// init shim starts; the running process cmdline is captured alongside so
	// the UI can show a drift between configured and live
	let c = load_config();
	let argv = engine_argv();
	let newc = 0;
	let lists = [];
	let seen = {};
	for (let i = 0; i < length(argv); i++) {
		if (argv[i] == '--new')
			newc++;
		if (substr(argv[i], 0, 11) == '--hostlist=' && seen[argv[i]] == null) {
			seen[argv[i]] = true;
			push(lists, substr(argv[i], 11));
		}
	}
	// no strategy words at all = the graceful no-op (zero profiles); each
	// --new starts the next profile set. The word count comes from the
	// STRATEGY SOURCE (profiles replace the legacy opt, issue #84), not
	// from c.opt alone.
	let psecs = load_profiles();
	let strategy = profile_strategy_words();
	if (strategy == null)
		strategy = c.opt;
	let profiles = (length(strategy) == 0) ? 0 : newc + 1;
	let ver = null;
	if (access(ENGINE, 'x')) {
		let fp = popen(ENGINE + ' --version 2>/dev/null', 'r');
		let out = (fp != null) ? fp.read('all') : '';
		if (fp != null)
			fp.close();
		ver = trim(split(out, '\n')[0]);
		if (length(ver) == 0)
			ver = null;
	}
	let pid = status_pidof('nfqws2');
	let sections = [];
	for (let i = 0; i < length(psecs); i++)
		push(sections, {
			id: psecs[i].id,
			name: psecs[i].name,
			proto: psecs[i].proto,
			enabled: psecs[i].enabled,
			words: length(psecs[i].words)
		});
	// policy surfaces (issue #86): the raw sections (UI table) + the count
	// of RENDERED policy blocks (first-match blocks ahead of the catch-all).
	// The render validates loudly (a broken policy dies like a broken
	// profile word does) - status stays consistent with the argv it reports.
	let polsecs = load_policies();
	let pol = policy_render();
	let psections = [];
	for (let i = 0; i < length(polsecs); i++)
		push(psections, {
			id: polsecs[i].id,
			name: polsecs[i].name,
			priority: polsecs[i].priority,
			domainlist: polsecs[i].domainlist,
			proto: polsecs[i].proto,
			action: polsecs[i].action,
			profile: polsecs[i].profile,
			device_group: polsecs[i].device_group,
			enabled: polsecs[i].enabled
		});
	return {
		pid: pid,
		version: ver,
		profiles: profiles,
		profile_sections: sections,
		policies: (pol == null) ? 0 : length(pol.blocks),
		policy_sections: psections,
		hostlists: lists,
		running_argv: (pid != null) ? status_proc_cmdline(pid) : null
	};
}

function status_nft_counters() {
	// the template owns exactly two counter statements (tcp 443 rule first,
	// udp 443 second - frozen order, test-golden locked). Text `nft list`
	// is NOT parseable for this: a zero counter is printed as a bare
	// `counter` word without values (same family as the md5-vs-counters
	// gotcha), so the machine-readable `nft -j` JSON is parsed instead.
	// Returns null when the table is absent.
	if (system('nft list table inet ' + TABLE + ' >/dev/null 2>&1') != 0)
		return null;
	let fp = popen('nft -j list table inet ' + TABLE + ' 2>/dev/null', 'r');
	let out = (fp != null) ? fp.read('all') : '';
	if (fp != null)
		fp.close();
	let doc = json(out);
	if (doc == null || type(doc.nftables) != 'array')
		return null;
	let res = [];
	for (let i = 0; i < length(doc.nftables); i++) {
		let r = doc.nftables[i].rule;
		if (r == null || type(r.expr) != 'array')
			continue;
		let has_queue = false;
		let cnt = null;
		for (let j = 0; j < length(r.expr); j++) {
			if (type(r.expr[j].queue) == 'object')
				has_queue = true;
			if (type(r.expr[j].counter) == 'object')
				cnt = r.expr[j].counter;
		}
		if (has_queue && cnt != null)
			push(res, cnt);
	}
	if (length(res) < 2)
		return null;
	return {
		tcp: { packets: int(res[0].packets), bytes: int(res[0].bytes) },
		udp: { packets: int(res[1].packets), bytes: int(res[1].bytes) }
	};
}

function status_tunnel_info() {
	let t = load_tunnel();
	let st = load_state();
	let now = time();
	let win = int(t.expire_hours) * 3600;
	let merged = merge_proxy_entries(t);
	let entries = [];
	for (let i = 0; i < length(merged); i++) {
		let e = merged[i];
		let src = (index_of(t.proxy_servers, e) >= 0) ? 'pin' : 'resolved';
		let exp = null; // pins never expire; expire_hours=0 = never
		if (src == 'resolved' && int(t.expire_hours) > 0) {
			let left = win;
			if (st[e] != null)
				left = win - (now - st[e]);
			exp = (left < 0) ? 0 : int((left + 1800) / 3600);
		}
		push(entries, { ip: e, source: src, expires_h: exp });
	}
	let parts = split_cron_lines(read_crontab_lines());
	return {
		hosts: t.tunnel_hosts,
		entries: entries,
		update_interval_h: int(t.update_interval),
		expire_hours: int(t.expire_hours),
		cron: { ok: (length(parts.ours) == 1), lines: length(parts.ours) }
	};
}

function status_whitelist_info() {
	let w = load_whitelist();
	let st = stat(HOSTLIST);
	return {
		mode: (w.enabled == '1') ? 'whitelist' : 'blanket',
		domains: w.domains,
		file: { exists: (st != null), mtime: (st != null) ? st.mtime : null }
	};
}

function status_mihomo_info() {
	let m = load_mihomo();
	let text = readfile(m.conffile);
	if (text == null)
		return {
			state: null, mark: null, install_on_start: !access(NOSTAMP, 'r'),
			backup: false, running: mihomo_running(), api: null, config: m.conffile,
			config_missing: true
		};
	let st = mark_state(text);
	return {
		state: st.state,
		mark: st.value,
		install_on_start: !access(NOSTAMP, 'r'),
		backup: access(m.conffile + BACKUP_SUFFIX, 'r'),
		running: mihomo_running(),
		api: api_endpoint(text),
		config: m.conffile,
		config_missing: false
	};
}

function status_pending_info() {
	// staged-vs-committed UCI delta (`uci changes`) - the UI's "N pending
	// change" counter. Section tokens are best effort: uci changes lines are
	// '<conf>.<section>[.option]=value' or '<conf>.<name>=<type>'.
	let fp = popen('uci -q changes ' + sh_quote(CONF) + ' 2>/dev/null', 'r');
	let out = (fp != null) ? fp.read('all') : '';
	if (fp == null)
		return { count: null, sections: [], degraded: 'uci unavailable' };
	if (fp.close() != 0 && length(trim(out)) == 0)
		return { count: null, sections: [], degraded: 'uci changes failed' };
	let sections = {};
	let count = 0;
	let lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		let ln = trim(lines[i]);
		if (length(ln) == 0)
			continue;
		count++;
		let rest = (substr(ln, 0, length(CONF) + 1) == CONF + '.') ? substr(ln, length(CONF) + 1) : ln;
		let dot = index(rest, '.');
		sections[(dot != null && dot > 0) ? substr(rest, 0, dot) : rest] = true;
	}
	let arr = [];
	for (let k in sections)
		push(arr, k);
	sort(arr);
	return { count: count, sections: arr };
}

function status_events_info() {
	// filtered syslog tail (nfqws2 / wanguard-antidpi). logread is probed
	// first: containers and minimal setups have no running syslogd - that is
	// a degraded surface, not an empty result.
	if (system('logread >/dev/null 2>&1') != 0)
		return { available: false, lines: [] };
	let fp = popen('logread 2>/dev/null | grep -E "nfqws2|wanguard-antidpi" | tail -n 20', 'r');
	let out = (fp != null) ? fp.read('all') : '';
	if (fp != null)
		fp.close();
	let lines = [];
	let raw = split(out, '\n');
	for (let i = 0; i < length(raw); i++) {
		let ln = trim(raw[i]);
		if (length(ln) > 0)
			push(lines, ln);
	}
	return { available: true, lines: lines };
}

function cmd_status() {
	let want_json = false;
	for (let i = 1; i < length(ARGV); i++)
		if (ARGV[i] == '--json')
			want_json = true;

	let degraded = {};
	let nftc = status_nft_counters();
	if (nftc == null)
		degraded.nft = 'table absent';
	let t = status_tunnel_info();
	let w = status_whitelist_info();
	let m = status_mihomo_info();
	if (m.config_missing)
		degraded.mihomo = 'mihomo config missing';
	if (!access(ENGINE, 'x'))
		degraded.engine = 'engine binary missing';
	let p = status_pending_info();
	if (p.degraded != null)
		degraded.pending = p.degraded;
	let ev = status_events_info();
	if (!ev.available)
		degraded.events = 'logread unavailable';
	let en = status_engine_info();
	if (degraded.engine == null && en.version == null)
		degraded.engine = 'engine version probe failed';

	let s = {
		service: status_service_info(),
		engine: {
			pid: en.pid,
			version: en.version,
			profiles: en.profiles,
			profile_sections: en.profile_sections,
			policies: en.policies,
			policy_sections: en.policy_sections,
			hostlists: en.hostlists,
			running_argv: en.running_argv
		},
		nft: { table_present: (nftc != null), counters: nftc },
		tunnel: t,
		whitelist: w,
		mihomo: m,
		pending: { count: p.count, sections: p.sections },
		events: ev.lines,
		degraded: degraded
	};

	if (want_json) {
		printf('%J\n', s);
		return;
	}

	// human ops view (mark-status style key: value lines)
	print('service: enabled=' + (s.service.enabled ? 'yes' : 'no') +
		((s.service.pid != null) ? ', engine pid ' + s.service.pid : ', engine not running') +
		((s.service.uptime_s != null) ? ' (uptime ' + s.service.uptime_s + 's)' : '') + '\n');
	print('engine: ' + ((s.engine.version != null) ? s.engine.version : 'unknown') +
		', profiles ' + s.engine.profiles +
		', sections ' + length(s.engine.profile_sections) +
		', policies ' + s.engine.policies +
		', policy sections ' + length(s.engine.policy_sections) +
		', hostlists ' + length(s.engine.hostlists) +
		((s.engine.running_argv != null) ? ', running argv captured' : '') + '\n');
	print('nft: ' + (s.nft.table_present ?
		('table present (tcp ' + s.nft.counters.tcp.packets + ' pkts / udp ' + s.nft.counters.udp.packets + ' pkts)') :
		'table absent') + '\n');
	print('tunnel: ' + length(s.tunnel.entries) + ' entries (hosts ' + length(s.tunnel.hosts) +
		', cron ' + (s.tunnel.cron.ok ? 'ok' : 'missing') + ')\n');
	print('whitelist: ' + s.whitelist.mode + ' (' + length(s.whitelist.domains) + ' domains, file ' +
		(s.whitelist.file.exists ? 'present' : 'absent') + ')\n');
	print('mihomo: ' + (m.config_missing ? 'config missing' : ((m.running ? 'running' : 'stopped') +
		', mark ' + m.state)) + '\n');
	print('pending: ' + ((p.count != null) ? (p.count + ' staged change(s)') : 'unknown') + '\n');
	print('events: ' + (ev.available ? (length(ev.lines) + ' line(s)') : 'unavailable') + '\n');
	if (length(keys(degraded)) > 0)
		print('degraded: ' + join_lines(keys(degraded)) + '\n');
}


// ---------------------------------------------------------------------------
// apply (issue #77): the idempotent orchestration point behind the LuCI page.
// ONE subcommand instead of the UI assembling a call sequence. The real run
// drives the SAME subcommands the init shim drives (as child processes, so
// their output/log lines stay byte-identical whether invoked directly or
// through apply):
//
//   mark-ensure -> tunnel-update -> nft-apply -> whitelist-refresh -> engine
//
// The engine step decides restart-vs-SIGHUP from evidence (#70: list CONTENT
// is re-read on HUP without dropping the queue or live connections; strategy
// word changes need a full restart through the init script):
//   - engine dead + strategy words present -> init restart (starts it)
//   - rendered argv drifted beyond the --hostlist words -> init restart
//   - only --hostlist words / hostlist file content changed -> SIGHUP
//   - nothing changed -> no-op (idempotency; repeated apply is safe)
//
// Exit codes (DESIGN.md contract): 0 ok, 1 validation failure (config does
// not render, nft apply failed, restart failed), 2 partial (a non-fatal step
// kept a fallback - e.g. tunnel-update kept the last known exclusion set on
// a total resolution failure).
//
// --check: preflight WITHOUT mutations - config renders, nft table in force,
// mark installed with our value, engine running, hostlist file present when
// the engine consumes it. Human output; --json adds a machine-readable
// report. DRYRUN (the README convention) prints the full plan without
// touching any live state.
// ---------------------------------------------------------------------------

function apply_running_argv() {
	// the live engine argv (binary path dropped) for the restart-vs-HUP
	// decision; null = not running (or /proc unreadable)
	let pid = engine_pid();
	if (length(pid) == 0)
		return null;
	let pids = split(trim(pid), ' ');
	let argv = status_proc_cmdline(pids[0]);
	if (argv == null || length(argv) < 1)
		return null;
	let r = [];
	for (let i = 1; i < length(argv); i++)
		push(r, argv[i]);
	return r;
}

function apply_argv_without_hostlist(a) {
	let r = [];
	for (let i = 0; i < length(a); i++)
		if (substr(a[i], 0, 11) != '--hostlist=')
			push(r, a[i]);
	return r;
}

function apply_argv_equal(a, b) {
	if (length(a) != length(b))
		return false;
	for (let i = 0; i < length(a); i++)
		if (a[i] != b[i])
			return false;
	return true;
}

function apply_hostlist_wouldbe() {
	// the canonical text whitelist-refresh would write right now, or null for
	// blanket mode (mirror of whitelist_refresh_run's content pipeline; the
	// caller has rendered engine_argv() first, so the domains are already
	// validated and this cannot die). The content is the merged source set
	// (#82): legacy whitelist.domains UNION domainlist sections.
	let src = whitelist_sources();
	if (src.enabled != '1')
		return null;
	let doms = whitelist_merged(src);
	if (length(doms) == 0)
		return null;
	return join_lines(doms) + '\n';
}

function apply_engine_decision(file_changed) {
	// pure computation over live state + the rendered argv (no mutations):
	// 'restart' (through the init script), 'reload' (SIGHUP) or 'noop'
	let c = load_config();
	let new_argv = engine_argv();
	let old_argv = apply_running_argv();
	// the "worth starting" check counts the STRATEGY SOURCES (profiles
	// replace the legacy opt, issue #84; policy blocks are their own blocks,
	// issue #86), not c.opt alone
	let strategy = profile_strategy_words();
	if (strategy == null)
		strategy = c.opt;
	let pol = policy_render();
	let worth = (length(strategy) > 0) || (pol != null && length(pol.blocks) > 0);
	if (old_argv == null)
		return worth
			? { action: 'restart', reason: 'engine not running - starting with ' + length(strategy) + ' strategy words' }
			: { action: 'noop', reason: 'engine not running, no strategy words - nothing to start' };
	if (!apply_argv_equal(old_argv, new_argv)) {
		if (apply_argv_equal(apply_argv_without_hostlist(old_argv), apply_argv_without_hostlist(new_argv))) {
			// ONLY the --hostlist words differ. With the fixed per-profile
			// emission (a mode emits the word on every profile or on none)
			// this is exactly the whitelist mode flip (#82) or a policy
			// rebinding to a different list (#86): SIGHUP re-reads
			// list file CONTENT but cannot add/drop the --hostlist binding
			// of a live process (the argv is exec-time), so a flip MUST go
			// through a restart (the AGENTS #70 memo contract).
			return { action: 'restart', reason: 'whitelist mode flipped - restart rebinds --hostlist (SIGHUP reloads file content only)' };
		}
		return { action: 'restart', reason: 'engine argv drifted (strategy/filters) - restart required' };
	}
	if (file_changed)
		return { action: 'reload', reason: 'hostlist file content changed - SIGHUP re-reads the lists' };
	return { action: 'noop', reason: 'engine argv and lists are up to date' };
}

function apply_child(args, quiet) {
	// run one of the CLI's own subcommands as a child process (output/log
	// lines stay byte-identical to a direct invocation; JSON mode swallows
	// them so the document stays parseable)
	return system(CLI_SELF + ' ' + args + ((quiet) ? ' >/dev/null 2>&1' : ''));
}

function apply_check_run(want_json) {
	let checks = {};
	let ok = true;

	// config: the full engine argv render (UCI strict section, whitelist
	// validation, address validation). Probed in a child so a die() inside
	// the render cannot kill the check itself; the child's stderr carries
	// the human-readable reason.
	let cfg_rc = system(CLI_SELF + ' engine-cmdline >/dev/null 2>&1');
	if (cfg_rc != 0) {
		let fp = popen(CLI_SELF + ' engine-cmdline 2>&1 >/dev/null', 'r');
		let cerr = trim((fp != null) ? fp.read('all') : '');
		if (fp != null)
			fp.close();
		checks.config = { ok: false, detail: (length(cerr) > 0) ? cerr : 'engine-cmdline render failed' };
		ok = false;
	} else {
		checks.config = { ok: true, detail: null };
	}

	// nft: table in force AND the template still renders
	let table_live = (system('nft list table inet ' + TABLE + ' >/dev/null 2>&1') == 0);
	let nft_rc = system(CLI_SELF + ' nft-render >/dev/null 2>&1');
	checks.nft = {
		ok: (table_live && nft_rc == 0),
		present: table_live,
		detail: (!table_live) ? 'table absent' : ((nft_rc != 0) ? 'nft-render failed' : null)
	};
	if (!checks.nft.ok)
		ok = false;

	// mark: installed with OUR value (a foreign value is a hard fail - the
	// add-on never touches it, and without our mark the scope silently does
	// not exist)
	let m = load_mihomo();
	let text = readfile(m.conffile);
	if (text == null) {
		checks.mark = { ok: false, value: null, detail: 'mihomo config missing (' + m.conffile + ')' };
		ok = false;
	} else {
		let st = mark_state(text);
		checks.mark = (st.state == 'installed')
			? { ok: true, value: st.value, detail: null }
			: {
				ok: false, value: st.value,
				detail: (st.state == 'conflict')
					? ('foreign routing-mark: ' + st.value + ' (needs ' + MARK_LINE + ' - never touched by this add-on)')
					: 'routing-mark not installed'
			};
		if (!checks.mark.ok)
			ok = false;
	}

	// engine: running
	let pid = engine_pid();
	checks.engine = (length(pid) > 0)
		? { ok: true, pid: pid, detail: null }
		: { ok: false, pid: null, detail: 'engine not running' };
	if (length(pid) == 0)
		ok = false;

	// hostlist: present when the engine consumes it - the whitelist binding
	// (whitelist on + a non-empty merged source set + strategy words from
	// EITHER source, profiles included: the #84 contract) or a rendered
	// policy block (each carries its own per-list file, issue #86). Blanket
	// mode and wordless whitelists never read the whitelist file.
	let src = whitelist_sources();
	let c = load_config();
	let strategy_words = profile_strategy_words();
	if (strategy_words == null)
		strategy_words = c.opt;
	let pol = policy_render();
	let needed = (pol != null && length(pol.blocks) > 0) ||
		(src.enabled == '1' && length(whitelist_merged(src)) > 0 && length(strategy_words) > 0);
	let exists = access(HOSTLIST, 'r');
	let pol_files_ok = true;
	let pol_files_detail = null;
	if (pol != null) {
		for (let li = 0; li < length(pol.lists); li++) {
			let path = policy_hostlist_path(pol.lists[li].sid);
			if (!access(path, 'r')) {
				pol_files_ok = false;
				pol_files_detail = 'policy list file missing: ' + path + ' (run whitelist-refresh)';
				break;
			}
		}
	}
	checks.hostlist = {
		ok: (!needed || (exists && pol_files_ok)),
		needed: needed,
		exists: exists,
		detail: (needed && !exists)
			? ('whitelist mode consumes ' + HOSTLIST + ' but the file is missing (run whitelist-refresh)')
			: ((needed && !pol_files_ok) ? pol_files_detail : null)
	};
	if (needed && !(exists && pol_files_ok))
		ok = false;

	if (want_json) {
		printf('%J\n', { ok: ok, checks: checks });
	} else {
		print('check: config: ' + (checks.config.ok ? 'ok' : 'FAILED - ' + checks.config.detail) + '\n');
		print('check: nft: ' + (checks.nft.ok ? 'ok' : 'FAILED - ' + checks.nft.detail) + '\n');
		print('check: mark: ' + (checks.mark.ok ? ('ok (' + checks.mark.value + ')') : 'FAILED - ' + checks.mark.detail) + '\n');
		print('check: engine: ' + (checks.engine.ok ? ('ok (pid ' + checks.engine.pid + ')') : 'FAILED - ' + checks.engine.detail) + '\n');
		print('check: hostlist: ' + (checks.hostlist.ok
			? (checks.hostlist.needed ? 'ok (file present)' : 'ok (not consumed in this mode)')
			: 'FAILED - ' + checks.hostlist.detail) + '\n');
		print('check-result: ' + (ok ? 'ok' : 'FAILED') + '\n');
	}
	exit(ok ? 0 : 1);
}

function cmd_apply() {
	let want_check = false;
	let want_json = false;
	for (let i = 1; i < length(ARGV); i++) {
		if (ARGV[i] == '--check')
			want_check = true;
		else if (ARGV[i] == '--json')
			want_json = true;
		else
			die('apply: unknown argument: ' + ARGV[i]);
	}
	if (want_check)
		return apply_check_run(want_json);

	// preflight render: every validation die() in the config path fires
	// HERE, before any mutation (validation failure -> exit 1, nothing
	// touched)
	let c = load_config();
	engine_argv();

	if (dryrun()) {
		let cur = access(HOSTLIST, 'r') ? readfile(HOSTLIST) : null;
		let wouldbe = apply_hostlist_wouldbe();
		let polchanged = (policy_lists_disk_state() != policy_lists_wouldbe_state());
		let d = apply_engine_decision((cur != wouldbe) || polchanged);
		print('DRYRUN: would ensure the routing-mark integration\n');
		print('DRYRUN: would update the tunnel exclusion set (' + length(load_tunnel().tunnel_hosts) + ' host(s) configured)\n');
		print('DRYRUN: would apply nft table inet ' + TABLE + '\n');
		print('DRYRUN: would ' + ((wouldbe == null) ? ('remove ' + HOSTLIST + ' (blanket mode)') : ('render ' + HOSTLIST)) + '\n');
		let dpol = policy_render();
		if (dpol != null && length(dpol.lists) > 0)
			print('DRYRUN: would render ' + length(dpol.lists) + ' policy list file(s) under ' + POLICY_LISTS_DIR + '\n');
		print('DRYRUN: engine: would ' + d.action + ' (' + d.reason + ')\n');
		print('DRYRUN: apply plan printed - no changes made\n');
		exit(0);
	}

	let steps = {};
	let fatal = false;
	let partial = false;

	// [1] mark integration (child: exit 0 = ok/skip/non-fatal - conflict and
	// missing-config stay graceful per the mark-ensure contract; 1 = the
	// injected config failed validation and was rolled back)
	steps.mark = (apply_child('mark-ensure', want_json) == 0) ? 'ok' : 'failed';
	if (steps.mark == 'failed')
		fatal = true;

	// [2] tunnel exclusion set (non-fatal by contract: a total resolution
	// failure keeps the last known set; the table below still applies)
	if (length(load_tunnel().tunnel_hosts) == 0) {
		steps.tunnel = 'skipped';
		if (!want_json)
			print('apply: tunnel: skipped (no hosts configured)\n');
	} else {
		steps.tunnel = (apply_child('tunnel-update', want_json) == 0) ? 'ok' : 'kept-last-known';
		if (steps.tunnel != 'ok')
			partial = true;
	}

	// [3] nft scope table
	steps.nft = (apply_child('nft-apply', want_json) == 0) ? 'applied' : 'failed';
	if (steps.nft == 'failed')
		fatal = true;
	else if (!want_json)
		print('apply: nft: applied\n');

	// [4] hostlist render + change detection for the engine step (the
	// whitelist file AND every referenced policy list file - a list content
	// change reloads via SIGHUP, an argv change restarts)
	let file_before = access(HOSTLIST, 'r') ? readfile(HOSTLIST) : null;
	let polstate_before = policy_lists_disk_state();
	if (apply_child('whitelist-refresh', want_json) != 0) {
		steps.whitelist = 'failed';
		fatal = true;
	} else {
		steps.whitelist = 'refreshed';
		if (!want_json)
			print('apply: whitelist: refreshed\n');
	}
	let file_after = access(HOSTLIST, 'r') ? readfile(HOSTLIST) : null;
	let polstate_after = policy_lists_disk_state();
	let file_changed = (file_before != file_after) || (polstate_before != polstate_after);

	// [5] engine: restart-vs-SIGHUP per the #70 evidence
	let d = apply_engine_decision(file_changed);
	if (d.action == 'restart') {
		let rc = system(INIT + ' restart >/dev/null 2>&1');
		if (rc == 0) {
			steps.engine = 'restarted';
			if (!want_json)
				print('apply: engine: restarted - ' + d.reason + '\n');
			system('logger -t wanguard-antidpi ' + sh_quote('apply: engine restarted (' + d.reason + ')'));
		} else {
			steps.engine = 'failed';
			warn('wanguard-antidpi: apply: init restart failed (rc ' + rc + ')\n');
			fatal = true;
		}
	} else if (d.action == 'reload') {
		let pid = engine_pid();
		let hp = (length(pid) > 0) ? trim(split(pid, ' ')[0]) : null;
		if (hp == null || system('kill -HUP ' + hp) != 0) {
			steps.engine = 'failed';
			warn('wanguard-antidpi: apply: failed to signal the engine\n');
			fatal = true;
		} else {
			steps.engine = 'reloaded';
			if (!want_json)
				print('apply: engine: reloaded (SIGHUP pid ' + hp + ') - ' + d.reason + '\n');
			system('logger -t wanguard-antidpi ' + sh_quote('apply: engine reloaded via SIGHUP (pid ' + hp + ') - ' + d.reason));
		}
	} else {
		steps.engine = 'noop';
		if (!want_json)
			print('apply: engine: no-op - ' + d.reason + '\n');
	}

	if (want_json)
		printf('%J\n', { ok: !fatal, partial: partial, steps: steps });
	else
		print('apply-result: ' + (fatal ? 'FAILED' : (partial ? 'PARTIAL' : 'ok')) + '\n');
	exit(fatal ? 1 : (partial ? 2 : 0));
}


let cmd = (length(ARGV) > 0) ? ARGV[0] : 'version';
switch (cmd) {
case 'version':
	cmd_version();
	break;

case 'engine-version':
	cmd_engine_version();
	break;

case 'engine-cmdline':
	cmd_engine_cmdline();
	break;

case 'nft-render':
	cmd_nft_render();
	break;

case 'nft-apply':
	cmd_nft_apply();
	break;

case 'nft-flush':
	cmd_nft_flush();
	break;

case 'mark-install':
	cmd_mark_install(true);
	break;

case 'mark-ensure':
	cmd_mark_ensure();
	break;

case 'mark-remove':
	cmd_mark_remove();
	break;

case 'mark-status':
	cmd_mark_status();
	break;

case 'tunnel-update':
	cmd_tunnel_update();
	break;

case 'tunnel-status':
	cmd_tunnel_status();
	break;

case 'cron-install':
	cmd_cron_install();
	break;

case 'cron-remove':
	cmd_cron_remove();
	break;

case 'whitelist-refresh':
	cmd_whitelist_refresh();
	break;

case 'whitelist-reload':
	cmd_whitelist_reload();
	break;

case 'whitelist-status':
	cmd_whitelist_status();
	break;

case 'apply':
	cmd_apply();
	break;

case 'status':
	cmd_status();
	break;

default:
	warn('usage: wanguard-antidpi [version|engine-version|engine-cmdline|nft-render|nft-apply|nft-flush|mark-install|mark-ensure|mark-remove|mark-status|tunnel-update|tunnel-status|cron-install|cron-remove|whitelist-refresh|whitelist-reload|whitelist-status|apply [--check]|status [--json]]\n');
	exit(2);
}
