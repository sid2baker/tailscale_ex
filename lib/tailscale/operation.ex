defmodule Tailscale.Operation do
  @moduledoc false

  @enforce_keys [:id, :mode, :kind, :command, :arguments, :timeout]
  defstruct [
    :id,
    :mode,
    :kind,
    :command,
    :arguments,
    :timeout,
    :from,
    :caller,
    :caller_monitor,
    :deadline_timer,
    :task,
    :cleanup,
    :deadline,
    requires_daemon?: true,
    internal?: false
  ]
end
