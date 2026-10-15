# Tailscaled for Elixir and Nerves

Supervise the `tailscaled` daemon and use its LocalAPI for configuration, login,
HTTPS Serve, and state subscriptions. This is an independent daemon integration,
not the [`tailscale`](https://hex.pm/packages/tailscale) package based on tailscale-rs.
Requires Linux, Elixir 1.19+, and OTP 28+. Tested with Tailscale **1.102.3**.

## 1. Install

Add the Hex dependency to `mix.exs`:

```elixir
{:tailscaled_ex, "~> 0.2.0"}
```

For Nerves, download the daemon into your firmware overlay:

```sh
export MIX_TARGET=rpi4 # Change to your firmware target.
mix deps.get
mix tailscaled.install rootfs_overlay/usr/sbin/tailscaled
```

```elixir
# config/config.exs
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :tailscaled_ex, daemon_path: "/usr/sbin/tailscaled", tun: :userspace
```

On a Linux host, use `mix deps.get` and `mix tailscaled.install ./bin/tailscaled`,
then set `daemon_path` to its absolute runtime path and `tun: :userspace`.
The installer verifies the checksum and detects the target architecture;
see `mix help tailscaled.install` for overrides. Use separate overlays per architecture.

The application starts automatically—do not add it to your supervision tree.
Userspace mode supports Serve without root or TUN. For a host-wide network interface,
use `tun: :kernel` with TUN support and OS permissions.

Keep `data_dir` on durable writable storage. Defaults: `/data/tailscale_ex` on Nerves,
`~/.local/share/tailscale_ex` elsewhere. These legacy directory names are intentionally
unchanged. For an existing daemon or other options, see the
[API reference](https://github.com/sid2baker/tailscaled_ex/blob/main/lib/tailscaled.ex).

## 2. Configure and log in

In your application's IEx session:

```elixir
:ok = Tailscaled.update_configuration(%{hostname: "my-device", accept_dns: false})
Tailscaled.login() # Returns {:ok, url}; open it in a browser. Already online: :ok.
Tailscaled.info()
```

The library defaults to `accept_dns: false`, leaving system DNS to the device's
network stack and avoiding `/etc/resolv.conf` write errors on read-only Nerves
filesystems. Set it to `true` to opt into tailnet DNS. The explicit update above
is still needed because startup and login do not apply library defaults.

For unattended login, use `Tailscaled.login(auth_key: key)` with a key from your
secret source. Login initiates enrollment; observe `["state"]` for `:online`.
Browser login waits up to 30 seconds for a URL, not browser completion.
Treat keys and login URLs as secrets.

`update_configuration/1` preserves omitted fields; `configure/1` resets them to
library defaults. Startup only reads settings. The daemon owns persistence;
settings made before enrollment may be lost on restart. Commands return errors
without retrying writes, and multi-setting changes can partially apply.

Use `Tailscaled.down()` and `Tailscaled.up()` to set the daemon's `WantRunning`
preference without logging out or resetting configuration. `:ok` confirms readback,
not connectivity or termination of every existing proxy session. The daemon stays
running; startup behavior is unchanged. `up/0` does not initiate login.

## 3. Serve your app over HTTPS

Enable MagicDNS and HTTPS in your tailnet. After login, check
`Tailscaled.get(["dns_name"])` for the expected name, then:

```elixir
:ok = Tailscaled.update_configuration(%{
  serve: [%{https: 443, to: "http://127.0.0.1:4000"}]
})
```

Visit `https://<dns_name>/` from an authorized tailnet device. This is not public
Funnel access or a replacement for app authentication. Setting `serve` replaces
all top-level listeners and clears Funnel; `serve: []` removes them.
Rename separately, wait for the new DNS name, then reapply Serve.

## 4. Read state and subscribe

Subscribe before reading; events report changes, not an initial snapshot:

```elixir
:ok = Tailscaled.subscribe(["state"])
Tailscaled.get(["state"]) # :unavailable | :offline | :online
Tailscaled.get(["ipv4"])
Tailscaled.get_by_prefix(["peers"])
# Messages: {Tailscaled, path, old_value, new_value, timestamps}
```

Reads are cached. `:online` means the backend reports Running, not a successful
internet or peer-reachability probe. Use `Tailscaled.info()` for a readable report.
External Serve edits may not emit notifications; call `Tailscaled.refresh_configuration()`
before `Tailscaled.get_configuration()` when you need a fresh configuration observation.
There is no background polling.
See the [API reference](https://github.com/sid2baker/tailscaled_ex/blob/main/lib/tailscaled.ex)
for settings, properties, login options, and logout.

## Migrating from tailscale_ex

- Rename the dependency and OTP configuration key from `:tailscale` to `:tailscaled_ex`.
- Replace the `Tailscale` module namespace with `Tailscaled`, including subscription
  message patterns and any references to registered processes.
- Use `mix tailscaled.install` instead of `mix tailscale.install`.
- Remove the old dependency from `mix.exs`, then run `mix deps.unlock tailscale`
  and `mix deps.get` to update the lockfile.
- Keep existing `data_dir`, `state_dir`, and `socket` overrides unchanged. Default
  storage paths are also unchanged; do not delete identity files or re-enroll.

The old namespace is not retained as an alias. See [CHANGELOG.md](CHANGELOG.md).

## Development

Run `mix deps.get && mix ci`. To include isolated real-daemon tests:

```sh
TAILSCALED_TEST_BINARY=/absolute/path/to/tailscaled mix ci
```

Add `TAILSCALE_TEST_NETWORK=1` to enable control-plane URL and invalid-key tests.
Tests never attach to a host daemon; they do not cover enrolled-tailnet HTTPS or hardware.
Run `mix docs --warnings-as-errors` to build the API documentation. See
[CONTRIBUTING.md](CONTRIBUTING.md) for development and release checks.

## License

[Apache License 2.0](https://github.com/sid2baker/tailscaled_ex/blob/main/LICENSE)
