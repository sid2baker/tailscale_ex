defmodule Tailscale.RouteStatus do
  @moduledoc false

  alias Tailscale.Preferences
  alias Tailscale.Status
  alias Tailscale.SubnetRouter

  @type t :: %{
          required(:advertised) => [String.t()],
          required(:approved) => [String.t()],
          required(:primary) => [String.t()]
        }

  @spec project(Preferences.t(), Status.t()) :: {:ok, t()}
  def project(%Preferences{} = preferences, %Status{} = status) do
    own_routes = own_routes(status)

    {:ok,
     %{
       advertised: preferences.advertised_routes,
       approved: status.allowed_ips -- own_routes,
       primary: status.primary_routes
     }}
  end

  defp own_routes(status) do
    [{status.ipv4, 32}, {status.ipv6, 128}]
    |> Enum.reduce([], fn
      {nil, _prefix}, routes -> routes
      {address, prefix}, routes -> [normalize_host(address, prefix) | routes]
    end)
    |> Enum.reverse()
  end

  defp normalize_host(address, prefix) do
    {:ok, [route]} = SubnetRouter.normalize_routes(["#{address}/#{prefix}"])
    route
  end
end
