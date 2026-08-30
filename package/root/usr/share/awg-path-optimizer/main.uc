#!/usr/bin/ucode

import * as fs from "fs";
import * as uci from "uci";

const TAG = "awg-path-opt";
const CONFIG = "awg_path_optimizer";

let ctx = uci.cursor();
let states = {};
let skip_reasons = {};

function log(msg) {
	warn(sprintf("[%s] %s\n", TAG, msg));
}

function run(argv) {
	/*
	 * OpenWrt 25.12 may ship a ucode fs module where fs.popen() accepts
	 * only a string command. Newer upstream ucode also accepts argv arrays.
	 *
	 * Build a shell command only from a deliberately restricted character
	 * set. This keeps compatibility with the older API without allowing
	 * UCI values such as target/interface names to inject shell syntax.
	 */
	let command = "";

	for (let arg in argv) {
		arg = "" + arg;

		if (!match(arg, /^[A-Za-z0-9_.:\/@%+=,-]+$/)) {
			log("refusing unsafe command argument: " + arg);
			return { rc: 126, out: "" };
		}

		command += (length(command) ? " " : "") + arg;
	}

	let p = fs.popen(command, "r");

	if (p == null) {
		log("popen failed for [" + command + "]: " + fs.error());
		return { rc: 127, out: "" };
	}

	let out = p.read("all");
	let rc = p.close();

	return {
		rc: rc == null ? 127 : rc,
		out: out == null ? "" : out
	};
}

function words(s) {
	s = trim(s == null ? "" : s);

	if (!length(s))
		return [];

	return split(s, /\s+/);
}

function contains(values, wanted) {
	for (let value in values) {
		if (value == wanted)
			return true;
	}

	return false;
}

function cfg(section, option, def) {
	let v = ctx.get(CONFIG, section, option);

	if (v == null || v == "")
		return def;

	return v;
}

function cfg_int(section, option, def) {
	let v = cfg(section, option, null);

	if (v == null)
		return def;

	return int(v);
}

function get_interfaces() {
	let r = run(["awg", "show", "interfaces"]);

	if (r.rc != 0) {
		log("awg show interfaces failed rc=" + r.rc);
		return [];
	}

	return words(r.out);
}

function get_listen_port(iface) {
	let r = run(["awg", "show", iface, "listen-port"]);

	if (r.rc != 0)
		return null;

	let p = int(trim(r.out));

	return p >= 1 && p <= 65535 ? p : null;
}

function get_network_port(iface) {
	let v = ctx.get("network", iface, "listen_port");

	if (v == null)
		return null;

	let p = int(v);

	return p >= 1 && p <= 65535 ? p : null;
}

function get_base_port(iface, current) {
	let override = int(cfg(iface, "base_port", "0"));

	if (override >= 1 && override <= 65535)
		return override;

	let configured = get_network_port(iface);

	if (configured != null)
		return configured;

	return current;
}

function is_link_up(iface) {
	let r = run(["ip", "link", "show", "dev", iface]);

	return r.rc == 0 && match(r.out, /[<,]UP[,>]/) != null;
}

function get_peer(iface) {
	let r = run(["awg", "show", iface, "endpoints"]);

	if (r.rc != 0)
		return null;

	let w = words(r.out);
	let wanted_ip = cfg(iface, "peer_ip", "");

	for (let i = 0; i + 1 < length(w); i += 2) {
		let endpoint = w[i + 1];
		let m = match(endpoint, /^\[([0-9A-Fa-f:.]+)\]:[0-9]+$/) ||
			match(endpoint, /^([0-9.]+):[0-9]+$/);

		if (!length(wanted_ip) || (m && m[1] == wanted_ip))
			return { key: w[i], endpoint: endpoint };
	}

	return null;
}

function get_allowed_words(iface, peer) {
	let r = run(["awg", "show", iface, "allowed-ips"]);

	if (r.rc != 0)
		return [];

	let w = words(r.out);

	for (let i = 0; i < length(w); i++) {
		if (w[i] == peer.key)
			return i + 1 < length(w) ? split(w[i + 1], ",") : [];
	}

	return [];
}

function client_skip_reason(iface) {
	if (cfg(iface, "enabled", "1") == "0")
		return "disabled by UCI";

	if (!is_link_up(iface))
		return "link is not UP";

	let peer = get_peer(iface);

	if (peer == null)
		return length(cfg(iface, "peer_ip", "")) ?
			"peer IP " + cfg(iface, "peer_ip", "") + " not found" :
			"no peers";

	if (peer.endpoint == "(none)")
		return "peer has no endpoint";

	if (cfg(iface, "force", "0") == "1")
		return null;

	let a = get_allowed_words(iface, peer);

	let default4 =
		contains(a, "0.0.0.0/0") ||
		(contains(a, "0.0.0.0/1") && contains(a, "128.0.0.0/1"));

	let default6 =
		contains(a, "::/0") ||
		(contains(a, "::/1") && contains(a, "8000::/1"));

	if (!default4 && !default6)
		return "not detected as a default-route client tunnel";

	return null;
}

function get_ipv4(iface) {
	let r = run([
		"ip", "-4", "-o", "addr", "show",
		"dev", iface, "scope", "global"
	]);

	if (r.rc != 0)
		return null;

	let m = match(
		r.out,
		/\sinet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\/([0-9]+)/
	);

	if (!m)
		return null;

	return { address: m[1], prefix: int(m[2]) };
}

function derive_private_gateway(addr) {
	let m = match(
		addr,
		/^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/
	);

	if (!m)
		return null;

	let a = int(m[1]);
	let b = int(m[2]);
	let c = int(m[3]);

	let private4 =
		a == 10 ||
		(a == 172 && b >= 16 && b <= 31) ||
		(a == 192 && b == 168);

	if (!private4)
		return null;

	return sprintf("%d.%d.%d.1", a, b, c);
}

function get_target(iface) {
	let explicit = cfg(iface, "target", "");

	if (length(explicit))
		return explicit;

	let info = get_ipv4(iface);

	if (info != null) {
		let gw = derive_private_gateway(info.address);

		if (gw != null)
			return gw;
	}

	return "1.1.1.1";
}

function measure(iface, target, count) {
	let r = run([
		"ping", "-I", iface,
		"-c", sprintf("%d", count),
		"-W", "1",
		target
	]);

	let loss = 100;
	let avg = 999999.0;

	let lm = match(r.out, /([0-9]+)% packet loss/);

	if (lm)
		loss = int(lm[1]);

	let rm = match(
		r.out,
		/= [0-9.]+\/([0-9.]+)\/[0-9.]+/
	);

	if (rm)
		avg = rm[1] * 1.0;

	return { loss: loss, avg: avg };
}

function set_port(iface, port) {
	let r = run([
		"awg", "set", iface,
		"listen-port", sprintf("%d", port)
	]);

	if (r.rc != 0)
		log(iface + ": awg set listen-port " + port + " failed rc=" + r.rc);

	return r.rc == 0;
}

function port_used_by_other(iface, port) {
	for (let other in get_interfaces()) {
		if (other == iface)
			continue;

		if (get_listen_port(other) == port)
			return true;
	}

	return false;
}

function candidate_port(base, offset) {
	let port = base + offset;

	if (port > 65535)
		port = 40000 + offset;

	return port;
}

function is_better(candidate, best) {
	if (best == null)
		return true;

	if (candidate.loss != best.loss)
		return candidate.loss < best.loss;

	return candidate.avg < best.avg;
}

function state_for(iface) {
	if (states[iface] == null) {
		states[iface] = {
			base_port: null,
			best_port: null,
			best_rtt: null,
			best_loss: null,
			last_scan: 0,
			bad_checks: 0,
			target: null
		};
	}

	return states[iface];
}

function choose_target(iface) {
	let explicit = cfg(iface, "target", "");

	if (length(explicit))
		return explicit;

	let target = get_target(iface);

	if (target == "1.1.1.1")
		return target;

	let probe = measure(iface, target, 2);

	if (probe.loss < 100)
		return target;

	let fallback = measure(iface, "1.1.1.1", 2);

	if (fallback.loss < 100) {
		log(iface + ": inferred target " + target + " does not answer; using 1.1.1.1");
		return "1.1.1.1";
	}

	/* Keep the tunnel-local guess: if every candidate fails it will be restored. */
	return target;
}

function scan(iface, state, reason) {
	let current = get_listen_port(iface);

	if (current == null) {
		log(iface + ": cannot read listen port");
		return false;
	}

	ctx.load("network");
	ctx.load(CONFIG);

	state.base_port = get_base_port(iface, current);
	state.target = choose_target(iface);

	let count = cfg_int("main", "scan_count", 8);
	let candidates = cfg_int("main", "candidate_count", 5);
	let settle_ms = cfg_int("main", "settle_ms", 300);

	log(
		iface +
		": scan reason=" + reason +
		" target=" + state.target +
		" base=" + state.base_port +
		" current=" + current
	);

	let best = null;

	for (let i = 0; i < candidates; i++) {
		let port = candidate_port(state.base_port, i);

		if (port_used_by_other(iface, port)) {
			log(iface + ": candidate port=" + port + " skipped: used by another AWG interface");
			continue;
		}

		if (!set_port(iface, port))
			continue;

		sleep(settle_ms);

		/* First packet after changing the source port is only a warm-up. */
		measure(iface, state.target, 1);

		let result = measure(iface, state.target, count);

		log(
			iface +
			": candidate port=" + port +
			" loss=" + result.loss + "%" +
			" avg=" + sprintf("%.3f", result.avg) + "ms"
		);

		let candidate = {
			port: port,
			loss: result.loss,
			avg: result.avg
		};

		if (is_better(candidate, best))
			best = candidate;
	}

	state.last_scan = time();
	state.bad_checks = 0;

	if (best == null || best.loss >= 100) {
		log(iface + ": no working candidate; restoring port=" + current);
		set_port(iface, current);
		return false;
	}

	if (!set_port(iface, best.port)) {
		log(iface + ": failed to apply selected port; restoring port=" + current);
		set_port(iface, current);
		return false;
	}

	state.best_port = best.port;
	state.best_rtt = best.avg;
	state.best_loss = best.loss;

	log(
		iface +
		": SELECTED port=" + best.port +
		" loss=" + best.loss + "%" +
		" avg=" + sprintf("%.3f", best.avg) + "ms"
	);

	return true;
}

function check(iface) {
	let skip = client_skip_reason(iface);

	if (skip != null) {
		if (skip_reasons[iface] != skip)
			log(iface + ": skip: " + skip);

		skip_reasons[iface] = skip;
		return;
	}

	if (skip_reasons[iface] != null)
		log(iface + ": became eligible for optimization");

	skip_reasons[iface] = null;

	let state = state_for(iface);
	let current = get_listen_port(iface);

	if (current == null)
		return;

	if (state.best_port == null) {
		scan(iface, state, "initial");
		return;
	}

	/*
	 * netifd or an operator may recreate/change the interface. Do not blindly
	 * overwrite that choice: use the configured/observed port as the baseline
	 * and re-evaluate its candidate set.
	 */
	if (current != state.best_port) {
		log(
			iface +
			": listen port changed externally " +
			state.best_port + " -> " + current +
			"; rescanning"
		);

		state.base_port = null;
		state.best_port = null;
		state.best_rtt = null;
		state.best_loss = null;
		state.bad_checks = 0;

		scan(iface, state, "external-port-change");
		return;
	}

	let target = state.target != null ? state.target : choose_target(iface);
	let count = cfg_int("main", "check_count", 5);
	let result = measure(iface, target, count);

	let loss_trigger = cfg_int("main", "loss_trigger", 20);
	let rtt_trigger = cfg_int("main", "rtt_trigger_ms", 25);
	let bad_required = cfg_int("main", "bad_checks_required", 2);
	let cooldown = cfg_int("main", "scan_cooldown", 300);
	let periodic = cfg_int("main", "periodic_rescan", 0);

	let degraded = false;
	let reason = "";

	if (result.loss >= loss_trigger) {
		degraded = true;
		reason = "loss=" + result.loss + "%";
	}
	else if (
		state.best_rtt != null &&
		result.avg < 999999 &&
		result.avg > state.best_rtt + rtt_trigger
	) {
		degraded = true;
		reason =
			"rtt=" + sprintf("%.3f", result.avg) +
			"ms best=" + sprintf("%.3f", state.best_rtt) + "ms";
	}

	if (degraded)
		state.bad_checks++;
	else
		state.bad_checks = 0;

	log(
		iface +
		": health port=" + current +
		" target=" + target +
		" loss=" + result.loss + "%" +
		" avg=" + sprintf("%.3f", result.avg) + "ms" +
		" bad=" + state.bad_checks + "/" + bad_required
	);

	let age = time() - state.last_scan;
	let immediate = result.loss >= 100;
	let confirmed = state.bad_checks >= bad_required;
	let periodic_due = periodic > 0 && age >= periodic;

	if (!immediate && !confirmed && !periodic_due)
		return;

	if (age < cooldown) {
		log(iface + ": rescan suppressed by cooldown; age=" + age + "s");
		return;
	}

	if (immediate)
		reason = "100% loss";
	else if (periodic_due && !degraded)
		reason = "periodic";

	scan(iface, state, reason);
}

ctx.load(CONFIG);
ctx.load("network");

if (cfg("main", "enabled", "1") == "0") {
	log("disabled by UCI");
	exit(0);
}

let interval = cfg_int("main", "check_interval", 60);

log(
	"started interval=" + interval + "s" +
	" candidates=" + cfg_int("main", "candidate_count", 5) +
	" scan_count=" + cfg_int("main", "scan_count", 8)
);

while (true) {
	ctx.load(CONFIG);
	ctx.load("network");

	for (let iface in get_interfaces())
		check(iface);

	sleep(interval * 1000);
}
