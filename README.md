# Tailscale

An Elixir wrapper for [Tailscale](https://tailscale.com), providing a supervised GenServer to manage the `tailscaled` daemon and execute CLI commands.

## Features

- 🚀 **Supervised daemon management** - Full lifecycle control via `MuonTrap`
- 🔌 **Custom socket paths** - Works in embedded/Nerves environments
- ⏱️ **Configurable timeouts** - Prevent hanging commands
- 🧪 **Mock-based testing** - No Tailscale installation required for tests
- 📝 **Full typespecs** - Complete type documentation

## Installation

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

# Check if online
Tailscale.online?()
# => false

# Execute CLI commands
{:ok, status} = Tailscale.cli("status", ["--json"])
{:ok, ips} = Tailscale.cli("ip", [])
{:ok, _} = Tailscale.cli("up", ["--hostname=my-device"])
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
| `:daemon_path`   | `/usr/bin/tailscaled`             | Path to daemon binary        |
| `:cli_path`      | `/usr/bin/tailscale`              | Path to CLI binary           |
| `:socket_path`   | `/run/tailscale/tailscaled.sock`  | Unix socket path             |
| `:tailscale_dir` | `/data/tailscale`                 | State directory              |
| `:timeout`       | `30_000`                          | Command timeout (ms)         |

## API

### Main Functions

```elixir
# Check if online
Tailscale.online?() :: boolean()

# Get version
Tailscale.version() :: {:ok, String.t()} | {:error, :not_available}

# Get daemon PID
Tailscale.daemon_pid() :: {:ok, pid()} | {:error, :not_started}

# Execute any CLI command
Tailscale.cli(command, args) :: {:ok, String.t() | map()} | {:error, term()}
```

### Common Commands

```elixir
# Connect
Tailscale.cli("up", ["--hostname=my-device"])

# Get status
Tailscale.cli("status", ["--json"])

# Get IPs
Tailscale.cli("ip", [])

# Disconnect
Tailscale.cli("down", [])

# Get version
Tailscale.cli("version", [])
```

## Error Handling

```elixir
case Tailscale.cli("status", ["--json"]) do
  {:ok, status} when is_map(status) ->
    # JSON parsed successfully
    IO.inspect(status)
    
  {:ok, output} when is_binary(output) ->
    # Plain text output
    IO.puts(output)
    
  {:error, {:timeout, partial_output}} ->
    # Command timed out
    Logger.error("Timeout: #{partial_output}")
    
  {:error, {exit_code, output}} ->
    # Command failed
    Logger.error("Exit #{exit_code}: #{output}")
    
  {:error, :not_started} ->
    # Daemon not running
    Logger.error("Daemon not started")
end
```

## Testing

Run tests with:

```bash
mix test
```

The test suite uses mock binaries and doesn't require Tailscale installation.

## Nerves Integration

For embedded/Nerves projects:

```elixir
{Tailscale,
  name: Tailscale,
  daemon_path: "/usr/sbin/tailscaled",
  cli_path: "/usr/bin/tailscale",
  socket_path: "/tmp/tailscale.sock",
  tailscale_dir: "/root/tailscale"}
```

### Auto-connect on boot

```elixir
defmodule MyDevice.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Tailscale, name: Tailscale, tailscale_dir: "/data/tailscale"}
    ]

    opts = [strategy: :one_for_one]
    {:ok, pid} = Supervisor.start_link(children, opts)
    
    # Connect after daemon starts
    :timer.sleep(100)
    auth_key = Application.get_env(:my_device, :tailscale_auth_key)
    Tailscale.cli("up", ["--auth-key=#{auth_key}", "--hostname=my-device"])
    
    {:ok, pid}
  end
end
```

## License

Apache License 2.0
