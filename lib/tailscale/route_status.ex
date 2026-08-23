defmodule Tailscale.RouteStatus do
  @moduledoc false

  alias Tailscale.Preferences
  alias Tailscale.SubnetRouter

  @type t :: %{
          required(:advertised) => [String.t()],
          required(:approved) => [String.t()],
          required(:primary) => [String.t()]
        }

  @spec project(Preferences.t(), term()) :: {:ok, t()} | {:error, term()}
  def project(%Preferences{} = preferences, %{"Self" => self} = status) when is_map(self) do
    with {:ok, approved} <- status_routes(self, "AllowedIPs"),
         {:ok, primary} <- status_routes(self, "PrimaryRoutes"),
         {:ok, own_routes} <- own_routes(status, self) do
      {:ok,
       %{
         advertised: preferences.advertised_routes,
         approved: approved -- own_routes,
         primary: primary
       }}
    end
  end

  def project(%Preferences{}, status), do: {:error, {:invalid_status_response, status}}

  defp status_routes(status, key) do
    case Map.get(status, key) do
      nil -> {:ok, []}
      routes when is_list(routes) -> normalize_status_routes(routes, key)
      routes -> {:error, {:invalid_status_routes, key, routes}}
    end
  end

  defp normalize_status_routes(routes, key) do
    case SubnetRouter.normalize_routes(routes) do
      {:ok, normalized_routes} -> {:ok, normalized_routes}
      {:error, reason} -> {:error, {:invalid_status_routes, key, reason}}
    end
  end

  defp own_routes(status, self) do
    addresses = Map.get(status, "TailscaleIPs") || Map.get(self, "TailscaleIPs") || []
    collect_own_routes(addresses, [])
  end

  defp collect_own_routes([], prefixes), do: {:ok, Enum.reverse(prefixes)}

  defp collect_own_routes([address | addresses], prefixes) do
    with {:ok, prefix} <- host_prefix(address) do
      collect_own_routes(addresses, [prefix | prefixes])
    end
  end

  defp collect_own_routes(addresses, _prefixes) do
    {:error, {:invalid_tailscale_ips, addresses}}
  end

  defp host_prefix(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} when tuple_size(parsed) == 4 -> normalize_host_prefix(address, 32)
      {:ok, parsed} when tuple_size(parsed) == 8 -> normalize_host_prefix(address, 128)
      {:error, _reason} -> {:error, {:invalid_tailscale_ip, address}}
    end
  end

  defp host_prefix(address), do: {:error, {:invalid_tailscale_ip, address}}

  defp normalize_host_prefix(address, prefix_length) do
    case SubnetRouter.normalize_routes(["#{address}/#{prefix_length}"]) do
      {:ok, [prefix]} -> {:ok, prefix}
      {:error, _reason} -> {:error, {:invalid_tailscale_ip, address}}
    end
  end
end
