# AWG Path Optimizer

Small OpenWrt 25.12+ service that monitors active AmneziaWG client tunnels and
changes only their **runtime UDP listen/source port** to try different
flow-hash/ECMP paths.

It was built for the case where changing an AWG source port changes RTT and/or
packet loss while the server, tunnel crypto, and OpenWrt interface remain healthy.

## Install

On OpenWrt 25.12+, subscribe the router to the package feed, then install the
packages:

```sh
wget -qO- https://maksimkurb.github.io/openwrt-amneziawg-port-switcher/subscribe.sh | sh
apk add awg-path-optimizer luci-app-awg-path-optimizer
```

The status and controls page is under **Services → AWG Path Optimizer**.

## LuCI

luci-app-awg-path-optimizer shows the current service state, AWG interfaces,
listen ports, first-peer endpoints, and recent optimizer logs. The page
refreshes every 10 seconds and can start, stop, force a fresh optimizer pass,
or change an interface runtime listen port.

## Defaults

| Option | Default | Description |
|---|---|---|
| main.enabled | 1 | Starts the service at boot. |
| main.check_interval | 60 seconds | Time between normal health checks. |
| main.check_count | 5 | Ping samples in a health check. |
| main.scan_count | 8 | Ping samples for each candidate port. |
| main.candidate_count | 5 | Consecutive source ports to test. |
| main.loss_trigger | 20% | Loss percentage that marks a path degraded. |
| main.rtt_trigger_ms | 25 ms | RTT increase over the best path that marks it degraded. |
| main.bad_checks_required | 2 | Consecutive degraded checks required before rescanning. |
| main.scan_cooldown | 300 seconds | Minimum time between scans. |
| main.periodic_rescan | 0 | Healthy-path rescan interval; 0 disables it. |
| main.settle_ms | 300 ms | Wait after changing port before probing. |
| tunnel.enabled | 1 | Enables this interface for optimization. |
| tunnel.target | automatic | Ping destination; inferred tunnel gateway, then 1.1.1.1. |
| tunnel.base_port | automatic | Network configured port, otherwise current runtime port. |
| tunnel.peer_ip | first peer | Selects a peer by endpoint IP when set. |
| tunnel.force | 0 | Bypasses default-route client detection. |

## Safety model

The service automatically touches an interface only when all of these are true:

- it is returned by `awg show interfaces`;
- the link is UP;
- its first peer has an endpoint (or `peer_ip` selects a peer by endpoint IP);
- its AllowedIPs look like a default-route client:
  `0.0.0.0/0`, `0.0.0.0/1 + 128.0.0.0/1`, `::/0`, or
  `::/1 + 8000::/1`.

On multi-peer interfaces the first peer is selected by default. Set `peer_ip`
to select a particular endpoint IP; default-route detection then uses only that
peer's AllowedIPs. Multi-peer/server interfaces still need `force='1'` unless
the selected peer is a default-route client.

For a tunnel that is intentionally not a default-route client, force=1 is
required:

    uci set awg_path_optimizer.vpn_example=tunnel
    uci set awg_path_optimizer.vpn_example.force='1'
    uci commit awg_path_optimizer
    /etc/init.d/awg-path-optimizer restart

For a non-standard client tunnel, add a named UCI section matching the interface:

```sh
uci set awg_path_optimizer.vpn_servitro=tunnel
uci set awg_path_optimizer.vpn_servitro.force='1'
uci set awg_path_optimizer.vpn_servitro.target='10.9.9.1'
uci set awg_path_optimizer.vpn_servitro.base_port='54001'
# Optional: select a peer by its endpoint IP instead of the first peer.
uci set awg_path_optimizer.vpn_servitro.peer_ip='203.0.113.10'
uci commit awg_path_optimizer
/etc/init.d/awg-path-optimizer restart
```

## Selection algorithm

For each eligible tunnel:

1. Take `base_port` from the per-tunnel override, otherwise
   `network.<iface>.listen_port`, otherwise the current runtime port.
2. Test `candidate_count` consecutive source ports.
3. Rank candidates by:
   1. lowest packet loss;
   2. then lowest average RTT.
4. Apply the selected port with `awg set ... listen-port ...`.
5. Do **not** write the selected port back to UCI/flash.
6. Health-check every 60 seconds by default.
7. Re-scan after confirmed loss/RTT degradation, with cooldown.

The selected path is intentionally runtime-only. After reboot or netifd
recreation, the configured port comes back and the service re-optimizes it.

## Probe target

A per-tunnel `option target` is preferred.

Without one, the daemon tries to infer a private `.1` peer from the interface
IPv4 address, e.g. `10.9.9.6 -> 10.9.9.1`. If that inferred target does not
answer, it tries `1.1.1.1`.

For important tunnels, explicitly configure the tunnel-local target.

## OpenWrt commands

```sh
/etc/init.d/awg-path-optimizer status
awg-path-optimizer-status
logread -f | grep awg-path-opt
```

Force a fresh optimization pass by restarting the service:

```sh
/etc/init.d/awg-path-optimizer restart
```

Disable one tunnel:

```sh
uci set awg_path_optimizer.vpn_servitro=tunnel
uci set awg_path_optimizer.vpn_servitro.enabled='0'
uci commit awg_path_optimizer
/etc/init.d/awg-path-optimizer restart
```

## Package contents

```text
/etc/config/awg_path_optimizer
/etc/init.d/awg-path-optimizer
/usr/share/awg-path-optimizer/main.uc
/usr/sbin/awg-path-optimizer-status
```

Dependencies:

- `amneziawg-tools`
- `ucode`
- `ucode-mod-fs`
- `ucode-mod-uci`

## GitHub Actions / owfeed

The workflow uses `owfeed/owfeed/setup@v0.5.0`.

Pull requests run the complete owfeed pipeline with throwaway keys. Pushes and
manual runs build the feed, sign it with the private key in the
`OPENWRT_APK_SIGNING_KEY` GitHub Actions secret, index it, and publish it to
GitHub Pages at:

```text
https://maksimkurb.github.io/openwrt-amneziawg-port-switcher
```

The signing key is available only in the publish job; it never reaches the
build job or pull requests. The workflow also smoke-tests OpenWrt 25.12 before
deployment. For direct local testing:

```sh
apk add --allow-untrusted ./awg-path-optimizer-0.1.0-r1.apk
```

Install the corresponding public key from the feed on OpenWrt before using it.

## Update version

Edit `VERSION`, for example:

```text
0.1.1-r1
```

Then push. The workflow builds the new noarch APK.
