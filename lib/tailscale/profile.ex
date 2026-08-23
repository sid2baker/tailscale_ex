defmodule Tailscale.Profile do
  @moduledoc """
  A locally stored Tailscale account profile.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          nickname: String.t() | nil,
          tailnet: String.t() | nil,
          account: String.t() | nil,
          selected?: boolean()
        }

  @enforce_keys [:id]
  defstruct id: nil,
            nickname: nil,
            tailnet: nil,
            account: nil,
            selected?: false

  @doc false
  @spec list_from_cli(term()) :: {:ok, [t()]} | {:error, term()}
  def list_from_cli(profiles) when is_list(profiles) do
    Enum.reduce_while(profiles, {:ok, []}, fn raw, {:ok, parsed} ->
      case from_cli(raw) do
        {:ok, profile} -> {:cont, {:ok, [profile | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end)
  end

  def list_from_cli(response), do: {:error, {:invalid_profiles_response, response}}

  @doc false
  @spec current([t()]) :: {:ok, t()} | {:error, term()}
  def current(profiles) do
    case Enum.filter(profiles, & &1.selected?) do
      [profile] -> {:ok, profile}
      [] -> {:error, :no_current_profile}
      _profiles -> {:error, :multiple_current_profiles}
    end
  end

  defp from_cli(%{"id" => id} = raw) when is_binary(id) and id != "" do
    {:ok,
     %__MODULE__{
       id: id,
       nickname: optional_string(Map.get(raw, "nickname")),
       tailnet: optional_string(Map.get(raw, "tailnet")),
       account: optional_string(Map.get(raw, "account")),
       selected?: Map.get(raw, "selected") == true
     }}
  end

  defp from_cli(raw), do: {:error, {:invalid_profile, raw}}

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil
end
