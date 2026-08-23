defmodule Tailscale.Transition do
  @moduledoc false

  @spec semantically_equal?(struct(), struct()) :: boolean()
  def semantically_equal?(left, right) do
    Map.put(left, :transitioned_at, nil) == Map.put(right, :transitioned_at, nil)
  end

  @spec at(struct(), DateTime.t()) :: struct()
  def at(value, timestamp), do: Map.put(value, :transitioned_at, timestamp)
end
