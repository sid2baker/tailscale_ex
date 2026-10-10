# Tailscale for Elixir and Nerves

Supervised Tailscale networking, browser/key login, HTTPS Serve, and cached state
subscriptions. Requires Linux, Elixir 1.19+, and OTP 28+.

## Setup

Add the dependency to `mix.exs` (pin a reviewed revision for production):

```elixir
{:tailscale, github: "sid2baker/tailscale_ex"}
```

From your application, download the tested **Tailscale 1.102.3** daemon to an explicit
path. For Nerves, include it through your firmware's root filesystem overlay:

```sh
export MIX_TARGET=rpi4 # Your firmware target
mix deps.get
mix tailscale.install rootfs_overlay/usr/sbin/tailscaled
```

The task uses the target's toolchain architecture, verifies the published SHA-256
checksum, and creates the destination's parent directories. The argument is the
full binary filename, relative to your current directory or absolute. Use separate
overlays for different target architectures. See `mix help tailscale.install`
for the `--arch` override.

```elixir
# config/config.exs
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :tailscale, daemon_path: "/usr/sbin/tailscaled", tun: :userspace
```

On a Linux host, run `mix tailscale.install ./bin/tailscaled` and set `daemon_path`
to that binary's runtime path instead.

The OTP application starts automatically; do not add it to your supervision tree.
Userspace mode supports Serve without root or a TUN device, but does not create a
host-wide network interface. Routing and Tailscale SSH require `tun: :kernel`,
TUN support, and OS permissions.

State defaults to `/data/tailscale_ex` on Nerves and `~/.local/share/tailscale_ex`
elsewhere. Override `data_dir:` with durable writable storage when needed.
A separately supplied daemon must be 1.102.3+ within 1.x; later versions need
compatibility testing. To attach to an existing daemon, set
`manage_daemon: false, socket: "/var/run/tailscale/tailscaled.sock"`.

## Configure and log in

Commands wait briefly for the daemon's initial observation; no startup polling is needed.

```elixir
:ok = Tailscale.configure(%{hostname: "my-device", accept_dns: false})
{:ok, url} = Tailscale.login()
IO.puts(url) # Open this URL in a browser.

# Or use a key from your secret source:
:ok = Tailscale.login(auth_key: key)
```

Browser login returns `{:ok, url}`, or `:ok` if already online. It waits up to
30 seconds for the URL (`login(timeout: 60_000)` overrides this), not for browser
completion. A timeout does not cancel enrollment. Key login returns after initiation.
Observe `["state"]` for `:online`; machine approval may still be required.
`Tailscale.logout/0` logs out without deleting identity.

Both configuration APIs work while running:

- `configure/1` replaces the **complete managed configuration**; omitted fields use defaults.
- `update_configuration/1` writes only supplied fields. Omitted Serve settings remain
  untouched, even if unsupported by this library. Lists replace completely.

Both verify writes by readback and serialize library callers. Preferences and Serve
are separate operations, not a transaction: errors can leave partial changes.
`get_configuration/0` returns observed settings, not a saved desired configuration.
If Serve is unreadable or unsupported, the map omits `:serve` and
`["configuration", "error"]` explains why; preference updates still work.

Startup only reads existing settings. The daemon owns persistence; settings made
before enrollment may be lost on restart. Failed operations return `{:error, reason}`
and writes are not queued or retried.

## Serve an HTTP app over HTTPS

Enable MagicDNS and HTTPS in your tailnet. After login, wait for the expected
`Tailscale.get(["dns_name"])`, then enable Serve without changing other settings:

```elixir
:ok = Tailscale.update_configuration(%{
  serve: [%{https: 443, to: "http://127.0.0.1:4000"}]
})
```

Visit `https://<dns_name>/` from an authorized tailnet device. This does not enable
public Funnel access or replace your app's authentication. Setting `serve` replaces
all top-level Serve listeners and Funnel settings; `serve: []` removes them.

## Inspect state and subscribe

For a readable status, configuration, and peer report in IEx:

```elixir
Tailscale.info()
```

The report uses cached observations and omits login URLs. For programmatic reads
and reactive clients, subscribe before reading; subscriptions deliver changes,
not an initial snapshot.

```elixir
:ok = Tailscale.subscribe(["state"])
Tailscale.get(["state"]) # :unavailable | :offline | :online
Tailscale.get(["ipv4"])
Tailscale.get_by_prefix(["peers"])

# Messages: {Tailscale, ["state"], old_value, new_value, timestamps}
```

Reads are cached. See [`Tailscale`](lib/tailscale.ex) for configuration fields,
properties, and the full API. Treat auth keys and login URLs as secrets.

## Development

Run `mix ci`. For isolated real-daemon tests:

```sh
TAILSCALED_TEST_BINARY=/absolute/path/to/tailscaled mix test test/integration/daemon_test.exs
```

## License

Apache License 2.0
