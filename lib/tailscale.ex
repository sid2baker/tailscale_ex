defmodule Tailscale do
  @moduledoc """
  Supervised Tailscale networking for Elixir and Nerves.

  The daemon owns configuration, identity, authentication, and persistence.
  This library manages its lifecycle, issues commands, and caches observations.
  `configure/1` replaces managed settings; `update_configuration/1` changes only
  the supplied fields. Commands wait briefly for the observer to become ready;
  callers do not need to coordinate startup.
  `get/2`, `get_by_prefix/1`, `get_configuration/0`, and subscriptions never perform
  daemon I/O. Startup reads existing settings; only `reset_to_defaults/0` applies
  application `config:` defaults. Subscribe **before** reading an initial value.

  ## Properties

  * `["state"]`: `:unavailable | :offline | :online`. Online means backend Running;
    unavailable means the observer cannot determine connectivity.
  * `["backend_state"]`: `:unknown | :no_state | :in_use_other_user | :needs_login |
    :needs_machine_auth | :stopped | :starting | :running`.
  * `["ipv4"]`, `["ipv6"]`: Erlang IP tuples; absent until assigned.
  * `["hostname"]`, `["dns_name"]`: self host and tailnet DNS names.
  * `["auth", "state"]`: `:unknown | :needs_login | :authenticating |
    :needs_approval | :authenticated | :stopped | :error`.
  * `["auth", "url"]`: transient HTTPS enrollment URL, absent when obsolete.
  * `["auth", "error"]`: sanitized failure category, absent on success.
  * `["peers", id, field]`: stable node ID (numeric fallback), with `"hostname"`,
    `"dns_name"`, `"ipv4"`, `"ipv6"`, and `"online"` fields. Missing values are absent.
  * `["health"]`: list of daemon health warning strings.
  * `["configuration", "value"]`: cached managed configuration, absent when preferences
    are unreadable. The `:serve` field is omitted when Serve cannot be read or represented.
  * `["configuration", "state"]`: `:ready | :applying | :error` (latest operation/read).
  * `["configuration", "error"]`: sanitized failure reason, absent on a successful read.
  * `["monitor", "connected"]`, `["monitor", "generation"]`, `["monitor", "error"]`:
    stream diagnostics. `["version"]` is the daemon version.
  * `["daemon", "state"]`: `:external | :running | :restarting`.

  Runtime properties are never persisted. See the README for daemon installation,
  writable storage, managed-setting ownership, and the Tailscale protocol baseline.
  """

  alias Tailscale.Controller

  @type path :: [String.t()]
  @type pattern :: [String.t() | :_]
  @type configuration :: %{
          optional(:hostname) => String.t(),
          optional(:accept_dns) => boolean(),
          optional(:accept_routes) => boolean(),
          optional(:ssh) => boolean(),
          optional(:advertise_routes) => [String.t() | {:inet.ip_address(), non_neg_integer()}],
          optional(:serve) => [%{https: 1..65_535, to: String.t()}]
        }
  @type result :: :ok | {:error, term()}

  @doc """
  Replace the complete managed configuration. Omitted fields use library defaults.
  Returns the LocalAPI apply/readback result, not a guarantee of disk durability;
  failed writes are never queued or retried. Preferences and Serve are not one
  transaction: an error can leave partial changes.
  Persistence follows the daemon's profile lifecycle (unenrolled profiles are memory-only).
  Authentication keys and unknown fields are rejected.
  """
  @spec configure(configuration()) :: result()
  def configure(config), do: Controller.configure(Controller, config)

  @doc """
  Change selected managed settings while running. Omitted fields are preserved;
  lists are replaced, not appended (`serve: []` removes all managed listeners).

  Serializes library callers and writes only supplied preference fields. Omitted
  Serve settings are left untouched, even if this library cannot represent them.
  A failure to observe omitted Serve settings does not fail a preference update;
  it is reported through the configuration cache instead. Validation, readback,
  and persistence semantics are otherwise the same as `configure/1`.
  External writes and the separate preferences/Serve operations are not transactional.
  """
  @spec update_configuration(configuration()) :: result()
  def update_configuration(changes), do: Controller.update_configuration(Controller, changes)

  @doc """
  Return cached daemon settings, or nil when preferences are unavailable.
  The `:serve` field is omitted when unreadable or unsupported; see
  `["configuration", "error"]` for the reason. Missing Serve is not an empty list.
  """
  @spec get_configuration() :: configuration() | nil
  def get_configuration, do: get(["configuration", "value"])

  @doc "Explicitly apply the application's `config:` defaults to the daemon."
  @spec reset_to_defaults() :: result()
  def reset_to_defaults, do: Controller.reset(Controller)

  @doc "Read a cached property, returning `default` if absent."
  @spec get(path(), term()) :: term()
  def get(path, default \\ nil), do: PropertyTable.get(Tailscale.Properties, path, default)

  @doc "Return cached `{path, value}` pairs matching a prefix (or `:_` wildcard)."
  @spec get_by_prefix(pattern()) :: [{path(), term()}]
  def get_by_prefix(path), do: PropertyTable.match(Tailscale.Properties, path)

  @doc """
  Subscribe the calling process to a prefix/wildcard, before reading its initial value.
  Messages are `{Tailscale, path, old, new, %{old_timestamp: old_ts, new_timestamp: ts}}`.
  Timestamps use native monotonic time units; deleted values are `nil`.
  """
  @spec subscribe(pattern()) :: :ok
  def subscribe(path), do: PropertyTable.subscribe(Tailscale.Properties, path)

  @doc "Stop the calling process's subscription for this exact pattern."
  @spec unsubscribe(pattern()) :: :ok
  def unsubscribe(path), do: PropertyTable.unsubscribe(Tailscale.Properties, path)

  @doc """
  Return `{:ok, url}` for browser enrollment, or `:ok` if already running.
  Waits up to 30 seconds for the URL after initiating login, never for browser
  completion. Override this URL wait with `timeout: milliseconds`. A timeout
  does not cancel enrollment; call again after an interruption or URL expiration.

  With `auth_key: key`, returns `:ok` after initiating unattended enrollment.
  Observe `["state"]` or `["auth"]` for completion. Machine approval is reported
  as `{:error, :needs_approval}` for browser login. Credentials are not persisted or logged.
  """
  @spec login(keyword()) :: result() | {:ok, String.t()}
  def login(opts \\ [])
  def login([]), do: login(timeout: 30_000)

  def login(timeout: timeout) when is_integer(timeout) and timeout in 1..4_294_967_295 do
    with :ok <- Controller.login(Controller, :interactive) do
      Tailscale.Monitor.await_login(Tailscale.Monitor, timeout)
    end
  end

  def login(auth_key: key) when is_binary(key) and byte_size(key) in 1..4096 do
    Controller.login(Controller, {:auth_key, key})
  end

  def login(auth_key: _), do: {:error, :invalid_auth_key}

  def login(_), do: {:error, :invalid_options}

  @doc "Log out without deleting the daemon's identity store."
  @spec logout() :: result()
  def logout, do: Controller.logout(Controller)

  @doc "Print a readable cached status report, without login URLs or daemon I/O."
  @spec info() :: :ok
  def info, do: Tailscale.Info.print()
end
