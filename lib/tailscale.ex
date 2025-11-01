defmodule Tailscale do
  @moduledoc """
  A supervised GenServer wrapper for Tailscale daemon and CLI.

  This module manages the lifecycle of the `tailscaled` daemon using MuonTrap
  and provides convenience functions for checking Tailscale status.

  ## Usage

      # Start as part of a supervision tree
      children = [
        {Tailscale, daemon_path: "/usr/sbin/tailscaled", cli_path: "/usr/bin/tailscale"}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      # Check if Tailscale is online
      Tailscale.online?()

  For CLI commands, see `Tailscale.CLI`.
  """

  use GenServer
  require Logger

  @default_daemon_path "/usr/sbin/tailscaled"
  @default_cli_path "/usr/bin/tailscale"
  @default_tailscale_dir "/tmp/tailscale"
  @default_socket_path "/tmp/tailscale/tailscaled.sock"

  @type option ::
          {:daemon_path, Path.t()}
          | {:cli_path, Path.t()}
          | {:tailscale_dir, Path.t()}
          | {:socket_path, Path.t()}
          | {:name, atom()}

  @type options :: [option()]

  defmodule State do
    @moduledoc false
    defstruct [:daemon_pid, :daemon_path, :cli_path, :tailscale_dir, :socket_path, :version]

    @type t :: %__MODULE__{
            daemon_pid: pid() | nil,
            daemon_path: Path.t(),
            cli_path: Path.t(),
            tailscale_dir: Path.t(),
            socket_path: Path.t(),
            version: String.t() | nil
          }
  end

  # Client API

  @doc """
  Starts the Tailscale GenServer with the given options.

  ## Options

    * `:daemon_path` - Path to the `tailscaled` binary (default: `#{@default_daemon_path}`)
    * `:cli_path` - Path to the `tailscale` CLI binary (default: `#{@default_cli_path}`)
    * `:tailscale_dir` - Directory for Tailscale state (default: `#{@default_tailscale_dir}`)
    * `:socket_path` - Path to the Unix socket (default: `#{@default_socket_path}`)
    * `:name` - Name for the GenServer (default: `#{__MODULE__}`)

  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a child specification for use in a supervision tree.
  """
  @spec child_spec(options()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Checks if Tailscale is currently online.

  Returns `true` if the status shows `Online == true`, `false` otherwise.
  """
  @spec online?(GenServer.server()) :: boolean()
  def online?(server \\ __MODULE__) do
    case Tailscale.CLI.status(server, json: true) do
      {:ok, status} when is_map(status) ->
        Map.get(status, "Self", %{}) |> Map.get("Online", false)

      _ ->
        false
    end
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

  # Server callbacks

  @impl true
  def init(opts) do
    daemon_path = Keyword.get(opts, :daemon_path, @default_daemon_path)
    cli_path = Keyword.get(opts, :cli_path, @default_cli_path)
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)
    tailscale_dir = Keyword.get(opts, :tailscale_dir, @default_tailscale_dir)

    # Ensure directories exist
    File.mkdir_p!(tailscale_dir)

    # Ensure socket directory exists
    socket_dir = Path.dirname(socket_path)
    File.mkdir_p!(socket_dir)

    state = %State{
      daemon_path: daemon_path,
      cli_path: cli_path,
      tailscale_dir: tailscale_dir,
      socket_path: socket_path,
      daemon_pid: nil,
      version: nil
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state) do
    # Check version first
    version = check_version(state)
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
  def handle_call(:daemon_pid, _from, %State{daemon_pid: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:daemon_pid, _from, %State{daemon_pid: pid} = state) do
    {:reply, {:ok, pid}, state}
  end

  def handle_call(:version, _from, %State{version: nil} = state) do
    {:reply, {:error, :not_available}, state}
  end

  def handle_call(:version, _from, %State{version: version} = state) do
    {:reply, {:ok, version}, state}
  end

  def handle_call({:cli_path}, _from, state) do
    {:reply, state.cli_path, state}
  end

  def handle_call({:socket_path}, _from, state) do
    {:reply, state.socket_path, state}
  end

  @impl true
  def terminate(_reason, %State{daemon_pid: nil}), do: :ok

  def terminate(_reason, %State{daemon_pid: pid}) when is_pid(pid) do
    Logger.info("Stopping Tailscale daemon")
    GenServer.stop(pid)
    :ok
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

  defp check_version(state) do
    case System.cmd(state.cli_path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse first line to get version number
        output
        |> String.split("\n", trim: true)
        |> List.first()
        |> String.trim()

      {_output, _exit_code} ->
        "unknown"
    end
  end
end
