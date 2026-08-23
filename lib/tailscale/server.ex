defmodule Tailscale.Server do
  @moduledoc false

  use GenServer

  alias Tailscale.Command
  alias Tailscale.CommandError
  alias Tailscale.DaemonHealth
  alias Tailscale.Health
  alias Tailscale.Operation
  alias Tailscale.Preferences
  alias Tailscale.Profile
  alias Tailscale.Scheduler
  alias Tailscale.SecretFile
  alias Tailscale.Server.State
  alias Tailscale.Status
  alias Tailscale.Subscriptions
  alias Tailscale.Telemetry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    with {:ok, secret_context} <- SecretFile.context(config.runtime_dir, config.name) do
      SecretFile.cleanup_abandoned(secret_context)

      state = %State{
        config: config,
        task_supervisor: Keyword.fetch!(opts, :task_supervisor),
        daemon_manager: Keyword.fetch!(opts, :daemon_manager),
        daemon_health: %DaemonHealth{state: :starting, transitioned_at: DateTime.utc_now()},
        status: Status.unknown(),
        health: Health.initial(),
        secret_context: secret_context
      }

      {:ok, state, {:continue, :subscribe_daemon}}
    end
  end

  @impl true
  def handle_continue(:subscribe_daemon, state) do
    :ok = Tailscale.DaemonManager.subscribe(state.daemon_manager, self())
    {:noreply, schedule_poll(state, 0)}
  end

  @impl true
  def handle_call({:operation, id, specification}, from, state) do
    case operation_error(state, specification) do
      :ok ->
        operation = build_operation(id, specification, from, state.config.command_timeout)
        state = register_operation(state, operation)
        {:noreply, dispatch_operation(state, id)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:await, id, type, requirements, timeout}, from, state) do
    if waiter_satisfied?(type, requirements, state) do
      {:reply, :ok, state}
    else
      waiter = build_waiter(id, type, requirements, timeout, from)
      state = state |> put_waiter(waiter) |> maybe_start_poll()
      {:noreply, state}
    end
  end

  def handle_call(:status_snapshot, _from, state), do: {:reply, {:ok, state.status}, state}
  def handle_call(:health, _from, state), do: {:reply, {:ok, state.health}, state}
  def handle_call(:secret_context, _from, state), do: {:reply, {:ok, state.secret_context}, state}

  def handle_call({:subscribe, subscriber}, _from, state) do
    subscriptions = Subscriptions.add(state.subscriptions, subscriber, state.status, state.health)
    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscriptions: Subscriptions.remove(state.subscriptions, subscriber)}}
  end

  @impl true
  def handle_cast({:cancel_operation, id}, state) do
    {:noreply, cancel_by_id(state, id, nil)}
  end

  @impl true
  def handle_info({:tailscale_daemon, :health, daemon_health}, state) do
    state = %{state | daemon_health: daemon_health}

    state =
      if daemon_health.state in [:starting, :restarting, :stopped] do
        state
        |> cancel_daemon_operations({:error, :daemon_restarting})
        |> invalidate_status()
      else
        state
      end

    state = state |> update_health() |> evaluate_waiters()

    state =
      if daemon_health.state in [:running, :external] do
        maybe_start_poll(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:status_poll, state) do
    state = schedule_poll(%{state | poll_timer: nil}, state.config.status_interval)
    {:noreply, maybe_start_poll(state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.task_refs, ref) do
      {:ok, id} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_operation(state, id, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.task_refs, ref) do
      {:ok, _id} when reason == :normal ->
        # Large task results can arrive through the task alias just after the
        # monitor signal. Keep the operation until its result or timeout.
        {:noreply, state}

      {:ok, id} ->
        error = task_exit_error(state, id, reason)
        {:noreply, finish_operation(state, id, error)}

      :error ->
        handle_monitor_down(state, ref, pid)
    end
  end

  def handle_info({:operation_timeout, id}, state) do
    {:noreply, timeout_operation(state, id)}
  end

  def handle_info({:waiter_timeout, id}, state) do
    {:noreply, timeout_waiter(state, id)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.operations, fn {_id, operation} ->
      terminate_task(state.task_supervisor, operation)
      cleanup(operation)
    end)

    :ok
  end

  defp build_operation(id, specification, from, default_timeout) do
    caller = elem(from, 0)
    monitor = Process.monitor(caller)
    timeout = Map.get(specification, :timeout, default_timeout)

    %Operation{
      id: id,
      mode: Map.fetch!(specification, :mode),
      kind: Map.fetch!(specification, :kind),
      command: Map.fetch!(specification, :command),
      arguments: Map.get(specification, :arguments, []),
      timeout: timeout,
      deadline: System.monotonic_time(:millisecond) + timeout,
      from: from,
      caller: caller,
      caller_monitor: monitor,
      deadline_timer: Process.send_after(self(), {:operation_timeout, id}, timeout),
      cleanup: Map.get(specification, :cleanup),
      requires_daemon?: Map.get(specification, :requires_daemon?, true)
    }
  end

  defp build_internal_poll(state) do
    id = make_ref()
    timeout = state.config.command_timeout

    %Operation{
      id: id,
      mode: :read,
      kind: :poll_status,
      command: "status",
      arguments: ["--json"],
      timeout: timeout,
      deadline: System.monotonic_time(:millisecond) + timeout,
      deadline_timer: Process.send_after(self(), {:operation_timeout, id}, timeout),
      internal?: true,
      requires_daemon?: true
    }
  end

  defp register_operation(state, operation) do
    caller_monitors =
      Map.put(state.caller_monitors, operation.caller_monitor, {:operation, operation.id})

    operations = Map.put(state.operations, operation.id, operation)
    %{state | operations: operations, caller_monitors: caller_monitors}
  end

  defp register_internal_operation(state, operation) do
    %{state | operations: Map.put(state.operations, operation.id, operation)}
  end

  defp dispatch_operation(state, id) do
    operation = Map.fetch!(state.operations, id)

    case operation.mode do
      :read -> start_task(state, operation)
      :mutation -> enqueue_mutation(state, operation)
    end
  end

  defp enqueue_mutation(%State{active_mutation: nil} = state, operation) do
    state |> Map.put(:active_mutation, operation.id) |> start_task(operation)
  end

  defp enqueue_mutation(state, operation) do
    %{state | mutation_queue: Scheduler.enqueue(state.mutation_queue, operation.id)}
  end

  defp start_task(state, operation) do
    remaining = max(operation.deadline - System.monotonic_time(:millisecond), 1)
    config = state.config
    cleanup_target = operation.cleanup

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        try do
          Command.run(
            config,
            operation.kind,
            operation.mode,
            operation.command,
            operation.arguments,
            remaining
          )
        after
          SecretFile.cleanup(cleanup_target)
        end
      end)

    operation = %{operation | task: task}

    %{
      state
      | operations: Map.put(state.operations, operation.id, operation),
        task_refs: Map.put(state.task_refs, task.ref, operation.id)
    }
  end

  defp finish_operation(state, id, result) do
    case Map.fetch(state.operations, id) do
      {:ok, operation} ->
        state = remove_operation(state, operation)
        {reply_value, state} = normalize_result(state, operation, result)
        reply(operation, reply_value)

        state
        |> start_next_mutation()
        |> maybe_refresh_after(operation, reply_value)
        |> evaluate_waiters()
        |> schedule_waiter_retry()

      :error ->
        state
    end
  end

  defp normalize_result(state, operation, {:ok, raw}) do
    state =
      if operation.requires_daemon? do
        state |> set_socket(:ready, nil) |> update_health()
      else
        state
      end

    case operation.kind do
      kind when kind in [:status, :poll_status] -> normalize_status_result(state, operation, raw)
      :preferences -> {Preferences.from_cli(raw), state}
      :profiles -> {Profile.list_from_cli(raw), state}
      :current_profile -> normalize_current_profile(raw, state)
      kind when kind in [:login, :set, :switch_profile, :remove_profile] -> {:ok, state}
      :version -> {{:ok, version_value(raw)}, state}
      _kind -> {{:ok, raw}, state}
    end
  end

  defp normalize_result(state, operation, {:error, %CommandError{} = error}) do
    error = classify_command_error(state, operation, error)
    state = maybe_record_lifecycle_error(state, error)
    {error, state}
  end

  defp normalize_result(state, _operation, result),
    do: {{:error, {:invalid_command_result, result}}, state}

  defp normalize_status_result(state, operation, raw) do
    case Status.from_cli(raw) do
      {:ok, status} ->
        state = put_status(state, status)
        reply = if operation.kind == :poll_status, do: :ok, else: {:ok, state.status}
        {reply, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp normalize_current_profile(raw, state) do
    with {:ok, profiles} <- Profile.list_from_cli(raw),
         {:ok, profile} <- Profile.current(profiles) do
      {{:ok, profile}, state}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp classify_command_error(state, operation, error) do
    cond do
      operation.requires_daemon? and
          state.daemon_health.state in [:starting, :restarting, :stopped] ->
        {:error, :daemon_restarting}

      operation.requires_daemon? and socket_error?(state, error) ->
        {:error, :socket_unavailable}

      true ->
        {:error, error}
    end
  end

  defp socket_error?(state, error) do
    not File.exists?(state.config.socket_path) or
      String.contains?(String.downcase(error.output), [
        "failed to connect to local tailscaled",
        "connect: no such file",
        "connection refused"
      ])
  end

  defp maybe_record_lifecycle_error(state, {:error, reason})
       when reason in [:socket_unavailable, :daemon_restarting] do
    socket = if reason == :socket_unavailable, do: :unavailable, else: :unknown
    state |> set_socket(socket, reason) |> update_health()
  end

  defp maybe_record_lifecycle_error(state, _error), do: state

  defp operation_error(state, specification) do
    if Map.get(specification, :requires_daemon?, true) do
      daemon_operation_error(state)
    else
      :ok
    end
  end

  defp daemon_operation_error(%{daemon_health: %{state: state}})
       when state in [:starting, :restarting, :stopped],
       do: {:error, :daemon_restarting}

  defp daemon_operation_error(state) do
    if File.exists?(state.config.socket_path), do: :ok, else: {:error, :socket_unavailable}
  end

  defp remove_operation(state, operation) do
    cancel_timer(operation.deadline_timer)
    demonitor(operation.caller_monitor)
    cleanup(operation)

    task_refs =
      if operation.task,
        do: Map.delete(state.task_refs, operation.task.ref),
        else: state.task_refs

    caller_monitors =
      if operation.caller_monitor,
        do: Map.delete(state.caller_monitors, operation.caller_monitor),
        else: state.caller_monitors

    state = %{
      state
      | operations: Map.delete(state.operations, operation.id),
        task_refs: task_refs,
        caller_monitors: caller_monitors,
        active_mutation: clear_if(state.active_mutation, operation.id),
        poll_operation: clear_if(state.poll_operation, operation.id)
    }

    %{state | mutation_queue: Scheduler.delete(state.mutation_queue, operation.id)}
  end

  defp timeout_operation(state, id) do
    case Map.fetch(state.operations, id) do
      {:ok, operation} ->
        terminate_task(state.task_supervisor, operation)

        error =
          {:error,
           %CommandError{
             command: operation.command,
             exit_code: nil,
             output: "",
             reason: :timeout
           }}

        finish_operation(state, id, error)

      :error ->
        state
    end
  end

  defp cancel_by_id(state, id, reply_value) do
    cond do
      Map.has_key?(state.operations, id) -> cancel_operation(state, id, reply_value)
      Map.has_key?(state.waiters, id) -> cancel_waiter(state, id, reply_value)
      true -> state
    end
  end

  defp cancel_operation(state, id, reply_value) do
    state
    |> cancel_operation_without_dispatch(id, reply_value)
    |> start_next_mutation()
  end

  defp cancel_daemon_operations(state, reply_value) do
    ids = Scheduler.daemon_operation_ids(state.operations)

    state = Enum.reduce(ids, state, &cancel_operation_without_dispatch(&2, &1, reply_value))
    start_next_mutation(state)
  end

  defp cancel_operation_without_dispatch(state, id, reply_value) do
    operation = Map.fetch!(state.operations, id)
    terminate_task(state.task_supervisor, operation)
    state = remove_operation(state, operation)
    if reply_value, do: reply(operation, reply_value)
    state
  end

  defp start_next_mutation(%State{active_mutation: nil} = state) do
    case Scheduler.next(state.mutation_queue, state.operations) do
      {:ok, id, queue} ->
        state = %{state | mutation_queue: queue, active_mutation: id}
        start_task(state, Map.fetch!(state.operations, id))

      :empty ->
        state
    end
  end

  defp start_next_mutation(state), do: state

  defp terminate_task(_task_supervisor, %Operation{task: nil}), do: :ok

  defp terminate_task(task_supervisor, %Operation{task: task}) do
    Task.Supervisor.terminate_child(task_supervisor, task.pid)
    :ok
  end

  defp reply(%Operation{from: nil}, _reply), do: :ok
  defp reply(operation, reply), do: GenServer.reply(operation.from, reply)

  defp cleanup(%Operation{cleanup: nil}), do: :ok
  defp cleanup(%Operation{cleanup: target}), do: SecretFile.cleanup(target)

  defp task_exit_error(state, id, reason) do
    command = state.operations |> Map.fetch!(id) |> Map.fetch!(:command)
    output = if reason in [:normal, :shutdown, :killed], do: "", else: "command task failed"

    {:error, %CommandError{command: command, exit_code: nil, output: output, reason: :task_exit}}
  end

  defp maybe_refresh_after(state, %Operation{mode: :mutation}, :ok), do: maybe_start_poll(state)
  defp maybe_refresh_after(state, _operation, _reply), do: state

  defp maybe_start_poll(%State{poll_operation: nil} = state) do
    if state.daemon_health.state in [:running, :external] do
      operation = build_internal_poll(state)

      state
      |> register_internal_operation(operation)
      |> Map.put(:poll_operation, operation.id)
      |> start_task(operation)
    else
      state
    end
  end

  defp maybe_start_poll(state), do: state

  defp schedule_waiter_retry(state) do
    if map_size(state.waiters) > 0 and is_nil(state.poll_operation) do
      schedule_poll(state, min(state.config.status_interval, 100))
    else
      state
    end
  end

  defp schedule_poll(state, delay) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    %{state | poll_timer: Process.send_after(self(), :status_poll, delay)}
  end

  defp invalidate_status(state) do
    unknown = Status.unknown()

    if Status.semantically_equal?(state.status, unknown) do
      set_socket(state, :unknown, :daemon_restarting)
    else
      subscriptions = Subscriptions.publish(state.subscriptions, :status_changed, unknown)
      emit_status_transition(state, unknown)

      %{state | status: unknown, subscriptions: subscriptions}
      |> set_socket(:unknown, :daemon_restarting)
    end
  end

  defp put_status(state, new_status) do
    if Status.semantically_equal?(state.status, new_status) do
      state |> set_socket(:ready, nil) |> update_health()
    else
      status = Status.with_transition_time(new_status, DateTime.utc_now())
      subscriptions = Subscriptions.publish(state.subscriptions, :status_changed, status)

      emit_status_transition(state, status)

      %{state | status: status, subscriptions: subscriptions}
      |> set_socket(:ready, nil)
      |> update_health()
    end
  end

  defp emit_status_transition(state, status) do
    backend_state =
      case status.backend_state do
        {:unknown, _raw} -> :unknown
        known -> known
      end

    Telemetry.execute(
      [:status, :transition],
      %{system_time: System.system_time()},
      %{instance: state.config.name, backend_state: backend_state}
    )
  end

  defp set_socket(state, socket, error) do
    %{state | socket_state: socket, last_error: error}
  end

  defp update_health(state) do
    candidate = %Health{
      client: :running,
      daemon: state.daemon_health.state,
      socket: state.socket_state,
      authenticated: state.status.authenticated,
      online: state.status.online,
      restart_attempt: state.daemon_health.restart_attempt,
      last_daemon_exit: state.daemon_health.last_exit,
      last_error: state.last_error,
      transitioned_at: state.health.transitioned_at
    }

    if Health.semantically_equal?(state.health, candidate) do
      %{state | health: candidate}
    else
      health = Health.with_transition_time(candidate, DateTime.utc_now())
      subscriptions = Subscriptions.publish(state.subscriptions, :health_changed, health)

      Telemetry.execute(
        [:health, :transition],
        %{system_time: System.system_time()},
        %{instance: state.config.name, daemon: health.daemon, socket: health.socket}
      )

      %{state | health: health, subscriptions: subscriptions}
    end
  end

  defp build_waiter(id, type, requirements, timeout, from) do
    caller = elem(from, 0)
    monitor = Process.monitor(caller)

    %{
      id: id,
      type: type,
      requirements: requirements,
      from: from,
      caller: caller,
      monitor: monitor,
      timer: Process.send_after(self(), {:waiter_timeout, id}, timeout)
    }
  end

  defp put_waiter(state, waiter) do
    monitors = Map.put(state.caller_monitors, waiter.monitor, {:waiter, waiter.id})
    %{state | waiters: Map.put(state.waiters, waiter.id, waiter), caller_monitors: monitors}
  end

  defp evaluate_waiters(state) do
    ready_ids =
      state.waiters
      |> Enum.filter(fn {_id, waiter} ->
        waiter_satisfied?(waiter.type, waiter.requirements, state)
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(ready_ids, state, &complete_waiter(&2, &1, :ok))
  end

  defp waiter_satisfied?(:ready, _requirements, state), do: state.health.socket == :ready

  defp waiter_satisfied?(:online, requirements, state) do
    state.status.backend_state == :running and state.status.online == true and
      Enum.all?(requirements, &requirement_met?(&1, state.status))
  end

  defp requirement_met?(:authenticated, status), do: status.authenticated == true
  defp requirement_met?(:tailscale_ipv4, status), do: is_binary(status.ipv4)
  defp requirement_met?(:tailscale_ipv6, status), do: is_binary(status.ipv6)

  defp timeout_waiter(state, id) do
    case Map.fetch(state.waiters, id) do
      {:ok, waiter} ->
        reason =
          if waiter.type == :ready,
            do: {:readiness_timeout, state.health},
            else: {:online_timeout, state.status}

        complete_waiter(state, id, {:error, reason})

      :error ->
        state
    end
  end

  defp cancel_waiter(state, id, reply_value) do
    case Map.fetch(state.waiters, id) do
      {:ok, waiter} ->
        state = remove_waiter(state, waiter)
        if reply_value, do: GenServer.reply(waiter.from, reply_value)
        state

      :error ->
        state
    end
  end

  defp complete_waiter(state, id, reply) do
    waiter = Map.fetch!(state.waiters, id)
    state = remove_waiter(state, waiter)
    GenServer.reply(waiter.from, reply)
    state
  end

  defp remove_waiter(state, waiter) do
    cancel_timer(waiter.timer)
    demonitor(waiter.monitor)

    %{
      state
      | waiters: Map.delete(state.waiters, waiter.id),
        caller_monitors: Map.delete(state.caller_monitors, waiter.monitor)
    }
  end

  defp handle_monitor_down(state, monitor, pid) do
    {subscription?, subscriptions} =
      Subscriptions.remove_monitor(state.subscriptions, monitor, pid)

    if subscription? do
      {:noreply, %{state | subscriptions: subscriptions}}
    else
      case Map.get(state.caller_monitors, monitor) do
        {:operation, id} -> {:noreply, cancel_operation(state, id, nil)}
        {:waiter, id} -> {:noreply, cancel_waiter(state, id, nil)}
        nil -> {:noreply, state}
      end
    end
  end

  defp version_value(%{"majorMinorPatch" => version}), do: version
  defp version_value(version) when is_binary(version), do: version
  defp version_value(_value), do: "unknown"

  defp clear_if(value, value), do: nil
  defp clear_if(value, _other), do: value

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp demonitor(nil), do: :ok
  defp demonitor(monitor), do: Process.demonitor(monitor, [:flush])
end
