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
//
// DRYRUN contract: WANGUARD_ANTIDPI_DRYRUN=1 makes every state-changing
// command print what it would do, touch nothing, exit 0. This is how the
// container matrix tests the CLI without live nft/queue state.
//
// Config: UCI /etc/config/wanguard-antidpi, section engine (see the shipped
// template). Unknown/missing options fall back to the published defaults.

'use strict';

import { access, popen, readfile, writefile, unlink } from 'fs';
import * as uci from 'uci';

const BASE = '/usr/share/wanguard-antidpi';
const NFT_TEMPLATE = BASE + '/wanguard-antidpi.nft';
const TABLE = 'wanguard_antidpi';
const CONF = 'wanguard-antidpi';
const ENGINE = '/usr/bin/nfqws2';
const STAMP = BASE + '/version';

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

default:
	warn('usage: wanguard-antidpi [version|engine-version|engine-cmdline|nft-render|nft-apply|nft-flush]\n');
	exit(2);
}
