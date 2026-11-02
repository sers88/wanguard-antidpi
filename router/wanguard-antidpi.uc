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
//   nft-render      print the rendered nft ruleset (template + config qnum)
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
	// it strictly numeric
	if (!match(c.qnum, /^[0-9]+$/))
		die('config qnum must be numeric, got: ' + c.qnum);
	return c;
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

function render_nft(c) {
	let tpl = readfile(NFT_TEMPLATE);
	if (tpl == null)
		die('nft template missing: ' + NFT_TEMPLATE);
	return replace(tpl, /@QNUM@/g, c.qnum);
}

function cmd_nft_render() {
	print(render_nft(load_config()));
}

function cmd_nft_apply() {
	let c = load_config();
	if (dryrun()) {
		print('DRYRUN: would apply nft table inet ' + TABLE + ':\n');
		print(render_nft(c));
		return;
	}
	// fixed tmp name: the engine lifecycle is single-instance (procd) and the
	// file is unlinked right after nft -f consumed it
	let tmp = '/tmp/wanguard-antidpi.nft';
	writefile(tmp, render_nft(c));
	let rc = system('nft -f ' + tmp);
	unlink(tmp);
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
	let cmd = 'curl -sS -f -m 10 --connect-timeout 3 -X PUT ';
	if (length(hdr) > 0) {
		check_write(AUTH_TMP, writefile(AUTH_TMP, hdr[0] + '\n'));
		cmd += '-H @' + sh_quote(AUTH_TMP) + ' ';
	}
	cmd += '-d ' + sh_quote('{"path":' + json_str(workdir + '/config.yaml') + '}') + ' ';
	cmd += sh_quote('http://' + ep + '/configs?force=true') + ' 2>&1';
	let fp = popen(cmd, 'r');
	let out = (fp != null) ? fp.read('all') : '';
	let rc = (fp != null) ? fp.close() : 1;
	unlink(AUTH_TMP);
	if (rc == 0) {
		log('mihomo reloaded via REST (' + ep + ') - routing-mark active');
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

default:
	warn('usage: wanguard-antidpi [version|engine-version|engine-cmdline|nft-render|nft-apply|nft-flush|mark-install|mark-ensure|mark-remove|mark-status]\n');
	exit(2);
}
