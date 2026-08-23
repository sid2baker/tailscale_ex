defmodule Tailscale.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Tailscale.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Tailscale.ApplicationSupervisor)
  end
end
