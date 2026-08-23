# Tailscale

A Linux-focused Elixir runtime for [Tailscale](https://tailscale.com). It owns
`tailscaled`, safely schedules CLI operations, normalizes unstable JSON, and
provides typed enrollment, profile, preference, readiness, health, and subnet
router APIs.

## Features

- Internally supervised `tailscaled` with bounded restart backoff
- Concurrent reads and FIFO-serialized mutations
- Nil-safe `%Tailscale.Status{}` and `%Tailscale.Health{}` models
- Secret-safe enrollment through volatile `0600` auth-key files
- Typed local profile management and preferences
- Daemon and online readiness barriers
- Deduplicated status and health subscriptions
- Secret-free telemetry
- Verified, architecture-aware Linux binary installer

## Installation

```elixir
def deps do
  [
    {:tailscale, github: "sid2baker/tailscale_ex"}
  ]
end
```

## Supervision

Add one named instance to your application supervisor:

```elixir
children = [
  {Tailscale,
    name: Tailscale,
    daemon_path: "/usr/sbin/tailscaled",
    cli_path: "/usr/bin/tailscale",
    socket_path: "/run/tailscale/tailscaled.sock",
    tailscale_dir: "/data/tailscale",
    runtime_dir: "/run/tailscale_ex",
    tun: :kernel}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Each instance internally uses a `:one_for_all` supervisor containing a command
`Task.Supervisor`, daemon manager, and public server. Ordinary `tailscaled`
exits are handled by the daemon manager without restarting the public server.
If the public state owner fails, all command tasks and daemon ownership restart
together so no work survives with stale ownership.

Read commands run concurrently, while login, profile, preference, and
explicitly mutating CLI operations execute FIFO. Work is cancelled when its
caller exits or its timeout expires. Cancellation is best effort because an
operation may already have reached `tailscaled`; callers should reconcile
through typed readback.

Important options:

| Option | Default | Description |
|---|---|---|
| `:name` | `Tailscale` | Public instance name |
| `:daemon_path` | `/usr/sbin/tailscaled` | Daemon executable |
| `:cli_path` | `/usr/bin/tailscale` | CLI executable |
| `:start_daemon` | `true` | Manage the daemon or attach to an external one |
| `:socket_path` | `/run/tailscale/tailscaled.sock` | Unix socket |
| `:tailscale_dir` | `/data/tailscale` | Persistent daemon state |
| `:runtime_dir` | `/run/tailscale_ex` | Volatile secret storage |
| `:tun` | `:kernel` | `:kernel`, `:userspace`, or interface name |
| `:command_timeout` | `30_000` | Per-operation timeout in milliseconds |
| `:status_interval` | `1_000` | Single-flight monitor interval |
| `:daemon_log_level` | `:info` | Logger level or `false` |
| `:daemon_stdio_window` | `10_240` | MuonTrap output flow-control window |

## Status and health

```elixir
{:ok,
 %Tailscale.Status{
   backend_state: :running,
   authenticated: true,
   online: true,
   ipv4: "100.64.0.1",
   ipv6: nil,
   hostname: "gateway",
   peers: []
 }} = Tailscale.status()

{:ok,
 %Tailscale.Health{
   client: :running,
   daemon: :running,
   socket: :ready,
   authenticated: true,
   online: true
 }} = Tailscale.health()
```

Unavailable startup fields remain `:unknown`; they are never incorrectly
normalized to `false`. Expected lifecycle races return values such as:

```elixir
{:error, :server_unavailable}
{:error, :daemon_restarting}
{:error, :socket_unavailable}
```

Public APIs do not leak `GenServer.call/3` exits.

## Enrollment

```elixir
:ok =
  Tailscale.login(
    auth_key: auth_key,
    hostname: "gateway-01",
    nickname: "Factory Gateway",
    accept_dns: false
  )
```

The auth key is written under the volatile runtime directory using a random
`0700` directory and `0600` file. The CLI receives only a `file:PATH`
reference. The key is omitted from long-lived process messages, command
arguments, errors, logs, and telemetry, and the file is removed after the
operation.

## Profiles

```elixir
{:ok, profiles} = Tailscale.profiles()
{:ok, %Tailscale.Profile{id: id}} = Tailscale.current_profile()
:ok = Tailscale.switch_profile(id)
:ok = Tailscale.remove_profile(id)
```

Profile commands use Tailscale's local profile interface and may require root or
a configured Tailscale operator.

## Typed preferences

Only explicitly supplied preferences change; the implementation always invokes
`tailscale set`, never `tailscale up`:

```elixir
:ok =
  Tailscale.set(
    hostname: "gateway-01",
    accept_dns: false,
    ssh: false,
    advertise_routes: ["192.168.1.0/24", "10.0.0.0/24"]
  )

:ok = Tailscale.set(advertise_routes: [])

{:ok,
 %Tailscale.Preferences{
   hostname: "gateway-01",
   accept_dns: false,
   ssh: false,
   advertised_routes: routes
 }} = Tailscale.preferences()
```

Route CIDRs are canonicalized and deduplicated. Approval remains a tailnet
policy or admin-console responsibility:

```elixir
{:ok, %{advertised: advertised, approved: approved, primary: primary}} =
  Tailscale.route_status()
```

## Readiness

Daemon readiness only proves that the local socket accepts commands and also
works before enrollment:

```elixir
:ok = Tailscale.await_ready(timeout: 10_000)
```

Online readiness requires a running, online backend and can impose additional
normalized requirements:

```elixir
:ok =
  Tailscale.await_online(
    timeout: 30_000,
    require: [:authenticated, :tailscale_ipv4]
  )
```

## Subscriptions

```elixir
:ok = Tailscale.subscribe()

receive do
  {:tailscale, :status_changed, generation, status} ->
    IO.inspect({generation, status})

  {:tailscale, :health_changed, generation, health} ->
    IO.inspect({generation, health})
end
```

Subscribers receive immediate snapshots. Later events are structurally
deduplicated, carry a monotonic per-instance generation, and include transition
timestamps in their structs. Dead subscribers are removed automatically.

## Generic CLI escape hatch

Scheduling semantics must be explicit:

```elixir
{:ok, ips} = Tailscale.cli("ip", ["--4"], mode: :read)
{:ok, _output} = Tailscale.cli("down", [], mode: :mutation)
```

Unknown commands are never classified automatically. Typed APIs should be
preferred for mutations.

## Installing Linux binaries dynamically

```elixir
{:ok, binaries} =
  Tailscale.Binary.ensure_installed(
    version: "1.102.3",
    install_dir: "/data/tailscale/bin"
  )
```

The installer detects the running BEAM ABI, downloads the official stable Linux
archive, verifies its published SHA-256 checksum, and atomically installs both
`tailscale` and `tailscaled`. Exact versions are required. Supported artifacts
include `amd64`, `386`, `arm`, `arm64`, MIPS variants, and `riscv64`.

## Nerves subnet routers

The Nerves system needs kernel TUN support (`CONFIG_TUN`) and `/dev/net/tun`.
Enable forwarding during each boot when `/etc` is immutable:

```elixir
:ok = Tailscale.enable_forwarding()
:ok = Tailscale.await_ready(timeout: 10_000)
:ok = Tailscale.set(advertise_routes: ["192.168.1.0/24"])
```

On conventional writable Linux, persist forwarding idempotently:

```elixir
:ok = Tailscale.enable_forwarding(persist: :sysctl_d)
```

This writes `/etc/sysctl.d/99-tailscale.conf` and applies the settings through
`/proc`. The calling OS process needs suitable permissions; the library never
invokes `sudo`.

## Telemetry

The library emits command duration/outcome, daemon exit/restart, and normalized
status/health transition events under the `[:tailscale, ...]` prefix. Metadata
contains operation and outcome identifiers only—never arguments, profile IDs,
hostnames, routes, CLI output, or secrets.

## Testing

```bash
mix ci
```

The real integration test attaches to an installed daemon without replacing it:

```bash
mix test --only integration test/integration/tailscale_integration_test.exs
```

Set `TAILSCALE_SOCKET` or `TAILSCALE_CLI_PATH` for non-default installations.
CI tests stable and unstable Tailscale channels using GitHub OIDC workload
identity federation. It expects `TS_OAUTH_CLIENT_ID` and `TS_AUDIENCE`; no
reusable auth key or OAuth client secret is stored in GitHub.

## License

Apache License 2.0
