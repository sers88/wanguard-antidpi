// tests/luci-menu-test.uc - LuCI menu.d merge + ACL harness for
// luci-app-wanguard-antidpi (issue #78).
//
// The build_pagetree/ACL logic below is verbatim-derived from the installed
// LuCI dispatcher (/usr/share/ucode/luci/dispatcher.uc, OpenWrt 25.12.x) -
// the same methodology spike-75/issue #75 blessed. Functional changes are
// exactly three, each commented inline: (1) build_pagetree() takes the
// menu.d directory as an argument instead of hardcoding it, (2) no index
// cache, (3) no Lua controller bridge. The distinctive dispatcher lines this
// file replicates are pinned in tests/luci-dispatcher-lines.txt; test-luci.sh
// greps the INSTALLED dispatcher for every line, so an upstream LuCI change
// fails the matrix loudly here instead of silently diverging.
//
// Modes:
//   tree <menudir> <acl.json>        build + ACL-apply the tree, print facts
//   parentguard <fixture> <ours> <acl-group>
//                                    parent-node identity guard (issue #78:
//                                    byte-identical parent EXCEPT the ACL
//                                    group - see the deviation note in
//                                    test-luci.sh)
//   childguard <ours>                the antidpi node must define ALL schema
//                                    fields (per-field merge: a missing field
//                                    leaks from the placeholder, #75
//                                    A_fieldmerge)
//
// NOTE: ucode runs script FILES without auto-importing modules (unlike -e).
import { stat, lsdir, glob, open } from 'fs';
import { cursor } from 'uci';

let uci = cursor();

function die(msg) {
	warn(`MENU-TEST-FAIL: ${msg}\n`);
	exit(1);
}

// ucode гоча (#60): join() returns null - concatenate manually
function joinlist(arr) {
	let out = '';

	for (let i, v in arr ?? [])
		out = out + (i > 0 ? ',' : '') + v;

	return out == '' ? '-' : out;
}

// ---- verbatim dispatcher.uc (read_jsonfile: the dispatcher wraps this in
// ---- read_cachefile() for the index cache; the cache is not used here) ----
function read_jsonfile(path, defval) {
	let rv;

	try {
		rv = json(open(path, "r"));
	}
	catch (e) {
		rv = defval;
	}

	return rv;
}

function check_fs_depends(spec) {
	for (let path, kind in spec) {
		if (kind == 'directory') {
			if (!length(lsdir(path)))
				return false;
		}
		else if (kind == 'executable') {
			let fstat = stat(path);

			if (fstat?.type != 'file' || fstat?.user_exec == false)
				return false;
		}
		else if (kind == 'file') {
			let fstat = stat(path);

			if (fstat?.type != 'file')
				return false;
		}
		else if (kind == 'absent') {
			if (stat(path) != null)
				return false;
		}
	}

	return true;
}

function check_uci_depends_options(conf, s, opts) {
	if (type(opts) == 'string') {
		return (s['.type'] == opts);
	}
	else if (opts === true) {
		for (let option, value in s)
			if (ord(option) != 46)
				return true;
	}
	else if (type(opts) == 'object') {
		for (let option, value in opts) {
			let sval = s[option];

			if (type(sval) == 'array') {
				if (!(value in sval))
					return false;
			}
			else if (value === true) {
				if (sval == null)
					return false;
			}
			else {
				if (sval != value)
					return false;
			}
		}
	}

	return true;
}

function check_uci_depends_section(conf, sect) {
	for (let section, options in sect) {
		let stype = match(section, /^@([A-Za-z0-9_-]+)$/);

		if (stype) {
			let found = false;

			uci.load(conf);
			uci.foreach(conf, stype[1], (s) => {
				if (check_uci_depends_options(conf, s, options)) {
					found = true;
					return false;
				}
			});

			if (!found)
				return false;
		}
		else {
			let s = uci.get_all(conf, section);

			if (!s || !check_uci_depends_options(conf, s, options))
				return false;
		}
	}

	return true;
}

function check_uci_depends(conf) {
	for (let config, values in conf) {
		if (values == true) {
			let found = false;

			uci.load(config);
			uci.foreach(config, null, () => { found = true });

			if (!found)
				return false;
		}
		else if (type(values) == 'object') {
			if (!check_uci_depends_section(config, values))
				return false;
		}
	}

	return true;
}

function check_depends(spec) {
	if (type(spec?.depends?.fs) in ['array', 'object']) {
		let satisfied = false;
		let alternatives = (type(spec.depends.fs) == 'array') ? spec.depends.fs : [ spec.depends.fs ];

		for (let alternative in alternatives) {
			if (check_fs_depends(alternative)) {
				satisfied = true;
				break;
			}
		}

		if (!satisfied)
			return false;
	}

	if (type(spec?.depends?.uci) in ['array', 'object']) {
		let satisfied = false;
		let alternatives = (type(spec.depends.uci) == 'array') ? spec.depends.uci : [ spec.depends.uci ];

		for (let alternative in alternatives) {
			if (check_uci_depends(alternative)) {
				satisfied = true;
				break;
			}
		}

		if (!satisfied)
			return false;
	}

	return true;
}

function check_acl_depends(require_groups, groups) {
	if (length(require_groups)) {
		let writable = false;

		for (let group in require_groups) {
			let read = ('read' in groups?.[group]);
			let write = ('write' in groups?.[group]);

			if (!read && !write)
				return null;

			if (write)
				writable = true;
		}

		return writable;
	}

	return true;
}

function apply_tree_acls(node, acl) {
	for (let name, spec in node?.children)
		apply_tree_acls(spec, acl);

	if (node?.depends?.acl) {
		switch (check_acl_depends(node.depends.acl, acl["access-group"])) {
		case null:  node.satisfied = false; break;
		case false: node.readonly = true;   break;
		}
	}
}

// ---- verbatim merge loop, parameterized by dir (changes 1-3 above) ----
function build_pagetree(dir) {
	let tree = { action: { type: 'firstchild' } };

	let schema = {
		action: 'object',
		auth: 'object',
		cors: 'bool',
		depends: 'object',
		order: 'int',
		setgroup: 'string',
		setuser: 'string',
		title: 'string',
		wildcard: 'bool',
		firstchild_ineligible: 'bool'
	};

	let files = glob(dir + '/*.json');

	for (let file in files) {
		let data = read_jsonfile(file);

		if (type(data) == 'object') {
			for (let path, spec in data) {
				if (type(spec) == 'object') {
					let node = tree;
					let has_wildcard = false;

					for (let s in match(path, /[^\/]+/g)) {
						if (s[0] == '*') {
							node.wildcard = true;
							has_wildcard = true;
							break;
						}

						node.children ??= {};
						node.children[s[0]] ??= { satisfied: true };
						node = node.children[s[0]];
					}

					if (node !== tree) {
						for (let k, t in schema)
							if (type(spec[k]) == t)
								node[k] = spec[k];

						/* Preserve distinct actions for wildcard vs. base path */
						if (has_wildcard && type(spec.action) == 'object')
							node.wildcardaction = spec.action;
						else if (type(spec.action) == 'object')
							node.action = spec.action;

						node.satisfied = check_depends(spec);
					}
				}
			}
		}
	}

	return tree;
}

// ---- harness helpers (not dispatcher code) ----

function node_facts(prefix, node, extra) {
	if (node == null) {
		printf('%s: absent\n', prefix);
		return;
	}

	let acl = (node?.depends?.acl != null) ? joinlist(node.depends.acl) : '-';

	printf('%s: satisfied=%d readonly=%d title=%s acl=%s%s\n',
		prefix,
		node?.satisfied ? 1 : 0,
		node?.readonly ? 1 : 0,
		node?.title ?? '-',
		acl,
		extra ?? '');
}

function run_tree(dir, aclfile) {
	let tree = build_pagetree(dir);

	if (aclfile != null) {
		let acl = read_jsonfile(aclfile);

		if (type(acl) != 'object')
			die(`cannot read acl file ${aclfile}`);

		apply_tree_acls(tree, acl);
	}

	let wg = tree?.children?.admin?.children?.network?.children?.wanguard;

	if (wg == null) {
		printf('wanguard.parent: absent\n');
		printf('wanguard.antidpi: absent\n');
		return;
	}

	let kids = (wg?.children != null) ? sort(keys(wg.children)) : [];

	node_facts('wanguard.parent', wg, ' children=' + joinlist(kids));
	node_facts('wanguard.antidpi', wg?.children?.antidpi,
		wg?.children?.antidpi != null
			? ' order=' + (wg.children.antidpi?.order ?? -1)
				+ ' path=' + (wg.children.antidpi?.action?.path ?? '-')
			: '');
}

function run_parentguard(fixt, ours, group) {
	let f = read_jsonfile(fixt)?.['admin/network/wanguard'];
	let o = read_jsonfile(ours)?.['admin/network/wanguard'];

	if (type(f) != 'object')
		die(`fixture ${fixt} has no admin/network/wanguard node`);
	if (type(o) != 'object')
		die(`${ours} has no admin/network/wanguard node`);

	// title/order/action must be identical; depends may differ ONLY in the
	// ACL group (see the deviation note in test-luci.sh).
	for (let key in ['title', 'order', 'action']) {
		if (sprintf('%J', f[key]) != sprintf('%J', o[key]))
			die(`parentguard: field ${key} differs: fixture=`
				+ sprintf('%J', f[key]) + ' ours=' + sprintf('%J', o[key]));
	}

	let fa = f?.depends?.acl;
	let oa = o?.depends?.acl;

	if (type(fa) != 'array' || type(oa) != 'array')
		die('parentguard: depends.acl must be an array on both sides');

	if (joinlist(oa) != group)
		die(`parentguard: ours acl is [${joinlist(oa)}], expected [${group}]`);

	printf('PARENT-GUARD-OK (title/order/action identical, acl=[%s] vs fixture [%s])\n',
		joinlist(oa), joinlist(fa));
}

function run_childguard(ours) {
	let n = read_jsonfile(ours)?.['admin/network/wanguard/antidpi'];

	if (type(n) != 'object')
		die(`${ours} has no admin/network/wanguard/antidpi node`);
	if (type(n.title) != 'string')
		die('childguard: title missing (per-field merge would leak the placeholder)');
	if (type(n.order) != 'int')
		die('childguard: order missing (per-field merge would leak the placeholder)');
	if (type(n.action) != 'object' || n.action.type != 'view' ||
	    type(n.action.path) != 'string')
		die('childguard: action { type: view, path } missing (would be overwritten wholesale)');
	if (type(n.depends) != 'object' || type(n.depends.acl) != 'array' ||
	    length(n.depends.acl) != 1)
		die('childguard: depends.acl must be a single-element array');

	printf('CHILD-GUARD-OK (title/order/action/depends all defined)\n');
}

switch (ARGV[0]) {
case 'tree':
	run_tree(ARGV[1], ARGV[2]);
	break;

case 'parentguard':
	run_parentguard(ARGV[1], ARGV[2], ARGV[3]);
	break;

case 'childguard':
	run_childguard(ARGV[1]);
	break;

default:
	die('usage: luci-menu-test.uc <tree <dir> <acl.json>|parentguard <fixture> <ours> <group>|childguard <ours>>');
}
