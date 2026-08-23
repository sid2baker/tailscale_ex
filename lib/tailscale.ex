defmodule Tailscale do
  @moduledoc """
  A supervised GenServer wrapper for Tailscale daemon and CLI.

  This module manages the lifecycle of the `tailscaled` daemon using MuonTrap
  and provides convenience functions for checking Tailscale status and executing
  CLI commands.

  ## Usage

      # Start as part of a supervision tree
      children = [
        {Tailscale, daemon_path: "/usr/sbin/tailscaled", cli_path: "/usr/bin/tailscale"}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      # Check if Tailscale is online
      Tailscale.online?()

      # Execute CLI commands
      Tailscale.cli("status", ["--json"])
      Tailscale.cli("up", ["--hostname=mynode"])
  """

  use GenServer
  require Logger

  alias Tailscale.CommandError
  alias Tailscale.Preferences
  alias Tailscale.RouteStatus
  alias Tailscale.SubnetRouter

  @default_daemon_path "/usr/sbin/tailscaled"
  @default_cli_path "/usr/bin/tailscale"
  @default_tailscale_dir "/data/tailscale"
  @default_socket_path "/run/tailscale/tailscaled.sock"
  @default_timeout 5_000
  @default_tun :kernel
  @default_readiness_timeout 10_000
  @default_readiness_interval 100

  @type tun :: :kernel | :userspace | String.t()
  @type route :: String.t()
  @type preference_change :: {:advertise_routes, [route()]}
  @type readiness_option :: {:timeout, pos_integer()} | {:interval, pos_integer()}
  @type forwarding_family :: :ipv4 | :ipv6
  @type forwarding_status :: %{required(:ipv4) => boolean(), required(:ipv6) => boolean()}
  @type forwarding_option ::
          {:families, [forwarding_family()]}
          | {:persist, false | :sysctl_d}

  @type option ::
          {:daemon_path, Path.t()}
          | {:cli_path, Path.t()}
          | {:start_daemon, boolean()}
          | {:tailscale_dir, Path.t()}
          | {:socket_path, Path.t()}
          | {:tun, tun()}
          | {:timeout, non_neg_integer()}
          | {:name, atom()}

  @type options :: [option()]

  defmodule State do
    @moduledoc false
    defstruct [
      :daemon_pid,
      :daemon_path,
      :cli_path,
      :start_daemon,
      :socket_path,
      :tailscale_dir,
      :tun,
      :version,
      :timeout
    ]

    @type t :: %__MODULE__{
            daemon_pid: pid() | nil,
            daemon_path: Path.t(),
            cli_path: Path.t(),
            start_daemon: boolean(),
            socket_path: Path.t(),
            tailscale_dir: Path.t(),
            tun: Tailscale.tun(),
            version: String.t() | nil,
            timeout: non_neg_integer()
          }
  end

  # Client API

  @doc """
  Starts the Tailscale GenServer with the given options.

  ## Options

    * `:name` - Name for the GenServer (default: `#{__MODULE__}`)
    * `:daemon_path` - Path to the `tailscaled` binary (default: `#{@default_daemon_path}`)
    * `:cli_path` - Path to the `tailscale` CLI binary (default: `#{@default_cli_path}`)
    * `:start_daemon` - Start and manage `tailscaled`; set to `false` to use an existing daemon (default: `true`)
    * `:socket_path` - Path to the Unix socket (default: `#{@default_socket_path}`)
    * `:tailscale_dir` - Directory for Tailscale state (default: `#{@default_tailscale_dir}`)
    * `:tun` - TUN mode: `:kernel`, `:userspace`, or a custom interface name (default: `#{inspect(@default_tun)}`)
    * `:timeout` - Command timeout in milliseconds (default: `#{@default_timeout}`)

  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    daemon_path = Keyword.get(opts, :daemon_path, @default_daemon_path)
    cli_path = Keyword.get(opts, :cli_path, @default_cli_path)
    start_daemon = Keyword.get(opts, :start_daemon, true)
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)
    tailscale_dir = Keyword.get(opts, :tailscale_dir, @default_tailscale_dir)
    tun = Keyword.get(opts, :tun, @default_tun)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with :ok <- validate_tun(tun),
         :ok <- validate_daemon(daemon_path, tailscale_dir, start_daemon),
         :ok <- validate_executable(cli_path),
         :ok <- ensure_directory(Path.dirname(socket_path)) do
      GenServer.start_link(
        __MODULE__,
        {daemon_path, cli_path, start_daemon, socket_path, tailscale_dir, tun, timeout},
        name: name
      )
    end
  end

  @doc """
  Checks if Tailscale is currently online.

  Returns `true` if the status shows `Online == true`, `false` otherwise.
  """
  @spec online?(GenServer.server()) :: boolean()
  def online?(server \\ __MODULE__) do
    GenServer.call(server, :online?)
  end

  @doc """
  Returns the current daemon PID.
  """
  @spec daemon_pid(GenServer.server()) :: {:ok, pid()} | {:error, :not_started}
  def daemon_pid(server \\ __MODULE__) do
    GenServer.call(server, :daemon_pid)
  end

  @doc """
  Returns the Tailscale version.
  """
  @spec version(GenServer.server()) :: {:ok, String.t()} | {:error, :not_available}
  def version(server \\ __MODULE__) do
    GenServer.call(server, :version)
  end

  @doc """
  Logs in to Tailscale using the provided authentication key.
  """
  @spec login(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def login(server \\ __MODULE__, auth_key) do
    GenServer.call(server, {:login, auth_key})
  end

  @doc """
  Returns the current status of the Tailscale daemon.
  """
  @spec status(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Changes explicitly specified Tailscale preferences.

  Unspecified preferences remain unchanged because this API always uses
  `tailscale set`, never `tailscale up`. Routes are normalized and deduplicated;
  an empty list withdraws every advertised route.

  ## Examples

      Tailscale.set(advertise_routes: ["192.168.10.0/24", "10.20.0.0/16"])
      Tailscale.set(my_server, advertise_routes: [])

  """
  @spec set([preference_change()]) :: :ok | {:error, term()}
  def set(changes), do: set(__MODULE__, changes)

  @spec set(GenServer.server(), [preference_change()]) :: :ok | {:error, term()}
  def set(server, changes) do
    with {:ok, arguments} <- Preferences.encode_changes(changes),
         {:ok, _output} <- cli(server, "set", arguments) do
      :ok
    end
  end

  @doc """
  Reads the preferences currently configured in `tailscaled`.

  This returns a stable Elixir projection over the JSON emitted by
  `tailscale debug prefs`.
  """
  @spec preferences(GenServer.server()) :: {:ok, Preferences.t()} | {:error, term()}
  def preferences(server \\ __MODULE__) do
    with {:ok, response} <- cli(server, "debug", ["prefs"]) do
      Preferences.from_cli(response)
    end
  end

  @doc """
  Returns the subnet routes currently configured for advertisement.
  """
  @spec advertised_routes(GenServer.server()) :: {:ok, [route()]} | {:error, term()}
  def advertised_routes(server \\ __MODULE__) do
    with {:ok, preferences} <- preferences(server) do
      {:ok, preferences.advertised_routes}
    end
  end

  @doc """
  Projects the node's advertised, control-plane-approved, and primary routes.

  Approval remains a Tailscale policy or admin-console responsibility.
  """
  @spec route_status(GenServer.server()) :: {:ok, RouteStatus.t()} | {:error, term()}
  def route_status(server \\ __MODULE__) do
    with {:ok, preferences} <- preferences(server),
         {:ok, status} <- status(server) do
      RouteStatus.project(preferences, status)
    end
  end

  @doc """
  Waits until the `tailscaled` socket accepts CLI commands.

  Readiness does not require authentication or an online node. States such as
  `NeedsLogin` are ready, which makes this suitable before commissioning.

  ## Options

    * `:timeout` - total wait in milliseconds (default: `#{@default_readiness_timeout}`)
    * `:interval` - delay between attempts in milliseconds (default: `#{@default_readiness_interval}`)

  """
  @spec await_ready() :: :ok | {:error, term()}
  def await_ready, do: await_ready(__MODULE__, [])

  @spec await_ready([readiness_option()] | GenServer.server()) :: :ok | {:error, term()}
  def await_ready(opts) when is_list(opts), do: await_ready(__MODULE__, opts)
  def await_ready(server), do: await_ready(server, [])

  @spec await_ready(GenServer.server(), [readiness_option()]) :: :ok | {:error, term()}
  def await_ready(server, opts) do
    with {:ok, timeout, interval} <- readiness_options(opts) do
      deadline = System.monotonic_time(:millisecond) + timeout
      await_ready_until(server, deadline, interval, nil)
    end
  end

  @doc """
  Returns whether Linux IPv4 and IPv6 forwarding are enabled.
  """
  @spec forwarding_status() :: {:ok, forwarding_status()} | {:error, term()}
  def forwarding_status do
    SubnetRouter.forwarding_status()
  end

  @doc """
  Enables Linux kernel forwarding.

  By default both IPv4 and IPv6 forwarding are enabled for the current boot by
  writing directly to `/proc`. Use `families: [:ipv4]` or `families: [:ipv6]`
  to enable only one family.

  Pass `persist: :sysctl_d` to also write an idempotent
  `/etc/sysctl.d/99-tailscale.conf`. The calling OS process must have permission
  to write these files; this function never invokes `sudo`.

  ## Examples

      Tailscale.enable_forwarding()
      Tailscale.enable_forwarding(families: [:ipv4], persist: :sysctl_d)

  """
  @spec enable_forwarding([forwarding_option()]) :: :ok | {:error, term()}
  def enable_forwarding(opts \\ []) do
    SubnetRouter.enable_forwarding(opts)
  end

  @doc """
  Executes a Tailscale CLI command with the given arguments.

  ## Examples

      Tailscale.cli("status", ["--json"])
      Tailscale.cli("up", ["--hostname=mynode"])

  """
  @spec cli(GenServer.server(), String.t(), [String.t()]) ::
          {:ok, String.t() | map()} | {:error, term()}
  def cli(server \\ __MODULE__, command, args) do
    GenServer.call(server, {:cli, command, args}, :infinity)
  end

  # Server callbacks

  @impl true
  def init({daemon_path, cli_path, start_daemon, socket_path, tailscale_dir, tun, timeout}) do
    state = %State{
      daemon_path: daemon_path,
      cli_path: cli_path,
      start_daemon: start_daemon,
      tailscale_dir: tailscale_dir,
      socket_path: socket_path,
      daemon_pid: nil,
      tun: tun,
      version: nil,
      timeout: timeout
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state) do
    # Check version first
    version =
      case exec_command(state, "version", ["--json"]) do
        {:ok, %{"majorMinorPatch" => v}} -> v
        {:ok, output} -> output
        _ -> "unknown"
      end

    Logger.info("Tailscale version: #{version}")

    state = %{state | version: version}

    if state.start_daemon do
      case start_daemon(state) do
        {:ok, pid} ->
          Logger.info("Tailscale daemon started with PID #{inspect(pid)}")
          {:noreply, %{state | daemon_pid: pid}}

        {:error, reason} ->
          Logger.error("Failed to start Tailscale daemon: #{inspect(reason)}")
          {:stop, reason, state}
      end
    else
      Logger.info("Using existing Tailscale daemon at #{state.socket_path}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:cli_path}, _from, state) do
    {:reply, state.cli_path, state}
  end

  def handle_call({:socket_path}, _from, state) do
    {:reply, state.socket_path, state}
  end

  def handle_call(:version, _from, state) do
    {:reply, {:ok, state.version}, state}
  end

  def handle_call({:login, auth_key}, _from, state) do
    result = exec_command(state, "login", ["--auth-key", auth_key])
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    case exec_command(state, "status", ["--json"]) do
      {:ok, json} -> {:reply, {:ok, json}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:daemon_pid, _from, %State{daemon_pid: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:online?, _from, state) do
    case exec_command(state, "status", ["--json"]) do
      {:ok, %{"Self" => %{"Online" => online?}}} ->
        {:reply, online?, state}

      {:error, reason} ->
        Logger.warning("Failed to check Tailscale status: #{inspect(reason)}")
        {:reply, false, state}
    end
  end

  def handle_call(:daemon_pid, _from, %State{daemon_pid: pid} = state) do
    {:reply, {:ok, pid}, state}
  end

  def handle_call({:cli, command, args}, _from, state) do
    result = exec_command(state, command, args)
    {:reply, result, state}
  end

  def handle_call({:readiness, timeout}, _from, state) do
    result = exec_command(state, "status", ["--json"], timeout)
    {:reply, result, state}
  end

  @impl true
  def terminate(reason, %State{daemon_pid: daemon_pid}) do
    Logger.warning("Tailscale GenServer terminating. Reason: #{inspect(reason)}")

    if is_pid(daemon_pid) and Process.alive?(daemon_pid) do
      GenServer.stop(daemon_pid)
    end

    :ok
  end

  # Private functions

  defp readiness_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:timeout, :interval] == [] do
      timeout = Keyword.get(opts, :timeout, @default_readiness_timeout)
      interval = Keyword.get(opts, :interval, @default_readiness_interval)

      if is_integer(timeout) and timeout > 0 and is_integer(interval) and interval > 0 do
        {:ok, timeout, interval}
      else
        {:error, {:invalid_readiness_options, opts}}
      end
    else
      {:error, {:invalid_readiness_options, opts}}
    end
  end

  defp readiness_options(opts), do: {:error, {:invalid_readiness_options, opts}}

  defp await_ready_until(server, deadline, interval, last_error) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:readiness_timeout, last_error}}
    else
      case readiness_attempt(server, remaining) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          sleep_until_next_attempt(deadline, interval)
          await_ready_until(server, deadline, interval, readiness_error(reason, last_error))
      end
    end
  end

  defp readiness_attempt(server, timeout) do
    GenServer.call(server, {:readiness, timeout}, timeout)
  catch
    :exit, reason -> {:error, {:server_unavailable, reason}}
  end

  defp readiness_error({:server_unavailable, _reason}, previous_error)
       when not is_nil(previous_error),
       do: previous_error

  defp readiness_error(error, _previous_error), do: error

  defp sleep_until_next_attempt(deadline, interval) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    Process.sleep(min(interval, remaining))
  end

  defp start_daemon(state) do
    daemon_args =
      [
        "--statedir=#{state.tailscale_dir}",
        "--socket=#{state.socket_path}"
      ] ++ tun_args(state.tun)

    MuonTrap.Daemon.start_link(state.daemon_path, daemon_args, log_output: :info)
  end

  defp exec_command(state, command, args) when is_list(args) do
    exec_command(state, command, args, state.timeout)
  end

  defp exec_command(state, command, args, timeout) when is_list(args) do
    # Add --socket flag to all commands.
    # It needs to be the first argument for tailscale to work correctly.
    args_with_socket = ["--socket=#{state.socket_path}", command] ++ args

    muontrap_opts = [
      stderr_to_stdout: true,
      timeout: timeout
    ]

    case MuonTrap.cmd(state.cli_path, args_with_socket, muontrap_opts) do
      {output, 0} ->
        trimmed = String.trim(output)
        # Try to decode as JSON, fall back to string
        case JSON.decode(trimmed) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:ok, trimmed}
        end

      {output, :timeout} ->
        {:error,
         %CommandError{
           command: command,
           exit_code: nil,
           output: String.trim(output),
           reason: :timeout
         }}

      {output, exit_code} ->
        {:error,
         %CommandError{
           command: command,
           exit_code: exit_code,
           output: String.trim(output),
           reason: :exit_status
         }}
    end
  end

  defp tun_args(:kernel), do: []
  defp tun_args(:userspace), do: ["--tun=userspace-networking"]
  defp tun_args(interface_name), do: ["--tun=#{interface_name}"]

  defp validate_tun(tun) when tun in [:kernel, :userspace], do: :ok

  defp validate_tun(tun) when is_binary(tun) do
    if String.trim(tun) == "" do
      {:error, ":tun interface name cannot be empty"}
    else
      :ok
    end
  end

  defp validate_tun(_tun) do
    {:error, ":tun must be :kernel, :userspace, or an interface name"}
  end

  defp validate_daemon(_daemon_path, _tailscale_dir, false), do: :ok

  defp validate_daemon(daemon_path, tailscale_dir, true) do
    with :ok <- validate_executable(daemon_path) do
      ensure_directory(tailscale_dir)
    end
  end

  defp validate_daemon(_daemon_path, _tailscale_dir, _start_daemon) do
    {:error, ":start_daemon must be a boolean"}
  end

  defp validate_executable(path) do
    cond do
      not File.exists?(path) ->
        {:error, "File #{path} not found at"}

      not File.regular?(path) ->
        {:error, "File at #{path} is not a regular file"}

      not executable?(path) ->
        {:error, "File at #{path} is not executable"}

      true ->
        :ok
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        # Check if any execute bit is set (owner, group, or other)
        Bitwise.band(mode, 0o111) != 0

      {:error, _} ->
        false
    end
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:validation_failed, "Failed to create directory #{path}: #{inspect(reason)}"}}
    end
  end
end
