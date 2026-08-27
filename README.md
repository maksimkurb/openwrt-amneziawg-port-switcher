# AWG Path Optimizer

Small OpenWrt 25.12+ service that monitors active AmneziaWG client tunnels and
changes only their **runtime UDP listen/source port** to try different
flow-hash/ECMP paths.

It was built for the case where changing an AWG source port changes RTT and/or
packet loss while the server, tunnel crypto, and OpenWrt interface remain healthy.

## Safety model

The service automatically touches an interface only when all of these are true:

- it is returned by `awg show interfaces`;
- the link is UP;
- it has exactly one peer;
- that peer has an endpoint;
- its AllowedIPs look like a default-route client:
  `0.0.0.0/0`, `0.0.0.0/1 + 128.0.0.0/1`, `::/0`, or
  `::/1 + 8000::/1`.

Multi-peer/server interfaces are not optimized automatically.

For a non-standard client tunnel, add a named UCI section matching the interface:

```sh
uci set awg_path_optimizer.vpn_servitro=tunnel
uci set awg_path_optimizer.vpn_servitro.force='1'
uci set awg_path_optimizer.vpn_servitro.target='10.9.9.1'
uci set awg_path_optimizer.vpn_servitro.base_port='54001'
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

`owfeed check` validates the package using throwaway keys. Then the workflow
removes the check output and runs a clean `owfeed build`, uploading:

```text
dist/noarch/awg-path-optimizer-<version>.apk
```

as the `awg-path-optimizer-apk` Actions artifact.

The artifact produced by this simple build workflow is not signed with your own
persistent key. For direct local testing:

```sh
apk add --allow-untrusted ./awg-path-optimizer-0.1.0-r1.apk
```

For public distribution, add an EC signing key and use `owfeed sign` or
owfeed's reusable author-side `package.yml` release workflow instead of asking
users to use `--allow-untrusted`.

## Update version

Edit `VERSION`, for example:

```text
0.1.1-r1
```

Then push. The workflow builds the new noarch APK.
