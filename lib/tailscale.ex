defmodule Tailscale do
  @moduledoc """
  A supervised Linux Tailscale runtime with typed preferences, status,
  enrollment, profile management, readiness, and daemon health.

  Add a named instance to your supervision tree and use that name for calls:

      children = [
        {Tailscale, name: Tailscale}
      ]

      {:ok, status} = Tailscale.status()
  """

  alias Tailscale.Call
  alias Tailscale.Config
  alias Tailscale.Health
  alias Tailscale.LoginOptions
  alias Tailscale.Preferences
  alias Tailscale.Profile
  alias Tailscale.RouteStatus
  alias Tailscale.SecretFile
  alias Tailscale.Status
  alias Tailscale.SubnetRouter

  @type tun :: :kernel | :userspace | String.t()
  @type route :: String.t()
  @type forwarding_family :: :ipv4 | :ipv6
  @type forwarding_status :: %{required(:ipv4) => boolean(), required(:ipv6) => boolean()}
  @type forwarding_option ::
          {:families, [forwarding_family()]}
          | {:persist, false | :sysctl_d}

  @type option ::
          {:name, atom()}
          | {:daemon_path, Path.t()}
          | {:cli_path, Path.t()}
          | {:start_daemon, boolean()}
          | {:tailscale_dir, Path.t()}
          | {:socket_path, Path.t()}
          | {:tun, tun()}
          | {:command_timeout, pos_integer()}
          | {:status_interval, pos_integer()}
          | {:runtime_dir, Path.t()}
          | {:daemon_log_level, Logger.level() | false}
          | {:daemon_stdio_window, pos_integer()}
          | {:daemon_restart_min, pos_integer()}
          | {:daemon_restart_max, pos_integer()}
          | {:daemon_restart_stable, pos_integer()}
          | {:daemon_restart_jitter, float()}

  @type options :: [option()]
  @type lifecycle_error :: :server_unavailable | :daemon_restarting | :socket_unavailable

  @doc """
  Starts an internally supervised Tailscale instance.
  """
  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    with {:ok, config} <- Config.build(opts) do
      Tailscale.Supervisor.start_link(config)
    end
  end

  @doc false
  @spec child_spec(options()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns fresh, normalized status without exposing upstream JSON.
  """
  @spec status(GenServer.server()) :: {:ok, Status.t()} | {:error, term()}
  def status(server \\ __MODULE__) do
    operation(server, :status, :read, "status", ["--json"])
  end

  @doc """
  Returns the latest combined client, daemon, socket, authentication, and online health.
  """
  @spec health(GenServer.server()) :: {:ok, Health.t()} | {:error, :server_unavailable}
  def health(server \\ __MODULE__), do: Call.call(server, :health)

  @doc """
  Returns the installed Tailscale CLI version.
  """
  @spec version(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def version(server \\ __MODULE__) do
    operation(server, :version, :read, "version", ["--json"], requires_daemon?: false)
  end

  @doc """
  Enrolls the node using typed, validated options.

  The authorization key is passed through a protected volatile file and never
  enters the long-lived server process.
  """
  @spec login([LoginOptions.option()]) :: :ok | {:error, term()}
  def login(opts), do: login(__MODULE__, opts)

  @spec login(GenServer.server(), [LoginOptions.option()]) :: :ok | {:error, term()}
  def login(server, opts) do
    with {:ok, encoded} <- LoginOptions.encode(opts),
         {:ok, context} <- Call.call(server, :secret_context),
         {:ok, secret} <- SecretFile.create(context, encoded.auth_key) do
      try do
        arguments = ["--auth-key=file:#{secret.path}" | encoded.arguments]

        server
        |> operation(:login, :mutation, "login", arguments, cleanup: secret)
        |> redact_login_result(encoded.auth_key)
      after
        SecretFile.cleanup(secret)
      end
    end
  end

  @doc """
  Changes only the explicitly supplied typed preferences using `tailscale set`.
  """
  @spec set([Preferences.change()]) :: :ok | {:error, term()}
  def set(changes), do: set(__MODULE__, changes)

  @spec set(GenServer.server(), [Preferences.change()]) :: :ok | {:error, term()}
  def set(server, changes) do
    with {:ok, arguments} <- Preferences.encode_changes(changes) do
      operation(server, :set, :mutation, "set", arguments)
    end
  end

  @doc """
  Reads the currently configured typed preferences.
  """
  @spec preferences(GenServer.server()) :: {:ok, Preferences.t()} | {:error, term()}
  def preferences(server \\ __MODULE__) do
    operation(server, :preferences, :read, "debug", ["prefs"])
  end

  @doc """
  Returns the configured advertised subnet routes.
  """
  @spec advertised_routes(GenServer.server()) :: {:ok, [route()]} | {:error, term()}
  def advertised_routes(server \\ __MODULE__) do
    with {:ok, preferences} <- preferences(server) do
      {:ok, preferences.advertised_routes}
    end
  end

  @doc """
  Projects advertised, approved, and primary subnet routes.
  """
  @spec route_status(GenServer.server()) :: {:ok, RouteStatus.t()} | {:error, term()}
  def route_status(server \\ __MODULE__) do
    with {:ok, preferences} <- preferences(server),
         {:ok, status} <- status(server) do
      RouteStatus.project(preferences, status)
    end
  end

  @doc """
  Lists locally stored Tailscale account profiles.
  """
  @spec profiles(GenServer.server()) :: {:ok, [Profile.t()]} | {:error, term()}
  def profiles(server \\ __MODULE__) do
    operation(server, :profiles, :read, "switch", ["--list", "--json"])
  end

  @doc """
  Returns the selected local profile.
  """
  @spec current_profile(GenServer.server()) :: {:ok, Profile.t()} | {:error, term()}
  def current_profile(server \\ __MODULE__) do
    operation(server, :current_profile, :read, "switch", ["--list", "--json"])
  end

  @doc """
  Switches to a local profile by ID.
  """
  @spec switch_profile(String.t()) :: :ok | {:error, term()}
  def switch_profile(profile_id), do: switch_profile(__MODULE__, profile_id)

  @spec switch_profile(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def switch_profile(server, profile_id) do
    with :ok <- validate_profile_id(profile_id) do
      operation(server, :switch_profile, :mutation, "switch", [profile_id])
    end
  end

  @doc """
  Removes a local profile by ID.
  """
  @spec remove_profile(String.t()) :: :ok | {:error, term()}
  def remove_profile(profile_id), do: remove_profile(__MODULE__, profile_id)

  @spec remove_profile(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def remove_profile(server, profile_id) do
    with :ok <- validate_profile_id(profile_id) do
      operation(server, :remove_profile, :mutation, "switch", ["remove", profile_id])
    end
  end

  @doc """
  Waits until the daemon socket accepts commands. Authentication is not required.
  """
  @spec await_ready(keyword() | GenServer.server()) :: :ok | {:error, term()}
  def await_ready(opts_or_server \\ [])
  def await_ready(opts) when is_list(opts), do: await_ready(__MODULE__, opts)
  def await_ready(server), do: await_ready(server, [])

  @spec await_ready(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def await_ready(server, opts) do
    with {:ok, timeout} <- waiter_timeout(opts, []) do
      Call.deferred(server, &{:await, &1, :ready, [], timeout}, timeout)
    end
  end

  @doc """
  Waits for a running, online node and optional normalized status requirements.

  Supported requirements are `:authenticated`, `:tailscale_ipv4`, and
  `:tailscale_ipv6`.
  """
  @spec await_online(keyword() | GenServer.server()) :: :ok | {:error, term()}
  def await_online(opts_or_server \\ [])
  def await_online(opts) when is_list(opts), do: await_online(__MODULE__, opts)
  def await_online(server), do: await_online(server, [])

  @spec await_online(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def await_online(server, opts) do
    allowed = [:require]

    with {:ok, timeout} <- waiter_timeout(opts, allowed),
         {:ok, requirements} <- online_requirements(Keyword.get(opts, :require, [])) do
      Call.deferred(server, &{:await, &1, :online, requirements, timeout}, timeout)
    end
  end

  @doc """
  Subscribes the calling process and immediately sends normalized status and health snapshots.
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, :server_unavailable}
  def subscribe(server \\ __MODULE__), do: Call.call(server, {:subscribe, self()})

  @doc """
  Removes the calling process's subscription.
  """
  @spec unsubscribe(GenServer.server()) :: :ok | {:error, :server_unavailable}
  def unsubscribe(server \\ __MODULE__), do: Call.call(server, {:unsubscribe, self()})

  @doc """
  Executes an escape-hatch CLI command with explicit scheduling semantics.

      Tailscale.cli("ip", ["--4"], mode: :read)
      Tailscale.cli(server, "down", [], mode: :mutation)

  """
  @spec cli(String.t(), [String.t()], keyword()) :: {:ok, term()} | {:error, term()}
  def cli(command, arguments, opts), do: cli(__MODULE__, command, arguments, opts)

  @spec cli(GenServer.server(), String.t(), [String.t()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def cli(server, command, arguments, opts) do
    with {:ok, mode, timeout} <- cli_options(opts) do
      operation(server, :cli, mode, command, arguments, timeout: timeout)
    end
  end

  @doc """
  Returns whether Linux IPv4 and IPv6 forwarding are enabled.
  """
  @spec forwarding_status() :: {:ok, forwarding_status()} | {:error, term()}
  def forwarding_status, do: SubnetRouter.forwarding_status()

  @doc """
  Enables Linux forwarding for the current boot and optionally through sysctl.d.
  """
  @spec enable_forwarding([forwarding_option()]) :: :ok | {:error, term()}
  def enable_forwarding(opts \\ []), do: SubnetRouter.enable_forwarding(opts)

  defp operation(server, kind, mode, command, arguments, opts \\ []) do
    specification = %{
      kind: kind,
      mode: mode,
      command: command,
      arguments: arguments,
      requires_daemon?: Keyword.get(opts, :requires_daemon?, true),
      cleanup: Keyword.get(opts, :cleanup)
    }

    specification =
      case Keyword.get(opts, :timeout) do
        nil -> specification
        timeout -> Map.put(specification, :timeout, timeout)
      end

    Call.operation(server, specification)
  end

  defp redact_login_result({:error, %Tailscale.CommandError{} = error}, auth_key) do
    {:error, %{error | output: String.replace(error.output, auth_key, "[REDACTED]")}}
  end

  defp redact_login_result(result, _auth_key), do: result

  defp validate_profile_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_profile_id(_value), do: {:error, :invalid_profile_id}

  defp waiter_timeout(opts, additional_allowed) do
    allowed = [:timeout | additional_allowed]

    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_wait_options}
      Keyword.keys(opts) -- allowed != [] -> {:error, :invalid_wait_options}
      true -> positive_timeout(Keyword.get(opts, :timeout, 30_000))
    end
  end

  defp positive_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  defp positive_timeout(_timeout), do: {:error, :invalid_wait_options}

  defp online_requirements(requirements) when is_list(requirements) do
    allowed = [:authenticated, :tailscale_ipv4, :tailscale_ipv6]

    if Enum.all?(requirements, &(&1 in allowed)) do
      {:ok, Enum.uniq(requirements)}
    else
      {:error, :invalid_online_requirements}
    end
  end

  defp online_requirements(_requirements), do: {:error, :invalid_online_requirements}

  defp cli_options(opts) do
    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_cli_options}
      Keyword.keys(opts) -- [:mode, :timeout] != [] -> {:error, :invalid_cli_options}
      Keyword.get(opts, :mode) not in [:read, :mutation] -> {:error, :invalid_cli_mode}
      true -> cli_timeout(Keyword.get(opts, :mode), Keyword.get(opts, :timeout))
    end
  end

  defp cli_timeout(mode, nil), do: {:ok, mode, nil}

  defp cli_timeout(mode, timeout) when is_integer(timeout) and timeout > 0,
    do: {:ok, mode, timeout}

  defp cli_timeout(_mode, _timeout), do: {:error, :invalid_cli_options}
end
