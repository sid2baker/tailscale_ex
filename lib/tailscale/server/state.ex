defmodule Tailscale.Server.State do
  @moduledoc false

  defstruct [
    :config,
    :task_supervisor,
    :daemon_manager,
    :daemon_health,
    :status,
    :health,
    :secret_context,
    :poll_timer,
    :poll_operation,
    socket_state: :unknown,
    last_error: nil,
    operations: %{},
    task_refs: %{},
    caller_monitors: %{},
    mutation_queue: :queue.new(),
    active_mutation: nil,
    waiters: %{},
    subscriptions: %Tailscale.Subscriptions{}
  ]
end
