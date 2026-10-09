# Tailscale for Elixir and Nerves

Supervised Tailscale networking with browser/key enrollment, HTTPS Serve, and cached
state subscriptions. It uses the daemon's LocalAPI event stream; tailscaled owns
persistence.

## Installation

Requires Linux, Elixir 1.19+, OTP 28+, and a provisioned `tailscaled` 1.102.3+ (1.x) binary.
**Tailscale 1.102.3** is the tested baseline. Pin and checksum-verify your binary;
LocalAPI is an internal protocol, so subsequent 1.x versions need compatibility testing.

```elixir
# mix.exs — pin a reviewed Git revision for production
{:tailscale, github: "sid2baker/tailscale_ex"}
```

```elixir
# config/runtime.exs
import Config

config :tailscale,
  daemon_path: "/usr/sbin/tailscaled",
  data_dir: "/data/tailscale_ex",
  tun: :userspace
```

The OTP application starts automatically. Do not add `Tailscale` to your supervision
tree. Startup reads existing daemon settings and retries until the daemon is available.

Userspace mode supports Serve without a TUN device, but does not provide a host-wide
network interface. Host routing and Tailscale SSH require `tun: :kernel`, TUN support,
and OS permissions. Subnet routing also needs forwarding/firewall setup and tailnet approval.

## Configuration

Once `Tailscale.get(["monitor", "connected"])` is `true`:

```elixir
:ok = Tailscale.configure(%{hostname: "nerves-livebook", accept_dns: false})
Tailscale.get_configuration()
```

Each call supplies the **complete managed configuration**, not a patch. Omitted
fields use these defaults:

| Field | Default | Accepted values |
|---|---|---|
| `hostname` | `""` | DNS label; empty uses the daemon's host default |
| `accept_dns` | `true` | Boolean |
| `accept_routes` | `false` | Boolean |
| `ssh` | `false` | Boolean; requires daemon/platform support |
| `advertise_routes` | `[]` | CIDR strings or `{ip_tuple, prefix}` |
| `serve` | `[]` | `%{https: port, to: "http://host:port"}` entries; HTTPS targets also supported |

`configure/1` validates, applies, and reads back settings. It returns `:ok` or
`{:error, reason}`. Failed writes are not queued or retried. Preferences and Serve
are separate operations, so an error can leave partial changes. Unmanaged preferences
are preserved, and configuration does not implicitly log in.

`get_configuration/0` reads the cache, returning a map or `nil` when unavailable.
`reset_to_defaults/0` explicitly applies the application's `config:` map (default
`%{}`). Startup, login, and reconnects never apply that map automatically.

## Authentication

```elixir
:ok = Tailscale.subscribe(["auth", "url"])
:ok = Tailscale.login()

# May be nil until the daemon supplies a URL.
Tailscale.get(["auth", "url"])

receive do
  {Tailscale, ["auth", "url"], _, url, _} when is_binary(url) ->
    IO.puts("Open #{url} on another device")
end
```

Complete enrollment in the browser and observe `["state"]` becoming `:online`.
`login/0` returns after initiation, not browser completion, and is a no-op when
already running. Call it again if the URL expires or enrollment is interrupted.
Machine approval may also be required by your tailnet.

For unattended enrollment, retrieve a key from your secret source:

```elixir
:ok = Tailscale.login(auth_key: key)
```

Progress and errors appear under `["auth"]`. `Tailscale.logout/0` logs out without
deleting the daemon's identity store.

## Livebook over HTTPS

After enrollment, wait for the expected `["dns_name"]`, then enable Serve:

```elixir
%{} = current = Tailscale.get_configuration()
:ok = Tailscale.configure(%{current | serve: [%{https: 443, to: "http://127.0.0.1:80"}]})
```

Run Livebook on port 80 and visit `https://<dns_name>/` from an authorized tailnet
device. Enable MagicDNS/HTTPS and appropriate tailnet permissions. Livebook's own
authentication still applies; this does not enable public Funnel access.

**Configure/reset replaces all top-level node Serve listeners and Funnel settings.**
An empty `serve` list removes them. Named `Services` are preserved; active `Foreground`
sessions return a conflict. Avoid concurrent CLI management of these listeners.

Set the hostname first and wait for its updated DNS name before configuring Serve.
Missing DNS returns `:awaiting_dns_name`; callers must retry explicitly. Unsupported
external Serve settings make the cached configuration unavailable. Serve-only edits
outside the library may remain unobserved until another refresh event.

## State and subscriptions

Reads are cached and never wait for the daemon. **Subscribe before reading**;
subscriptions send changes, not an initial snapshot.

```elixir
:ok = Tailscale.subscribe(["state"])
Tailscale.get(["state"], :unavailable)

# Change messages:
# {Tailscale, ["state"], :offline, :online, %{old_timestamp: ..., new_timestamp: ...}}

:ok = Tailscale.subscribe(["peers", :_, "online"])
Tailscale.get_by_prefix(["peers"])
:ok = Tailscale.unsubscribe(["state"])
```

| Path | Meaning |
|---|---|
| `["state"]` | `:unavailable`, `:offline`, or `:online` (backend Running, not a reachability probe) |
| `["backend_state"]` | Detailed daemon state |
| `["ipv4"]`, `["ipv6"]` | Erlang IP tuples |
| `["hostname"]`, `["dns_name"]` | Node names |
| `["auth", …]` | Enrollment `state`, `url`, and `error` |
| `["peers", id, field]` | Peer hostname, DNS name, IPs, and online state |
| `["health"]` | Daemon warnings |
| `["configuration", …]` | Latest apply/read `state` (`:ready`, `:applying`, `:error`) and `error` |
| `["monitor", …]` | Event-stream readiness (`connected`) and `error` |

Missing values read as `nil`. Timestamps are monotonic; overlapping subscriptions
may produce duplicate messages. Subscribe inside the process consuming the events.
Subscriptions survive daemon reconnects, but consumers must restart/re-subscribe
after an application/table restart; subscribers are linked to the table's registry.

`Tailscale.info/0` returns cached diagnostics with login URLs redacted. See
[`Tailscale`](lib/tailscale.ex) for the full API and property list.

## Runtime options and storage

Application options (`config :tailscale, ...`):

| Option | Default |
|---|---|
| `manage_daemon` | `true` |
| `daemon_path` | `"tailscaled"` |
| `data_dir` | `/data/tailscale_ex` on Nerves; `~/.local/share/tailscale_ex` otherwise |
| `state_dir` | `<data_dir>/identity` |
| `socket` | `<data_dir>/run/tailscaled.sock`; `/var/run/tailscale/tailscaled.sock` when external |
| `tun`, `port` | `:kernel`, `0` (dynamic UDP port) |
| `config` | `%{}`; applied only by `reset_to_defaults/0` |
| `timeout`, `initial_timeout` | `5_000`, `10_000` ms |
| `retry_min`, `retry_max` | `200`, `30_000` ms for daemon/observation retries |
| `auth_url_ttl` | `600_000` ms |
| `max_body`, `max_frame` | `4_194_304` bytes each |

To use an external daemon, set `manage_daemon: false` and its `socket` path.
The BEAM OS user needs LocalAPI permission. Each ordinary response has one deadline;
the watch has an initial-snapshot deadline but no idle timeout once established.

Keep daemon state on durable writable storage. Do not share a state directory between
daemons. Fresh unenrolled preferences are memory-only and can be lost on restart.
LocalAPI success/readback does not guarantee a durable disk write; monitor storage
health. Runtime caches are never persisted.

Auth keys pass in memory to LocalAPI, not into configuration, files, or retained
controller state. Controller crash messages are redacted; daemon error bodies are
discarded. Avoid credential tracing, raw input logging, and unauthenticated
provisioning controls. Login URLs are sensitive.

## Development

```sh
mix deps.get
mix ci

# Isolated userspace daemon tests
TAILSCALED_TEST_BINARY=/absolute/path/to/tailscaled mix test test/integration/daemon_test.exs

# Also contact Tailscale's control plane for browser-URL and invalid-key tests
TAILSCALED_TEST_BINARY=/absolute/path/to/tailscaled TAILSCALE_TEST_NETWORK=1 mix test
```

Tests use disposable state and sockets, never the host daemon. Browser completion,
valid-key enrollment, tailnet HTTPS, kernel networking, and Nerves reboot behavior
require separate credential/hardware validation.

## License

Apache License 2.0
