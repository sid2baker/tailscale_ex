defmodule Tailscale.Daemon do
  @moduledoc false
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :daemon))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{opts: opts, pid: nil, delay: Keyword.get(opts, :retry_min, 200)}

    if Keyword.get(opts, :manage_daemon, false) do
      send(self(), :start)
      {:ok, state}
    else
      publish(state, :external)
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:start, state) do
    case start_daemon(state.opts) do
      {:ok, pid} ->
        Process.send_after(self(), {:stable, pid}, 30_000)
        publish(state, :running)
        {:noreply, %{state | pid: pid}}

      {:error, _reason} ->
        {:noreply, restart(state)}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{pid: pid} = state),
    do: {:noreply, restart(%{state | pid: nil})}

  def handle_info({:stable, pid}, %{pid: pid} = state),
    do: {:noreply, %{state | delay: Keyword.get(state.opts, :retry_min, 200)}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{pid: pid}) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
  end

  defp restart(state) do
    publish(state, :restarting)
    Process.send_after(self(), :start, state.delay)
    %{state | delay: min(state.delay * 2, Keyword.get(state.opts, :retry_max, 30_000))}
  end

  defp start_daemon(opts) do
    directory = Keyword.fetch!(opts, :state_dir)
    socket = Keyword.fetch!(opts, :socket)

    tun =
      case Keyword.get(opts, :tun, :kernel) do
        :kernel -> "tailscale0"
        :userspace -> "userspace-networking"
        interface when is_binary(interface) -> interface
      end

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.mkdir_p(Path.dirname(socket)) do
      MuonTrap.Daemon.start_link(
        Keyword.get(opts, :daemon_path, "tailscaled"),
        [
          "--statedir=#{directory}",
          "--socket=#{socket}",
          "--tun=#{tun}",
          "--port=#{Keyword.get(opts, :port, 0)}"
        ],
        stderr_to_stdout: true,
        logger_fun: fn _line -> :ok end,
        env: [{"TS_NO_LOGS_NO_SUPPORT", "true"}, {"STATE_DIRECTORY", directory}]
      )
    end
  rescue
    _ -> {:error, :daemon_start_failed}
  catch
    :exit, _ -> {:error, :daemon_start_failed}
  end

  defp publish(state, value),
    do: PropertyTable.put(Keyword.fetch!(state.opts, :table), ["daemon", "state"], value)
end
