'use strict';
import { popen } from 'fs';
const SERVICE = '/etc/init.d/awg-path-optimizer';
function command(cmd) {
	let p = popen(cmd, 'r');
	if (!p)
		return '';
	let out = p.read('all') ?? '';
	p.close();
	return trim(out);
}
function interfaces() {
	return split(command('awg show interfaces'), /\s+/);
}
function valid_interface(iface) {
	for (let candidate in interfaces())
		if (candidate == iface && match(iface, /^[A-Za-z0-9_.-]+$/))
			return true;
	return false;
}
function state() {
	let ifaces = [];
	for (let iface in interfaces()) {
		if (!length(iface))
			continue;
		let endpoint = split(command('awg show ' + iface + ' endpoints'), /\s+/)[1] ?? '-';
		push(ifaces, {
			name: iface,
			port: command('awg show ' + iface + ' listen-port') || '-',
			endpoint
		});
	}
	return {
		running: system(SERVICE + ' running >/dev/null 2>&1') == 0,
		interfaces: ifaces,
		recent_log: command("logread | grep 'awg-path-opt' | tail -n 20")
	};
}
function render(message) {
	include('awg_path_optimizer/index', {
		...state(),
		message,
		action_base: http.getenv('SCRIPT_NAME') + '/admin/services/awg-path-optimizer/action'
	});
}
return {
	index: function() {
		render();
	},
	action: function(_env, action) {
		let message;
		if (action == 'start' || action == 'stop' || action == 'recheck') {
			let command = action == 'recheck' ? 'restart' : action;
			message = system(SERVICE + ' ' + command) == 0 ?
				'Service ' + command + ' requested.' :
				'Service ' + command + ' failed.';
		}
		else if (action == 'set-port') {
			let iface = http.formvalue('iface');
			let port = int(http.formvalue('port'));
			if (!valid_interface(iface))
				message = 'Unknown interface.';
			else if (port < 1 || port > 65535)
				message = 'Port must be between 1 and 65535.';
			else
				message = system('awg set ' + iface + ' listen-port ' + port) == 0 ?
					iface + ': listen port changed to ' + port + '.' :
					iface + ': failed to change listen port.';
		}
		else {
			message = 'Unknown action.';
		}
		render(message);
	}
};
