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

# Get status as a map
{:ok, status} = Tailscale.status()

# Execute CLI commands
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
| `:daemon_path`   | `/usr/sbin/tailscaled`            | Path to daemon binary        |
| `:cli_path`      | `/usr/bin/tailscale`              | Path to CLI binary           |
| `:socket_path`   | `/run/tailscale/tailscaled.sock`  | Unix socket path             |
| `:tailscale_dir` | `/data/tailscale`                 | State directory              |
| `:timeout`       | `5_000`                           | Command timeout (ms)         |

## API

### Status & Health Functions

```elixir
# Check if online
Tailscale.online?() :: boolean()
Tailscale.online?(server) :: boolean()

# Get full status as a map
Tailscale.status() :: {:ok, map()} | {:error, term()}
Tailscale.status(server) :: {:ok, map()} | {:error, term()}

# Get version
Tailscale.version() :: {:ok, String.t()} | {:error, :not_available}
Tailscale.version(server) :: {:ok, String.t()} | {:error, :not_available}

# Get daemon PID
Tailscale.daemon_pid() :: {:ok, pid()} | {:error, :not_started}
Tailscale.daemon_pid(server) :: {:ok, pid()} | {:error, :not_started}
```

### Authentication

```elixir
# Login with auth key
Tailscale.login(auth_key) :: {:ok, String.t()} | {:error, term()}
Tailscale.login(server, auth_key) :: {:ok, String.t()} | {:error, term()}
```

### CLI Commands

```elixir
# Execute any CLI command
Tailscale.cli(command, args) :: {:ok, String.t() | map()} | {:error, term()}
Tailscale.cli(server, command, args) :: {:ok, String.t() | map()} | {:error, term()}
```

### Common CLI Examples

```elixir
# Connect with hostname
Tailscale.cli("up", ["--hostname=my-device"])

# Connect with auth key
Tailscale.cli("up", ["--auth-key=tskey-...", "--hostname=my-device"])

# Get status (JSON automatically parsed)
{:ok, status_map} = Tailscale.cli("status", ["--json"])

# Get IPs
{:ok, ips} = Tailscale.cli("ip", [])

# Disconnect
Tailscale.cli("down", [])

# Get version
Tailscale.cli("version", [])

# Network check
Tailscale.cli("netcheck", [])

# Who is using an IP
Tailscale.cli("whois", ["100.64.0.1", "--json"])
```

## Error Handling

All functions return tagged tuples for proper error handling:

```elixir
case Tailscale.status() do
  {:ok, status} when is_map(status) ->
    # Successfully retrieved status
    if status["Self"]["Online"] do
      IO.puts("Connected as #{status["Self"]["HostName"]}")
    end
    
  {:error, reason} ->
    Logger.error("Failed to get status: #{inspect(reason)}")
end
```

### CLI Error Handling

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
    # Command failed with exit code
    Logger.error("Exit #{exit_code}: #{output}")
end
```

## Testing

Run tests with:

```bash
mix test
```

The test suite uses mock binaries and doesn't require Tailscale installation. See `test/support/mock_tailscale.ex` for mock implementation details.

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

### Auto-connect on Boot

Here's a production-ready example with proper error handling:

```elixir
defmodule MyDevice.Application do
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      {Tailscale, name: Tailscale, tailscale_dir: "/data/tailscale"}
    ]

    opts = [strategy: :one_for_one]
    {:ok, pid} = Supervisor.start_link(children, opts)
    
    # Schedule async connection attempt
    Task.start(fn -> connect_tailscale() end)
    
    {:ok, pid}
  end

  defp connect_tailscale do
    # Wait for daemon to be ready
    wait_for_daemon()
    
    auth_key = Application.get_env(:my_device, :tailscale_auth_key)
    hostname = Application.get_env(:my_device, :hostname, "my-device")
    
    case Tailscale.login(auth_key) do
      {:ok, _} ->
        Logger.info("Tailscale authenticated successfully")
        Tailscale.cli("up", ["--hostname=#{hostname}"])
        
      {:error, reason} ->
        Logger.error("Failed to authenticate: #{inspect(reason)}")
    end
  end

  defp wait_for_daemon(attempts \\ 50) do
    case Tailscale.daemon_pid() do
      {:ok, _pid} -> :ok
      {:error, _} when attempts > 0 ->
        Process.sleep(100)
        wait_for_daemon(attempts - 1)
      {:error, _} ->
        Logger.error("Daemon failed to start")
    end
  end
end
```

## Advanced Usage

### Multiple Named Instances

You can run multiple Tailscale instances with different configurations:

```elixir
# Start first instance
{:ok, pid1} = Tailscale.start_link(
  name: :tailscale_prod,
  socket_path: "/tmp/tailscale-prod.sock",
  tailscale_dir: "/data/tailscale-prod"
)

# Start second instance
{:ok, pid2} = Tailscale.start_link(
  name: :tailscale_test,
  socket_path: "/tmp/tailscale-test.sock",
  tailscale_dir: "/data/tailscale-test"
)

# Use specific instance
Tailscale.online?(:tailscale_prod)
Tailscale.cli(:tailscale_test, "status", ["--json"])
```

### Custom Timeouts

For slow networks or long-running commands:

```elixir
# Set longer timeout (30 seconds)
{:ok, _pid} = Tailscale.start_link(timeout: 30_000)

# Commands will now wait up to 30 seconds before timing out
Tailscale.cli("up", ["--hostname=slow-device"])
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
