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

import { access, popen, readfile, writefile, unlink } from 'fs';
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

function valid_hostname(h) {
	// strict DNS hostname for shell exec via nslookup: letters/digits/hyphen
	// labels, at least two labels (single labels cannot resolve via DNS
	// anyway), 253-octet presentation limit
	if (h == null || length(h) == 0 || length(h) > 253)
		return false;
	return match(h, /^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/) != null;
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

function cmd_engine_cmdline() {
	let c = load_config();
	print(ENGINE + '\n');
	print('--qnum=' + c.qnum + '\n');
	print('--fwmark=' + c.fwmark + '\n');
	print('--user=' + c.user + '\n');
	// gzipped lua is supported natively by nfqws2 (--lua-init=@<file>)
	print('--lua-init=@' + BASE + '/lua/zapret-lib.lua.gz\n');
	print('--lua-init=@' + BASE + '/lua/zapret-antidpi.lua.gz\n');
	if (c.debug == '1')
		print('--debug=1\n');
	// strategy words verbatim: one UCI list item = one argv word (the shell
	// word-split contract is gone with the ucode base)
	for (let i = 0; i < length(c.opt); i++)
		print(c.opt[i] + '\n');
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

default:
	warn('usage: wanguard-antidpi [version|engine-version|engine-cmdline|nft-render|nft-apply|nft-flush|mark-install|mark-ensure|mark-remove|mark-status|tunnel-update|tunnel-status|cron-install|cron-remove]\n');
	exit(2);
}
