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

  @default_daemon_path "/usr/sbin/tailscaled"
  @default_cli_path "/usr/bin/tailscale"
  @default_tailscale_dir "/data/tailscale"
  @default_socket_path "/run/tailscale/tailscaled.sock"
  @default_timeout 5_000

  @type option ::
          {:daemon_path, Path.t()}
          | {:cli_path, Path.t()}
          | {:tailscale_dir, Path.t()}
          | {:socket_path, Path.t()}
          | {:timeout, non_neg_integer()}
          | {:name, atom()}

  @type options :: [option()]

  defmodule State do
    @moduledoc false
    defstruct [:daemon_pid, :daemon_path, :cli_path, :socket_path, :tailscale_dir, :version, :timeout]

    @type t :: %__MODULE__{
            daemon_pid: pid() | nil,
            daemon_path: Path.t(),
            cli_path: Path.t(),
            socket_path: Path.t(),
            tailscale_dir: Path.t(),
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
    * `:socket_path` - Path to the Unix socket (default: `#{@default_socket_path}`)
    * `:tailscale_dir` - Directory for Tailscale state (default: `#{@default_tailscale_dir}`)
    * `:timeout` - Command timeout in milliseconds (default: `#{@default_timeout}`)

  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    daemon_path = Keyword.get(opts, :daemon_path, @default_daemon_path)
    cli_path = Keyword.get(opts, :cli_path, @default_cli_path)
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)
    tailscale_dir = Keyword.get(opts, :tailscale_dir, @default_tailscale_dir)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with :ok <- validate_executable(daemon_path),
         :ok <- validate_executable(cli_path),
         :ok <- ensure_directory(Path.dirname(socket_path)),
         :ok <- ensure_directory(tailscale_dir) do
      GenServer.start_link(__MODULE__, {daemon_path, cli_path, socket_path, tailscale_dir, timeout},
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
  Executes a Tailscale CLI command with the given arguments.

  ## Examples

      Tailscale.cli("status", ["--json"])
      Tailscale.cli("up", ["--hostname=mynode"])

  """
  @spec cli(GenServer.server(), String.t(), [String.t()]) :: {:ok, String.t() | map()} | {:error, term()}
  def cli(server \\ __MODULE__, command, args) do
    GenServer.call(server, {:cli, command, args}, :infinity)
  end

  # Server callbacks

  @impl true
  def init({daemon_path, cli_path, socket_path, tailscale_dir, timeout}) do
    state = %State{
      daemon_path: daemon_path,
      cli_path: cli_path,
      tailscale_dir: tailscale_dir,
      socket_path: socket_path,
      daemon_pid: nil,
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

    # Start daemon
    case start_daemon(state) do
      {:ok, pid} ->
        Logger.info("Tailscale daemon started with PID #{inspect(pid)}")
        {:noreply, %{state | daemon_pid: pid, version: version}}

      {:error, reason} ->
        Logger.error("Failed to start Tailscale daemon: #{inspect(reason)}")
        {:stop, reason, state}
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

  def handle_call(_msg, _from, %State{daemon_pid: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:online?, _from, state) do
    case exec_command(state, "status", ["--json"]) do
      {:ok, %{"Self" => %{"Online" => online?}}} -> {:reply, online?, state}
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

  # Private functions

  defp start_daemon(state) do
    MuonTrap.Daemon.start_link(
      state.daemon_path,
      [
        "--tun=userspace-networking",
        "--statedir=#{state.tailscale_dir}",
        "--socket=#{state.socket_path}"
      ]
    )
  end

  defp exec_command(state, command, args \\ []) when is_list(args) do
    # Add --socket flag to all commands
    args_with_socket = [command | args] ++ ["--socket=#{state.socket_path}"]
    muontrap_opts = [
      stderr_to_stdout: true,
      timeout: state.timeout
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
        {:error, {:timeout, String.trim(output)}}

      {output, exit_code} ->
        {:error, {exit_code, String.trim(output)}}
    end
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
      :ok -> :ok
      {:error, reason} -> {:error, {:validation_failed, "Failed to create directory #{path}: #{inspect(reason)}"}}
    end
  end
end
