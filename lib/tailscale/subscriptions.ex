defmodule Tailscale.Subscriptions do
  @moduledoc false

  defstruct subscribers: %{}, generation: 0

  @type t :: %__MODULE__{
          subscribers: %{optional(pid()) => reference()},
          generation: non_neg_integer()
        }

  @spec add(t(), pid(), Tailscale.Status.t(), Tailscale.Health.t()) :: t()
  def add(state, subscriber, status, health) do
    state =
      if Map.has_key?(state.subscribers, subscriber) do
        state
      else
        monitor = Process.monitor(subscriber)
        %{state | subscribers: Map.put(state.subscribers, subscriber, monitor)}
      end

    send(subscriber, {:tailscale, :status_changed, state.generation, status})
    send(subscriber, {:tailscale, :health_changed, state.generation, health})
    state
  end

  @spec remove(t(), pid()) :: t()
  def remove(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _subscribers} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  @spec remove_monitor(t(), reference(), pid()) :: {boolean(), t()}
  def remove_monitor(state, monitor, subscriber) do
    case Map.get(state.subscribers, subscriber) do
      ^monitor -> {true, %{state | subscribers: Map.delete(state.subscribers, subscriber)}}
      _other -> {false, state}
    end
  end

  @spec publish(t(), :status_changed | :health_changed, struct()) :: t()
  def publish(state, event, value) do
    generation = state.generation + 1
    Enum.each(Map.keys(state.subscribers), &send(&1, {:tailscale, event, generation, value}))
    %{state | generation: generation}
  end
end
