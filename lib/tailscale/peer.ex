defmodule Tailscale.Peer do
  @moduledoc """
  Normalized status for a Tailscale peer.
  """

  @type truth :: boolean() | :unknown
  @type t :: %__MODULE__{
          id: String.t() | nil,
          hostname: String.t() | nil,
          dns_name: String.t() | nil,
          online: truth(),
          ipv4: String.t() | nil,
          ipv6: String.t() | nil
        }

  defstruct id: nil,
            hostname: nil,
            dns_name: nil,
            online: :unknown,
            ipv4: nil,
            ipv6: nil

  @doc false
  @spec from_cli(term()) :: t()
  def from_cli(peer) when is_map(peer) do
    {ipv4, ipv6} = addresses(Map.get(peer, "TailscaleIPs"))

    %__MODULE__{
      id: optional_string(Map.get(peer, "ID")),
      hostname: optional_string(Map.get(peer, "HostName")),
      dns_name: optional_string(Map.get(peer, "DNSName")),
      online: truth(Map.get(peer, "Online")),
      ipv4: ipv4,
      ipv6: ipv6
    }
  end

  def from_cli(_peer), do: %__MODULE__{}

  defp addresses(addresses) when is_list(addresses) do
    Enum.reduce(addresses, {nil, nil}, fn address, {ipv4, ipv6} ->
      case parse_address(address) do
        :ipv4 -> {ipv4 || address, ipv6}
        :ipv6 -> {ipv4, ipv6 || address}
        :error -> {ipv4, ipv6}
      end
    end)
  end

  defp addresses(_addresses), do: {nil, nil}

  defp parse_address(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} when tuple_size(parsed) == 4 -> :ipv4
      {:ok, parsed} when tuple_size(parsed) == 8 -> :ipv6
      _other -> :error
    end
  end

  defp parse_address(_address), do: :error

  defp truth(value) when is_boolean(value), do: value
  defp truth(_value), do: :unknown

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil
end
