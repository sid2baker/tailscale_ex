# Tailscale

[![Hex.pm](https://img.shields.io/hexpm/v/tailscale.svg)](https://hex.pm/packages/tailscale)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/tailscale)

An Elixir wrapper for [Tailscale](https://tailscale.com), providing a supervised GenServer to manage the `tailscaled` daemon and a comprehensive API for all Tailscale CLI commands.

**Designed with [Nerves](https://nerves-project.org/) in mind**, but works equally well in standard Elixir applications.

## Features

- 🚀 **Supervised daemon management** - Full lifecycle control of `tailscaled` via `MuonTrap`
- 🔌 **Custom socket paths** - No permission issues, works in embedded environments
- ⏱️ **Configurable timeouts** - Prevent hanging commands with `MuonTrap.cmd`
- 🎯 **Complete CLI coverage** - All ~25 Tailscale commands wrapped
- 🧪 **Mock-based testing** - No Tailscale installation required for tests
- 📝 **Full typespecs** - Complete type documentation
- 🎛️ **Flexible configuration** - Customize paths, sockets, and state directories

## Why Nerves?

This library uses `MuonTrap` for process supervision, which is the standard in Nerves for managing OS processes. Features like custom socket paths and state directories make it ideal for embedded Linux devices where:

- You may not have `/var/run` available
- You need full control over daemon lifecycle
- You want everything supervised under your application tree
- You're running without systemd or other init systems

However, it works just as well on your development machine or in production Elixir applications!

## Installation

Add `tailscale` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tailscale, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Basic Usage

```elixir
# Start the Tailscale GenServer
{:ok, pid} = Tailscale.start_link(name: Tailscale)

# Check version
{:ok, version} = Tailscale.version()
# => "1.88.3"

# Check if online
Tailscale.online?()
# => false (not logged in yet)

# Connect to your Tailnet
Tailscale.CLI.up(Tailscale, hostname: "my-device", accept_routes: true)

# Get status
{:ok, status} = Tailscale.CLI.status(Tailscale, json: true)

# Get IPs
{:ok, ips} = Tailscale.CLI.ip(Tailscale)
# => ["100.64.0.1", "fd7a:115c:a1e0::1"]
```

### Supervised Usage (Recommended)

Add Tailscale to your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # ... other children
      {Tailscale, name: Tailscale, tailscale_dir: "/data/tailscale"}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Nerves Configuration

For Nerves projects, customize paths to fit your rootfs:

```elixir
children = [
  {Tailscale,
   name: Tailscale,
   daemon_path: "/usr/sbin/tailscaled",
   cli_path: "/usr/bin/tailscale",
   socket_path: "/tmp/tailscale.sock",
   tailscale_dir: "/root/tailscale"}
]
```

## Configuration Options

All options are passed to `start_link/1`:

| Option           | Description                          | Default                           |
|------------------|--------------------------------------|-----------------------------------|
| `:name`          | GenServer name                       | `Tailscale`                       |
| `:daemon_path`   | Path to `tailscaled` binary          | `/usr/sbin/tailscaled`            |
| `:cli_path`      | Path to `tailscale` CLI              | `/usr/bin/tailscale`              |
| `:socket_path`   | Unix socket path                     | `/tmp/tailscale/tailscaled.sock`  |
| `:tailscale_dir` | State directory                      | `/tmp/tailscale`                  |

## API Documentation

### Main Module (`Tailscale`)

Convenience functions for common operations:

```elixir
# Check if connected and online
Tailscale.online?()
# => true | false

# Get Tailscale version
{:ok, version} = Tailscale.version()

# Get daemon PID
{:ok, pid} = Tailscale.daemon_pid()
```

### CLI Module (`Tailscale.CLI`)

All Tailscale CLI commands are available as functions. Each function takes the server name as the first argument.

#### Connection Management

```elixir
# Connect to Tailscale
Tailscale.CLI.up(Tailscale, 
  hostname: "my-device",
  auth_key: "tskey-...",
  accept_routes: true,
  timeout: 60_000  # optional timeout in ms
)

# Disconnect
Tailscale.CLI.down(Tailscale)

# Login
Tailscale.CLI.login(Tailscale, auth_key: "tskey-...")

# Logout
Tailscale.CLI.logout(Tailscale)

# Switch accounts
Tailscale.CLI.switch(Tailscale)
```

#### Status & Information

```elixir
# Get status (JSON)
{:ok, status} = Tailscale.CLI.status(Tailscale, json: true)

# Get status (text)
{:ok, status} = Tailscale.CLI.status(Tailscale, [])

# Get status with peers
{:ok, status} = Tailscale.CLI.status(Tailscale, peers: true)

# Get IP addresses
{:ok, ips} = Tailscale.CLI.ip(Tailscale)

# Get version
{:ok, version} = Tailscale.CLI.version(Tailscale)

# Network check
{:ok, report} = Tailscale.CLI.netcheck(Tailscale)
```

#### Configuration

```elixir
# Set preferences
Tailscale.CLI.set(Tailscale, hostname: "new-name")

# Configure host features
Tailscale.CLI.configure(Tailscale, ["route-all", "on"])
```

#### Network Operations

```elixir
# Ping a peer
{:ok, result} = Tailscale.CLI.ping(Tailscale, "100.64.0.1", [])

# WhoIs lookup
{:ok, info} = Tailscale.CLI.whois(Tailscale, "100.64.0.1", json: true)

# Get exit nodes
{:ok, nodes} = Tailscale.CLI.exit_node(Tailscale, json: true)
```

#### File Sharing

```elixir
# Send a file
Tailscale.CLI.file(Tailscale, ["cp", "document.pdf", "hostname:"])

# Receive files
Tailscale.CLI.file(Tailscale, ["get", "/tmp"])
```

#### Advanced Features

```elixir
# Serve HTTP
Tailscale.CLI.serve(Tailscale, ["443", "http://localhost:3000"])

# Enable Funnel (public internet)
Tailscale.CLI.funnel(Tailscale, ["443", "on"])

# SSH to peer
Tailscale.CLI.ssh(Tailscale, "hostname", [])

# Manage Tailnet lock
Tailscale.CLI.lock(Tailscale, ["status"])

# Get certificates
Tailscale.CLI.cert(Tailscale, "mydevice.example.ts.net")
```

### Timeout Handling

All CLI commands support a `:timeout` option (defaults to 30 seconds):

```elixir
# Quick commands
{:ok, ips} = Tailscale.CLI.ip(Tailscale)

# Potentially slow commands with custom timeout
Tailscale.CLI.up(Tailscale, 
  hostname: "device",
  timeout: 120_000  # 2 minutes
)

# Handle timeout errors
case Tailscale.CLI.exec_command(Tailscale, ["status"], timeout: 1000) do
  {:ok, output} -> 
    IO.puts("Success: #{output}")
    
  {:error, {:timeout, partial_output}} -> 
    IO.puts("Command timed out! Got: #{partial_output}")
    
  {:error, {exit_code, output}} -> 
    IO.puts("Failed with exit code #{exit_code}: #{output}")
end
```

## Error Handling

Commands return `{:ok, result}` or `{:error, reason}` tuples:

```elixir
case Tailscale.CLI.status(Tailscale, json: true) do
  {:ok, status} ->
    # Success - status is a parsed map
    IO.inspect(status)
    
  {:error, {exit_code, output}} ->
    # Command failed
    Logger.error("Status failed (#{exit_code}): #{output}")
    
  {:error, {:timeout, partial}} ->
    # Command timed out
    Logger.error("Status timed out: #{partial}")
end
```

## Testing

The library includes mock Tailscale binaries for testing without requiring actual Tailscale installation:

```elixir
# In your tests
setup do
  %{cli_path: cli_path, daemon_path: daemon_path, test_dir: mock_dir} =
    MockTailscale.create_mocks()

  opts = [
    name: :test_tailscale,
    daemon_path: daemon_path,
    cli_path: cli_path,
    socket_path: "/tmp/test.sock",
    tailscale_dir: "/tmp/test"
  ]

  {:ok, server} = Tailscale.start_link(opts)

  on_exit(fn ->
    if Process.alive?(server), do: GenServer.stop(server)
    MockTailscale.cleanup_mocks(mock_dir)
  end)

  %{server: server}
end

test "status returns data", %{server: server} do
  assert {:ok, status} = Tailscale.CLI.status(server, json: true)
  assert is_map(status)
end
```

Run tests:

```bash
mix test
```

## Examples

### Unattended Headless Device

Perfect for Nerves or IoT devices:

```elixir
defmodule MyDevice.Tailscale do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Start Tailscale daemon
    {:ok, _pid} = Tailscale.start_link(
      name: MyDevice.TailscaleServer,
      tailscale_dir: "/data/tailscale",
      socket_path: "/tmp/tailscale.sock"
    )

    # Connect with auth key from config
    auth_key = Application.get_env(:my_device, :tailscale_auth_key)
    hostname = Application.get_env(:my_device, :hostname)

    case Tailscale.CLI.up(MyDevice.TailscaleServer,
      auth_key: auth_key,
      hostname: hostname,
      accept_routes: true,
      advertise_exit_node: false
    ) do
      {:ok, _} -> 
        Logger.info("Tailscale connected!")
      {:error, reason} -> 
        Logger.error("Tailscale connection failed: #{inspect(reason)}")
    end

    {:ok, %{}}
  end
end
```

### Health Check GenServer

```elixir
defmodule MyApp.TailscaleMonitor do
  use GenServer
  require Logger

  @check_interval :timer.minutes(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check, state) do
    if Tailscale.online?() do
      Logger.debug("Tailscale: Online")
    else
      Logger.warning("Tailscale: Offline - attempting reconnect")
      Tailscale.CLI.up(Tailscale, [])
    end

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end
end
```

## Troubleshooting

### Permission Denied on Socket

If you see socket permission errors, ensure the socket directory exists and is writable:

```elixir
{Tailscale, socket_path: "/tmp/my-app/tailscale.sock"}
```

The library automatically creates the socket directory, but ensure `/tmp` is writable.

### Daemon Won't Start

Check that `tailscaled` is installed and in your PATH:

```bash
which tailscaled
# /usr/sbin/tailscaled
```

For Nerves, ensure Tailscale is included in your `rootfs_overlay` or system image.

### Command Timeouts

Increase timeout for slow operations:

```elixir
Tailscale.CLI.up(Tailscale, hostname: "device", timeout: 120_000)
```

## Nerves Integration Tips

### Including Tailscale in Nerves

1. **Using `rootfs_overlay`**: Add Tailscale binaries to `rootfs_overlay/usr/sbin/`

2. **Custom Nerves System**: Add Tailscale package to your Buildroot config

3. **Runtime Download**: Download and extract Tailscale in your application's startup

### Persistent State

Store Tailscale state on persistent storage:

```elixir
{Tailscale, 
  tailscale_dir: "/root/tailscale",  # or /data/tailscale
  socket_path: "/tmp/tailscale.sock"
}
```

### Auto-Start on Boot

Add to your Application supervision tree to start automatically:

```elixir
def start(_type, _args) do
  children = [
    {Tailscale, name: Tailscale}
    # Start monitor after Tailscale
    MyApp.TailscaleMonitor
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

Copyright (c) 2025

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## Acknowledgments

- Built with [MuonTrap](https://github.com/fhunleth/muontrap) for robust OS process management
- Designed for the [Nerves Project](https://nerves-project.org/)
- Wraps the excellent [Tailscale](https://tailscale.com) VPN

## Links

- [Tailscale Documentation](https://tailscale.com/kb)
- [Nerves Project](https://nerves-project.org/)
- [MuonTrap](https://github.com/fhunleth/muontrap)
