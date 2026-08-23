defmodule Tailscale.DaemonHealth do
  @moduledoc false

  @type state :: :starting | :running | :restarting | :external | :stopped
  @type t :: %__MODULE__{
          state: state(),
          restart_attempt: non_neg_integer(),
          last_exit: Tailscale.DaemonExit.t() | nil,
          transitioned_at: DateTime.t()
        }

  defstruct state: :starting,
            restart_attempt: 0,
            last_exit: nil,
            transitioned_at: nil
end

defmodule Tailscale.DaemonExit do
  @moduledoc """
  Structured reason for an unexpected `tailscaled` exit.
  """

  @type t :: %__MODULE__{
          reason: term(),
          status: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [:reason, :occurred_at]
  defstruct [:reason, :status, :occurred_at]
end
