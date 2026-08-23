defmodule Tailscale.Health do
  @moduledoc """
  Combined health of the Elixir client, daemon, socket, and Tailscale node.
  """

  alias Tailscale.DaemonExit
  alias Tailscale.Status

  @type socket_state :: :ready | :unavailable | :unknown
  @type daemon_state :: :starting | :running | :restarting | :external | :stopped
  @type t :: %__MODULE__{
          client: :running,
          daemon: daemon_state(),
          socket: socket_state(),
          authenticated: Status.truth(),
          online: Status.truth(),
          restart_attempt: non_neg_integer(),
          last_daemon_exit: DaemonExit.t() | nil,
          last_error: term() | nil,
          transitioned_at: DateTime.t()
        }

  defstruct client: :running,
            daemon: :starting,
            socket: :unknown,
            authenticated: :unknown,
            online: :unknown,
            restart_attempt: 0,
            last_daemon_exit: nil,
            last_error: nil,
            transitioned_at: nil

  @doc false
  @spec initial() :: t()
  def initial do
    %__MODULE__{transitioned_at: DateTime.utc_now()}
  end

  @doc false
  @spec semantically_equal?(t(), t()) :: boolean()
  defdelegate semantically_equal?(left, right), to: Tailscale.Transition

  @doc false
  @spec with_transition_time(t(), DateTime.t()) :: t()
  def with_transition_time(health, timestamp), do: Tailscale.Transition.at(health, timestamp)
end
