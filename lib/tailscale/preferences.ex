defmodule Tailscale.Preferences do
  @moduledoc """
  Typed Tailscale preferences exposed by `Tailscale.preferences/1`.
  """

  alias Tailscale.SubnetRouter

  @type t :: %__MODULE__{advertised_routes: [String.t()]}

  @enforce_keys [:advertised_routes]
  defstruct [:advertised_routes]

  @doc false
  @spec encode_changes(term()) :: {:ok, [String.t()]} | {:error, term()}
  def encode_changes([]), do: {:error, :preferences_required}

  def encode_changes(changes) when is_list(changes) do
    if Keyword.keyword?(changes) do
      encode_keyword(changes)
    else
      {:error, {:invalid_preferences, changes}}
    end
  end

  def encode_changes(changes), do: {:error, {:invalid_preferences, changes}}

  @doc false
  @spec from_cli(term()) :: {:ok, t()} | {:error, term()}
  def from_cli(%{"AdvertiseRoutes" => routes}) do
    build(routes)
  end

  def from_cli(response), do: {:error, {:invalid_preferences_response, response}}

  defp encode_keyword(changes) do
    case reject_duplicate_keys(changes) do
      :ok -> encode_preferences(changes)
      {:error, _reason} = error -> error
    end
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
      {:ok, normalized_routes} ->
        {:ok, "--advertise-routes=#{Enum.join(normalized_routes, ",")}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_preference({preference, _value}) do
    {:error, {:unsupported_preference, preference}}
  end

  defp reject_duplicate_keys(changes) do
    keys = Keyword.keys(changes)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      {:error, :duplicate_preferences}
    end
  end

  defp build(nil), do: {:ok, %__MODULE__{advertised_routes: []}}

  defp build(routes) do
    case SubnetRouter.normalize_routes(routes) do
      {:ok, normalized_routes} ->
        {:ok, %__MODULE__{advertised_routes: normalized_routes}}

      {:error, _reason} ->
        {:error, {:invalid_preferences_response, %{"AdvertiseRoutes" => routes}}}
    end
  end
end
