# tailscale-userspace-installer

Run Tailscale on Linux **without root, without `/dev/net/tun`, and without a system-wide
daemon**. One command, everything under `$HOME`, uninstallable with one more command.

This is a drop-in replacement for `tailscale.com/install.sh` for environments where the
official installer cannot work: containers, unprivileged LXC, HPC clusters, locked-down
workstations, or any box where you are just a normal user.

```sh
curl -fsSL https://raw.githubusercontent.com/dhava-gautama/tailscale-userspace-installer/main/install.sh | sh
```

Join a tailnet in the same breath, mirroring the official one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/dhava-gautama/tailscale-userspace-installer/main/install.sh \
  | sh -s -- --auth-key=tskey-auth-xxxx --advertise-exit-node --ssh
```

After that, `tailscale` works like it always did:

```sh
tailscale status
tailscale up --ssh
tailscale ssh my-other-box
```

## How it works

The official installer unpacks packages, writes to `/usr/bin`, and registers a root
systemd service. This one does none of that:

1. downloads the **official static tarball** from `pkgs.tailscale.com` and verifies its
   published SHA-256,
2. unpacks `tailscale` and `tailscaled` into `~/.local/libexec/tailscale-userspace/<version>/`,
3. starts `tailscaled --tun=userspace-networking`, which uses a userspace TCP/IP stack
   (gVisor netstack) instead of a kernel TUN device, and exposes a SOCKS5/HTTP proxy,
4. installs a `tailscale` wrapper that auto-starts that daemon and then behaves exactly
   like the real CLI, plus a `tailscale-userspace` manager for the daemon itself.

Nothing is written outside your home directory. No command uses `sudo`.

## Requirements

- Linux (the static `tailscaled` builds are Linux-only; macOS/Windows should use the
  official apps), x86_64 / arm64 / arm / 386 / riscv64 / mips
- `curl`, `tar`, and `sh` — that is it; `jq` is not needed
- A tailnet auth key if you want to join unattended (otherwise `tailscale up` prints a
  login URL, which works fine too)

## Usage

### Install options

| Flag | Meaning |
| --- | --- |
| `--prefix DIR` | install prefix (default `~/.local`) |
| `--state-dir DIR` | state, socket and log directory (default `~/.local/state/tailscale-userspace`) |
| `--version VER`, `--track stable\|unstable` | which Tailscale build to install |
| `--arch ARCH` | override architecture detection |
| `--socks5 ADDR`, `--http-proxy ADDR` | proxy listeners (default `127.0.0.1:1055`; pass `--socks5=` to disable) |
| `--auth-key KEY` | join the tailnet during install (also read from `$TS_AUTHKEY` or `$TS_AUTH_KEY`) |
| `--shim` / `--no-shim` | install the `tailscale` wrapper (default: yes) |
| `--systemd` / `--no-systemd` | use a systemd user unit when available (default: auto) |
| `--linger` / `--no-linger` | try to enable systemd user lingering so the daemon starts at boot |
| `--no-start`, `--no-up` | install only; do not start the daemon / do not join |

Any other flag is passed through to `tailscale up`, so `--ssh`,
`--advertise-exit-node`, `--hostname=box`, `--advertise-tags=tag:ci` and friends all
work. Use the `--flag=value` form, or put them after `--` to use the space-separated form.

### Manager commands

```sh
tailscale-userspace start | stop | restart | status | logs [-f] | is-running
tailscale-userspace up --auth-key=tskey-auth-... --advertise-exit-node --ssh
tailscale-userspace down | logout
tailscale-userspace env            # print proxy environment exports
tailscale-userspace run <cmd...>   # run a command with the proxy environment set
tailscale-userspace shell          # subshell with the proxy environment set
tailscale-userspace version | uninstall [--purge]
```

### Using the tailnet from other programs

This is the part people trip over: **userspace mode is proxy-mediated**. There is no
kernel route to `100.64.0.0/10`, so a program only reaches the tailnet if it speaks
SOCKS5/HTTP through the proxy:

```sh
export ALL_PROXY=socks5://127.0.0.1:1055/          # or: eval "$(tailscale-userspace env)"
curl -x socks5h://127.0.0.1:1055 http://my-box:8080/
tailscale-userspace run ssh user@my-box            # runs ssh with the proxy set
```

MagicDNS names resolve *through the proxy* (tailscaled does the lookup itself), but the
system resolver is not pointed at Tailscale, so `ping my-box` and `ssh my-box` from a
plain shell will not work unless the program is proxy-aware. `tailscale ssh`, `tailscale
ping`, `tailscale status` and `tailscale file` all work normally, because they talk to
`tailscaled` over its own socket rather than over the network.

### Inbound connections

Inbound TCP from a peer to *this node's* tailnet IP is forwarded by netstack to
`127.0.0.1` on the same port, so a service is reachable at `100.x.y.z:8080` if and only
if something is listening on `127.0.0.1:8080` (loopback binding is enough). Ports that
`tailscaled` serves itself — 22 with `--ssh`, 53 for DNS, the peer API — are handled
in-process instead. Inbound UDP other than DNS/peer API is not forwarded.

## What works and what does not

Userspace mode is a real Tailscale node, not a stripped-down imitation, but it is not
transparent VPN. Verified against Tailscale's documentation and source:

| Capability | Status |
| --- | --- |
| `tailscale status`, `ping`, `ssh`, `netcheck`, `file` (Taildrop) | works |
| `tailscale up --ssh` — Tailscale SSH server | works (handled in-process by tailscaled; as a non-root daemon it can only spawn processes as your user) |
| `--advertise-exit-node` | advertises fine; transit works via netstack, but ICMP/ping through it is unreliable and the exit node must be approved in the admin console before other devices can select it |
| `--advertise-routes` (subnet router) | works for TCP/UDP; advertised subnets are not necessarily pingable, and are not reachable through the local SOCKS5 proxy |
| `--accept-routes` | meaningless — there is no TUN device to install routes into |
| OS-level MagicDNS | does not work (the DNS manager is a no-op); names resolve only via the proxy |
| Transparent routing for arbitrary apps (browsers, `ping`, plain `ssh`) | does not work — use the proxy, or `tailscale ssh` as a client |
| system-wide VPN for other users or system services | no; this is a per-user, per-process install |

Sources: [Userspace networking mode](https://tailscale.com/kb/1112/userspace-networking),
[netstack.go](https://github.com/tailscale/tailscale/blob/main/wgengine/netstack/netstack.go),
[issue #4012](https://github.com/tailscale/tailscale/issues/4012),
[issue #5233](https://github.com/tailscale/tailscale/issues/5233),
[issue #16713](https://github.com/tailscale/tailscale/issues/16713),
[issue #17167](https://github.com/tailscale/tailscale/issues/17167).

### What this repo has actually been tested against

Measured, not assumed (see `tests/smoke.sh`, run with the static 1.102.4 build):

- install, checksum verification, daemon start/stop/restart, uninstall — all pass
- `tailscale up --auth-key=... --advertise-exit-node --ssh` joins the tailnet and sets
  `RunSSH` plus `AdvertiseRoutes: 0.0.0.0/0, ::/0`
- `tailscale ping <peer>` gets pongs over the userspace WireGuard stack
- `nc -X 5 -x 127.0.0.1:1055 <node>.tailnet.ts.net 22` completes a SOCKS5 handshake,
  resolves the MagicDNS name and reaches the node's Tailscale SSH server
  (`SSH-2.0-Tailscale` banner)
- the systemd user unit path is implemented but was not exercised on the test host,
  which has no user systemd session; that host falls back to a background process

Not tested here: actual packet transit *through* a userspace exit node, Taildrop, and
subnet-router traffic from a remote peer.

## Upgrading and uninstalling

Re-run the same command (or `install.sh --version=1.104.0`): the new version is unpacked
alongside the old one, the `current` symlink is repointed, and a running daemon is
restarted onto it. The previous version directory stays behind; delete it if you want.

```sh
tailscale-userspace uninstall           # remove wrappers, binaries, unit; keep state
tailscale-userspace uninstall --purge    # also delete the node key, state and logs
tailscale logout                         # expire the node key before you walk away
```

## Security notes

- **Never commit an auth key.** Pass it via `--auth-key`, `$TS_AUTHKEY`, or
  `--auth-key=file:/path/to/key`. Both this installer and the manager convert a bare key
  into a temporary `file:` reference so it does not show up in `ps`.
- Auth keys are reusable credentials for your whole tailnet. Use a dedicated, tagged,
  ideally ephemeral key for unattended installs, and rotate it if it leaks.
- The daemon's state directory is created with mode `0700`; the node key lives there.
- The proxy listens on `127.0.0.1` by default. If you bind it to a wider address, anyone
  who can reach that port can reach your tailnet.

## If you already run a system-wide Tailscale

The two can coexist — this install uses its own socket and state, and registers a
*separate node*. But the wrapper is only found first if `~/.local/bin` precedes
`/usr/bin` in `PATH`, and the system daemon's TUN device will also provide real routes
to the tailnet, which can hide the proxy-only limitation above. The installer warns when
it detects either situation.

## Layout

```
install.sh                     the installer (curl | sh)
bin/tailscale-userspace        daemon manager: start/stop/up/env/uninstall
bin/tailscale                  the CLI wrapper (auto-starts the daemon)
tests/smoke.sh                 end-to-end test in a throwaway prefix
```

Runtime layout after install:

```
~/.local/bin/tailscale                        wrapper (and tailscale-userspace)
~/.local/libexec/tailscale-userspace/<ver>/   official static binaries
~/.local/state/tailscale-userspace/           node key, state, socket, log
~/.config/tailscale-userspace/config          settings written by install.sh
~/.config/systemd/user/tailscaled-userspace.service   only when systemd is used
```

## License

MIT — see [LICENSE](LICENSE). Tailscale itself is a separate product under its own
licenses; this project only downloads and drives its official binaries.
