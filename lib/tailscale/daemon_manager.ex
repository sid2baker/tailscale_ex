defmodule Tailscale.DaemonManager do
  @moduledoc false

  use GenServer

  alias Tailscale.DaemonExit
  alias Tailscale.DaemonHealth
  alias Tailscale.Telemetry

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :daemon_pid,
      :health,
      :restart_timer,
      :stable_timer,
      daemon_generation: 0,
      subscribers: %{},
      stopping?: false
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :registered_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, subscriber) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @spec daemon_pid(GenServer.server()) :: {:ok, pid()} | {:error, :not_running}
  def daemon_pid(server), do: GenServer.call(server, :daemon_pid)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)

    health = %DaemonHealth{
      state: if(config.start_daemon, do: :starting, else: :external),
      restart_attempt: 0,
      last_exit: nil,
      transitioned_at: DateTime.utc_now()
    }

    {:ok, %State{config: config, health: health}, {:continue, :start_daemon}}
  end

  @impl true
  def handle_continue(:start_daemon, %State{config: %{start_daemon: false}} = state) do
    {:noreply, state}
  end

  def handle_continue(:start_daemon, state) do
    {:noreply, start_daemon(state)}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    {state, _monitor} = add_subscriber(state, subscriber)
    send(subscriber, {:tailscale_daemon, :health, state.health})
    {:reply, :ok, state}
  end

  def handle_call(:daemon_pid, _from, %State{daemon_pid: pid} = state) when is_pid(pid) do
    {:reply, {:ok, pid}, state}
  end

  def handle_call(:daemon_pid, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %State{daemon_pid: pid, stopping?: false} = state) do
    state = cancel_timer(state, :stable_timer)
    exit = daemon_exit(reason)
    attempt = state.health.restart_attempt + 1

    Telemetry.execute(
      [:daemon, :exit],
      %{system_time: System.system_time()},
      %{instance: state.config.name, reason: exit.reason, status: exit.status}
    )

    state =
      state
      |> Map.put(:daemon_pid, nil)
      |> transition_health(:restarting, attempt, exit)
      |> schedule_restart(attempt)

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:restart_daemon, %State{stopping?: false} = state) do
    {:noreply, state |> Map.put(:restart_timer, nil) |> start_daemon()}
  end

  def handle_info(
        {:restart_stable, generation},
        %State{daemon_pid: pid, daemon_generation: generation} = state
      )
      when is_pid(pid) do
    {:noreply,
     state
     |> Map.put(:stable_timer, nil)
     |> transition_health(:running, 0, state.health.last_exit)}
  end

  def handle_info({:restart_stable, _generation}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^monitor -> Map.delete(state.subscribers, pid)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = %{state | stopping?: true}
    cancel_timer(state, :restart_timer)
    cancel_timer(state, :stable_timer)

    if is_pid(state.daemon_pid) and Process.alive?(state.daemon_pid) do
      GenServer.stop(state.daemon_pid, :shutdown)
    end

    :ok
  end

  defp start_daemon(state) do
    args = daemon_args(state.config)
    options = daemon_options(state.config)

    case safe_start(state.config.daemon_path, args, options) do
      {:ok, pid} ->
        generation = state.daemon_generation + 1

        stable_timer =
          Process.send_after(
            self(),
            {:restart_stable, generation},
            state.config.daemon_restart_stable
          )

        state
        |> Map.put(:daemon_pid, pid)
        |> Map.put(:daemon_generation, generation)
        |> Map.put(:stable_timer, stable_timer)
        |> transition_health(:running, state.health.restart_attempt, state.health.last_exit)

      {:error, reason} ->
        exit = daemon_exit(reason)
        attempt = state.health.restart_attempt + 1

        state
        |> transition_health(:restarting, attempt, exit)
        |> schedule_restart(attempt)
    end
  end

  defp safe_start(path, args, options) do
    MuonTrap.Daemon.start_link(path, args, options)
  catch
    :exit, reason -> {:error, reason}
  end

  defp daemon_args(config) do
    [
      "--statedir=#{config.tailscale_dir}",
      "--socket=#{config.socket_path}"
    ] ++ tun_args(config.tun)
  end

  defp tun_args(:kernel), do: []
  defp tun_args(:userspace), do: ["--tun=userspace-networking"]
  defp tun_args(interface_name), do: ["--tun=#{interface_name}"]

  defp daemon_options(config) do
    logging =
      case config.daemon_log_level do
        false -> [logger_fun: fn _line -> :ok end]
        level -> [log_output: level]
      end

    [
      stderr_to_stdout: true,
      stdio_window: config.daemon_stdio_window,
      exit_status_to_reason: &{:tailscaled_exit, &1}
    ] ++ logging
  end

  defp daemon_exit({:tailscaled_exit, status}) do
    %DaemonExit{reason: :exit_status, status: status, occurred_at: DateTime.utc_now()}
  end

  defp daemon_exit(reason) do
    %DaemonExit{reason: sanitize_reason(reason), status: nil, occurred_at: DateTime.utc_now()}
  end

  defp sanitize_reason(reason) when reason in [:normal, :shutdown, :killed, :epipe], do: reason
  defp sanitize_reason(_reason), do: :daemon_failed

  defp schedule_restart(state, attempt) do
    delay = restart_delay(state.config, attempt)
    timer = Process.send_after(self(), :restart_daemon, delay)

    Telemetry.execute(
      [:daemon, :restart],
      %{delay: delay},
      %{instance: state.config.name, attempt: attempt}
    )

    %{state | restart_timer: timer}
  end

  defp restart_delay(config, attempt) do
    multiplier = Integer.pow(2, min(attempt - 1, 20))
    base = min(config.daemon_restart_min * multiplier, config.daemon_restart_max)
    jitter(base, config.daemon_restart_jitter)
  end

  defp jitter(base, 0), do: base

  defp jitter(base, ratio) do
    spread = round(base * ratio)
    offset = :rand.uniform(spread * 2 + 1) - spread - 1
    max(base + offset, 0)
  end

  defp transition_health(state, daemon_state, attempt, last_exit) do
    health = %DaemonHealth{
      state: daemon_state,
      restart_attempt: attempt,
      last_exit: last_exit,
      transitioned_at: DateTime.utc_now()
    }

    if state.health == health do
      state
    else
      Enum.each(Map.keys(state.subscribers), &send(&1, {:tailscale_daemon, :health, health}))
      %{state | health: health}
    end
  end

  defp add_subscriber(state, subscriber) do
    case Map.fetch(state.subscribers, subscriber) do
      {:ok, monitor} ->
        {state, monitor}

      :error ->
        monitor = Process.monitor(subscriber)
        {%{state | subscribers: Map.put(state.subscribers, subscriber, monitor)}, monitor}
    end
  end

  defp cancel_timer(state, field) do
    if timer = Map.get(state, field), do: Process.cancel_timer(timer)
    Map.put(state, field, nil)
  end
end
