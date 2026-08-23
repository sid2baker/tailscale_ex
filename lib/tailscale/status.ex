defmodule Tailscale.Status do
  @moduledoc """
  Nil-safe, normalized Tailscale node status.
  """

  alias Tailscale.Peer
  alias Tailscale.SubnetRouter

  @type truth :: boolean() | :unknown
  @type backend_state ::
          :no_state
          | :starting
          | :needs_login
          | :needs_machine_auth
          | :stopped
          | :running
          | :unknown
          | {:unknown, String.t()}

  @type t :: %__MODULE__{
          backend_state: backend_state(),
          authenticated: truth(),
          online: truth(),
          ipv4: String.t() | nil,
          ipv6: String.t() | nil,
          hostname: String.t() | nil,
          peers: [Peer.t()],
          allowed_ips: [String.t()],
          primary_routes: [String.t()],
          transitioned_at: DateTime.t()
        }

  defstruct backend_state: :unknown,
            authenticated: :unknown,
            online: :unknown,
            ipv4: nil,
            ipv6: nil,
            hostname: nil,
            peers: [],
            allowed_ips: [],
            primary_routes: [],
            transitioned_at: nil

  @doc false
  @spec unknown() :: t()
  def unknown do
    %__MODULE__{transitioned_at: DateTime.utc_now()}
  end

  @doc false
  @spec from_cli(term()) :: {:ok, t()} | {:error, term()}
  def from_cli(raw) when is_map(raw) do
    self = map_or_empty(Map.get(raw, "Self"))
    addresses = Map.get(raw, "TailscaleIPs") || Map.get(self, "TailscaleIPs")
    {ipv4, ipv6} = addresses(addresses)

    {:ok,
     %__MODULE__{
       backend_state: backend_state(Map.get(raw, "BackendState")),
       authenticated: authenticated(raw),
       online: truth(Map.get(self, "Online")),
       ipv4: ipv4,
       ipv6: ipv6,
       hostname: optional_string(Map.get(self, "HostName")),
       peers: peers(Map.get(raw, "Peer")),
       allowed_ips: routes(Map.get(self, "AllowedIPs")),
       primary_routes: routes(Map.get(self, "PrimaryRoutes")),
       transitioned_at: DateTime.utc_now()
     }}
  end

  def from_cli(raw), do: {:error, {:invalid_status_response, raw}}

  @doc false
  @spec semantically_equal?(t(), t()) :: boolean()
  defdelegate semantically_equal?(left, right), to: Tailscale.Transition

  @doc false
  @spec with_transition_time(t(), DateTime.t()) :: t()
  def with_transition_time(status, timestamp), do: Tailscale.Transition.at(status, timestamp)

  defp backend_state("NoState"), do: :no_state
  defp backend_state("Starting"), do: :starting
  defp backend_state("NeedsLogin"), do: :needs_login
  defp backend_state("NeedsMachineAuth"), do: :needs_machine_auth
  defp backend_state("Stopped"), do: :stopped
  defp backend_state("Running"), do: :running
  defp backend_state(nil), do: :unknown
  defp backend_state(value) when is_binary(value), do: {:unknown, value}
  defp backend_state(_value), do: :unknown

  defp authenticated(%{"HaveNodeKey" => value}) when is_boolean(value), do: value
  defp authenticated(%{"BackendState" => "NeedsLogin"}), do: false
  defp authenticated(_raw), do: :unknown

  defp truth(value) when is_boolean(value), do: value
  defp truth(_value), do: :unknown

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil

  defp addresses(addresses) when is_list(addresses) do
    Enum.reduce(addresses, {nil, nil}, fn address, {ipv4, ipv6} ->
      case address_family(address) do
        :ipv4 -> {ipv4 || address, ipv6}
        :ipv6 -> {ipv4, ipv6 || address}
        :error -> {ipv4, ipv6}
      end
    end)
  end

  defp addresses(_addresses), do: {nil, nil}

  defp address_family(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} when tuple_size(parsed) == 4 -> :ipv4
      {:ok, parsed} when tuple_size(parsed) == 8 -> :ipv6
      _other -> :error
    end
  end

  defp address_family(_address), do: :error

  defp peers(peers) when is_map(peers), do: peers |> Map.values() |> normalize_peers()
  defp peers(peers) when is_list(peers), do: normalize_peers(peers)
  defp peers(_peers), do: []

  defp normalize_peers(peers) do
    peers
    |> Enum.map(&Peer.from_cli/1)
    |> Enum.sort_by(&{&1.id || "", &1.hostname || ""})
  end

  defp routes(routes) when is_list(routes) do
    case SubnetRouter.normalize_routes(routes) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> []
    end
  end

  defp routes(_routes), do: []
end
