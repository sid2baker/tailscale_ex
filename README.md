# Tailscale

An Elixir wrapper for [Tailscale](https://tailscale.com), providing a supervised GenServer to manage the `tailscaled` daemon and execute CLI commands.

## Features

- 🚀 **Supervised daemon management** - Full lifecycle control via `MuonTrap`
- 🔌 **Custom socket paths** - Works in embedded/Nerves environments
- ⏱️ **Configurable timeouts** - Prevent hanging commands

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
| `:timeout`       | `5_000`                           | Command timeout (ms)         |


## Nerves Integration

For embedded/Nerves projects:

```elixir
{Tailscale,
  name: Tailscale,
  daemon_path: "/data/tailscaled",
  cli_path: "/data/tailscale",
  socket_path: "/run/tailscale/tailscale.sock",
  tailscale_dir: "/data/tailscale"}
```

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
