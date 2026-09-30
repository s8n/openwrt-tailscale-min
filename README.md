# openwrt-tailscale-min

Minimal `tailscaled` + `tailscale` CLI packaged for OpenWrt routers with
little flash (~8 MB free is enough) and RAM to spare. The daemon is stored
gzipped and unpacked to RAM at start; the CLI is downloaded to RAM on demand.
Build approach and feature set follow
<https://github.com/dhs26206/tailscale-archer-c6-v2>.

Defaults target `mipsel_24kc` (`GOARCH=mipsle GOMIPS=softfloat`), which covers
the `ramips` targets (MT7621, MT7620, MT76x8, RT305x). Other architectures
need only build args, e.g. `--build-arg GOARCH=mips --build-arg
PKG_ARCH=mips_24kc` for big-endian `ath79`. The reference repo's prebuilt
binaries are big-endian MIPS, so they won't run on `mipsel` boards.

## Build

Requires Docker with buildx, and openssl (to create the signing key).

```sh
./build.sh
```

The `tailscale` wrapper in the package downloads the CLI from this repo's
GitHub release for the tailscale version being built
(`https://github.com/s8n/openwrt-tailscale-min/releases/download/<TS_VERSION>/tailscale-cli`).
If you fork this, build with `--build-arg GITHUB_REPO=<you>/<repo>` (or
`--build-arg CLI_URL=<url>` for any other host) and publish your own release:
the wrapper checks the download against the checksum of the CLI built
alongside the package, so another build's CLI will be rejected.

Output in `dist/`:

| File | Notes |
|---|---|
| `tailscale-min-<version>-r<N>.apk` | OpenWrt package (see below) |
| `tailscale-min.pub.pem` | public key the package is signed with |
| `tailscaled-min` / `tailscaled-min.gz` | daemon, `featuretags --min --add=osrouter,ipnbus,advertiseexitnode` |
| `tailscale-cli` / `tailscale-cli.gz` | full-featured CLI (no omit tags) |
| `daemon-tags.txt` | exact `ts_omit_*` list used for the daemon |
| `SHA256SUMS` | checksums of the package and binaries |

Build args you can override (`./build.sh --build-arg NAME=value`):

| Arg | Default |
|---|---|
| `TS_VERSION` | `v1.102.5` |
| `GO_VERSION` | `1.26.6` (must satisfy tailscale's `go.mod`) |
| `TS_FEATURES` | `osrouter,ipnbus,advertiseexitnode` |
| `CLI_TAGS` | empty (full CLI) |
| `GOARCH` / `GOMIPS` | `mipsle` / `softfloat` |
| `PKG_ARCH` | `mipsel_24kc` (OpenWrt package arch) |
| `PKG_RELEASE` | `1` (bump when repackaging the same tailscale version) |
| `GITHUB_REPO` | `s8n/openwrt-tailscale-min` |
| `CLI_URL` | `https://github.com/${GITHUB_REPO}/releases/download/${TS_VERSION}/tailscale-cli` |

`patches/` is applied on top of the tailscale source. The single patch makes
the `ts_omit_unixsocketidentity` stub still detect Unix-socket connections;
without it the CLI gets `Access denied: status access denied` (reference
guide §8.2).

The package is signed with `keys/tailscale-min.pem`, which `build.sh`
generates on first run. Keep it to sign future builds; `keys/*.pem` other
than the public key is gitignored.

## The package

`tailscale-min` installs:

| Path | What |
|---|---|
| `/usr/lib/tailscale/tailscaled.gz` | the daemon, gzipped (~4.8 MB on flash) |
| `/etc/init.d/tailscale` | procd service: unpacks the daemon to `/tmp/tailscaled` on start, deletes it on stop |
| `/etc/config/tailscale` | UCI config, same options as OpenWrt's `tailscale` package plus `daemon_path`, `cli_path`, `cli_url`, `cli_sha256` |
| `/usr/sbin/tailscale` | CLI wrapper |
| `/etc/uci-defaults/90-tailscale-firewall` | adds the firewall zone on first install (runs once, then deleted) |

The init script, config and state path (`/etc/tailscale/tailscaled.state`)
match OpenWrt's own `tailscale` package, which this one conflicts with. The
daemon uses the default socket path, so the CLI needs no `--socket` flag.

The `tailscale` wrapper runs `/tmp/tailscale-cli` with all arguments passed
through, downloading the uncompressed CLI first if it's missing. The
download is checked against the sha256 of the CLI built alongside the
package, so a stale CLI is replaced after a package upgrade. After every run
it prints a reminder to stderr to delete the CLI (24 MB of RAM) once you're
done.

On first install the package adds a `tailscale` firewall zone containing
`tailscale0` (input/output/forward ACCEPT, masquerading and MSS clamping on)
and forwardings tailscale→wan (exit node), tailscale→lan (subnet routes) and
lan→tailscale. Without it fw4 rejects everything arriving on `tailscale0`,
because the interface isn't in any zone. The step is skipped on upgrades,
and when `tailscale0` already appears in the firewall config (e.g. you added
it to `lan` yourself). `apk del` removes the zone and forwardings again. To
restrict what the tailnet can reach, edit or delete the forwardings
(`firewall.tailscale_lan` etc.).

Package dependencies: `ca-bundle` (the daemon is built without baked-in TLS
roots) and `kmod-tun`.

## Install

Prebuilt packages for `mipsel_24kc` are attached to the
[releases](https://github.com/s8n/openwrt-tailscale-min/releases). For other
architectures, build your own (see above).

On the router, trust the signing key once, then install:

```sh
REL=https://github.com/s8n/openwrt-tailscale-min/releases/download/v1.102.5
wget $REL/tailscale-min.pub.pem -O /etc/apk/keys/tailscale-min.pem
wget $REL/tailscale-min-1.102.5-r1.apk -O /tmp/tailscale-min.apk
apk update                     # so kmod-tun can be resolved
apk add /tmp/tailscale-min.apk
rm /tmp/tailscale-min.apk
```

The service is enabled and started on install. To download the CLI from
somewhere else:

```sh
uci set tailscale.settings.cli_url='http://<host>/tailscale-cli'
uci commit tailscale
```

Then `tailscale up`.

To upgrade, `apk add` a newer build; the daemon is restarted on the new
binary.

## Testing without the router

The package was tested on the real OpenWrt 25.12.5 ramips/mt7621 rootfs
(extracted from a sysupgrade image, imported into Docker, and run under
qemu-user binfmt with procd as init): install, service start/stop/restart,
CLI download and checksum failure, firewall zone setup (checked with
`fw4 print`), upgrade and removal. qemu-user can't load nftables rules, so
the firewall itself hasn't been exercised with live traffic.
