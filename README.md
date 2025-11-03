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
