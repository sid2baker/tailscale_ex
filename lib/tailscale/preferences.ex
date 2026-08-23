defmodule Tailscale.Preferences do
  @moduledoc """
  Typed Tailscale preferences exposed by `Tailscale.preferences/1`.
  """

  alias Tailscale.SubnetRouter

  @allowed [:hostname, :accept_dns, :ssh, :advertise_routes]

  @type truth :: boolean() | :unknown
  @type change ::
          {:hostname, String.t()}
          | {:accept_dns, boolean()}
          | {:ssh, boolean()}
          | {:advertise_routes, [String.t()]}

  @type t :: %__MODULE__{
          hostname: String.t() | nil,
          accept_dns: truth(),
          ssh: truth(),
          advertised_routes: [String.t()]
        }

  defstruct hostname: nil,
            accept_dns: :unknown,
            ssh: :unknown,
            advertised_routes: []

  @doc false
  @spec encode_changes(term()) :: {:ok, [String.t()]} | {:error, term()}
  def encode_changes([]), do: {:error, :preferences_required}

  def encode_changes(changes) when is_list(changes) do
    with :ok <- validate_changes(changes) do
      encode_preferences(changes)
    end
  end

  def encode_changes(_changes), do: {:error, :invalid_preferences}

  @doc false
  @spec from_cli(term()) :: {:ok, t()} | {:error, term()}
  def from_cli(raw) when is_map(raw) do
    with {:ok, routes} <- normalize_readback_routes(Map.get(raw, "AdvertiseRoutes")) do
      {:ok,
       %__MODULE__{
         hostname: optional_string(Map.get(raw, "Hostname")),
         accept_dns: truth(Map.get(raw, "CorpDNS")),
         ssh: truth(Map.get(raw, "RunSSH")),
         advertised_routes: routes
       }}
    end
  end

  def from_cli(response), do: {:error, {:invalid_preferences_response, response}}

  defp validate_changes(changes) do
    cond do
      not Keyword.keyword?(changes) ->
        {:error, :invalid_preferences}

      duplicate_keys?(changes) ->
        {:error, :duplicate_preferences}

      Keyword.keys(changes) -- @allowed != [] ->
        {:error, {:unsupported_preferences, Keyword.keys(changes) -- @allowed}}

      true ->
        :ok
    end
  end

  defp duplicate_keys?(changes) do
    keys = Keyword.keys(changes)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp encode_preferences(changes) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, arguments} ->
      case encode_preference(change) do
        {:ok, argument} -> {:cont, {:ok, arguments ++ [argument]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp encode_preference({:advertise_routes, routes}) do
    case SubnetRouter.normalize_routes(routes) do
      {:ok, normalized} -> {:ok, "--advertise-routes=#{Enum.join(normalized, ",")}"}
      {:error, _reason} = error -> error
    end
  end

  defp encode_preference({:hostname, hostname}) when is_binary(hostname) and hostname != "" do
    {:ok, "--hostname=#{hostname}"}
  end

  defp encode_preference({key, value}) when key in [:accept_dns, :ssh] and is_boolean(value) do
    flag = key |> Atom.to_string() |> String.replace("_", "-")
    {:ok, if(value, do: "--#{flag}", else: "--#{flag}=false")}
  end

  defp encode_preference({key, _value}), do: {:error, {:invalid_preference, key}}

  defp normalize_readback_routes(nil), do: {:ok, []}

  defp normalize_readback_routes(routes) do
    case SubnetRouter.normalize_routes(routes) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_preferences_routes, reason}}
    end
  end

  defp truth(value) when is_boolean(value), do: value
  defp truth(_value), do: :unknown

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil
end
