# Tailscale

An Elixir wrapper for [Tailscale](https://tailscale.com), providing a supervised GenServer to manage the `tailscaled` daemon and execute CLI commands.

## Features

- 🚀 **Supervised daemon management** - Full lifecycle control via `MuonTrap`
- 🔌 **Custom socket paths** - Works in embedded/Nerves environments
- ⏱️ **Configurable timeouts** - Prevent hanging commands
- 📦 **Linux binary installer** - Detects the runtime ABI and installs verified, pinned binaries
- 🌐 **Typed route preferences** - Configures, reads, and reconciles subnet routing state

## Installation

```elixir
def deps do
  [
    {:tailscale, github: "sid2baker/tailscale_ex"}
  ]
end
```

## Quick Start

### Basic Usage

```elixir
# Start the Tailscale GenServer
{:ok, pid} = Tailscale.start_link()

# Check if online
Tailscale.online?()
# => false

# Get status as a map
{:ok, status} = Tailscale.status()

# Register device with auth-key
{:ok, _} = Tailscale.login("your-auth-key")

# Execute CLI commands
{:ok, ips} = Tailscale.cli("ip", [])
```

### Supervised Usage

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Tailscale,
        name: Tailscale,
        tailscale_dir: "/data/tailscale",
        socket_path: "/tmp/tailscale.sock"}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Configuration Options

| Option           | Default                           | Description                  |
|------------------|-----------------------------------|------------------------------|
| `:name`          | `Tailscale`                       | GenServer name               |
| `:daemon_path`   | `/usr/sbin/tailscaled`            | Path to daemon binary        |
| `:cli_path`      | `/usr/bin/tailscale`              | Path to CLI binary           |
| `:start_daemon`  | `true`                            | Manage a daemon or use an existing one |
| `:socket_path`   | `/run/tailscale/tailscaled.sock`  | Unix socket path             |
| `:tailscale_dir` | `/data/tailscale`                 | State directory              |
| `:tun`           | `:kernel`                         | Kernel, userspace, or custom TUN interface |
| `:timeout`       | `5_000`                           | Command timeout (ms)         |

## Installing Linux binaries dynamically

`Tailscale.Binary` can detect the ABI of the running Linux BEAM and install a
pinned Tailscale release. Installation is explicit and never happens as a side
effect of `Tailscale.start_link/1`:

```elixir
{:ok, binaries} =
  Tailscale.Binary.ensure_installed(
    version: "1.102.3",
    install_dir: "/data/tailscale/bin"
  )

{:ok, pid} =
  Tailscale.start_link(
    daemon_path: binaries.daemon_path,
    cli_path: binaries.cli_path
  )
```

The installer supports Tailscale's Linux `amd64`, `386`, `arm`, `arm64`,
`mips`, `mipsle`, `mips64`, `mips64le`, and `riscv64` archives. It uses the
BEAM runtime ABI rather than the physical CPU, downloads both binaries from the
official stable package repository, verifies the published SHA-256 checksum,
and atomically caches them by version and architecture.

An exact `:version` is required. You can provide an independently trusted
checksum with `sha256: "..."`, or a custom CA bundle with
`cacertfile: "/path/to/cacerts.pem"`. The installation directory must be
persistent and writable. For reproducible Nerves production firmware, bundling
pinned binaries at build time remains preferable to downloading them during
boot.

## Linux subnet routing

Linux must enable kernel forwarding before Tailscale can route advertised
subnets. The top-level API can inspect and enable it for the current boot:

```elixir
{:ok, %{ipv4: false, ipv6: false}} = Tailscale.forwarding_status()
:ok = Tailscale.enable_forwarding()
```

On a conventional writable Linux system, persist the settings in an idempotent
`/etc/sysctl.d/99-tailscale.conf` as well:

```elixir
:ok = Tailscale.enable_forwarding(persist: :sysctl_d)
```

The calling OS process must have permission to write `/proc` and, when
requested, `/etc/sysctl.d`. The library never invokes `sudo`.

Advertise IPv4 or IPv6 CIDRs after the node is authenticated:

```elixir
:ok =
  Tailscale.set(
    advertise_routes: [
      "192.168.1.0/24",
      "10.0.0.0/24"
    ]
  )
```

`set/1` validates, canonicalizes, and deduplicates CIDRs. It invokes
`tailscale set`, so preferences not explicitly supplied remain unchanged. Pass
an empty list to withdraw every advertised route:

```elixir
:ok = Tailscale.set(advertise_routes: [])
```

Read back configured preferences or compare local configuration with the
control-plane view:

```elixir
{:ok, %Tailscale.Preferences{advertised_routes: routes}} =
  Tailscale.preferences()

{:ok, %{advertised: advertised, approved: approved, primary: primary}} =
  Tailscale.route_status()
```

Routes must still be approved in the Tailscale admin console or by suitable
`autoApprovers` policy. Forwarding configuration is deliberately separate from
preference updates, allowing desired settings to be persisted and reconciled
independently.

## Nerves Integration

For embedded/Nerves projects:

```elixir
{Tailscale,
  name: Tailscale,
  daemon_path: "/data/tailscaled",
  cli_path: "/data/tailscale",
  socket_path: "/run/tailscale/tailscale.sock",
  tailscale_dir: "/data/tailscale",
  tun: :kernel}
```

Kernel TUN mode is the default. It follows the upstream `tailscaled` default interface (`tailscale0`) by omitting the `--tun` flag. This is the recommended mode for a Nerves subnet router because it supports all IP protocols and uses the Linux routing stack.

The Nerves system must include kernel TUN support (`CONFIG_TUN`) and expose
`/dev/net/tun`. Since `/etc` may be immutable, enable forwarding during each
boot before advertising routes:

```elixir
:ok = Tailscale.enable_forwarding()
:ok = Tailscale.await_ready(timeout: 10_000)
:ok = Tailscale.set(advertise_routes: ["192.168.1.0/24", "10.0.0.0/24"])
```

`await_ready/1` only waits for the daemon socket to accept commands. It also
succeeds in pre-enrollment states such as `NeedsLogin`.

If a target has no TUN device, explicitly select netstack mode with
`tun: :userspace`. A custom kernel interface name such as `tun: "ts-nerves0"`
is also supported.

## Testing

Unit tests use mock `tailscale` and `tailscaled` binaries and do not require a tailnet:

```bash
mix ci
```

The integration test uses the installed Tailscale CLI and a real, connected daemon. It exercises this library's version parsing, JSON status parsing, online detection, and IP command handling:

```bash
mix test --only integration test/integration/tailscale_integration_test.exs
```

The test defaults to `/var/run/tailscale/tailscaled.sock`. Set `TAILSCALE_SOCKET` or `TAILSCALE_CLI_PATH` when reproducing against a non-default local installation. The test attaches with `start_daemon: false`, so it does not stop or replace the machine's existing daemon.

### Tailscale compatibility CI

`.github/workflows/ci.yml` runs the unit suite independently and then uses `tailscale/github-action@v4` to create an ephemeral `tag:ci` node. Pull requests are tested against `version: latest`; a separate `unstable` matrix entry is an allowed-to-fail early warning.

The action authenticates with GitHub OIDC workload identity federation. Maintainers must configure these GitHub Actions secrets:

- `TS_OAUTH_CLIENT_ID` — the Tailscale federated identity client ID
- `TS_AUDIENCE` — its configured audience

The Tailscale trust credential must have writable `auth_keys` scope and permission to create nodes tagged `tag:ci`. The workflow requests `id-token: write`; no reusable auth key or OAuth client secret is stored in the repository. The action marks its node ephemeral and logs it out after the job.

## Troubleshooting

### Daemon won't start

Check that:
- Binaries exist and are executable
- Socket directory is writable
- State directory is writable
- No other Tailscale instance is using the same socket
- `/dev/net/tun` exists when using the default `:kernel` mode

### Commands timeout

Increase the timeout in configuration:

```elixir
{Tailscale, timeout: 30_000}  # 30 seconds
```

### Permission errors on Nerves

Ensure binaries have execute permissions:

```bash
chmod +x /usr/sbin/tailscaled
chmod +x /usr/bin/tailscale
```

## License

Apache License 2.0
