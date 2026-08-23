defmodule Tailscale.Naming do
  @moduledoc false

  @spec via(atom(), atom()) :: {:via, Registry, {module(), term()}}
  def via(instance, role) do
    {:via, Registry, {Tailscale.Registry, {instance, role}}}
  end

  @spec instance_id(atom()) :: String.t()
  def instance_id(instance) do
    instance
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
