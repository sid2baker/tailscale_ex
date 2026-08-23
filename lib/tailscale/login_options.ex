defmodule Tailscale.LoginOptions do
  @moduledoc """
  Defines and validates the typed options accepted by `Tailscale.login/1`.
  """

  @allowed [:auth_key, :hostname, :nickname, :accept_dns]

  @type option ::
          {:auth_key, String.t()}
          | {:hostname, String.t()}
          | {:nickname, String.t()}
          | {:accept_dns, boolean()}

  @type encoded :: %{auth_key: String.t(), arguments: [String.t()]}

  @spec encode(term()) :: {:ok, encoded()} | {:error, term()}
  def encode(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         {:ok, auth_key} <- fetch_auth_key(opts),
         {:ok, arguments} <- encode_optional(opts) do
      {:ok, %{auth_key: auth_key, arguments: arguments}}
    end
  end

  def encode(_opts), do: {:error, :invalid_login_options}

  defp validate_keyword(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_login_options}

      duplicate_keys?(opts) ->
        {:error, :duplicate_login_options}

      Keyword.keys(opts) -- @allowed != [] ->
        {:error, {:unknown_login_options, Keyword.keys(opts) -- @allowed}}

      true ->
        :ok
    end
  end

  defp duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp fetch_auth_key(opts) do
    case Keyword.fetch(opts, :auth_key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_login_option, :auth_key}}
      :error -> {:error, {:missing_login_option, :auth_key}}
    end
  end

  defp encode_optional(opts) do
    opts
    |> Keyword.drop([:auth_key])
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, arguments} ->
      case encode_option(option) do
        {:ok, argument} -> {:cont, {:ok, arguments ++ [argument]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp encode_option({key, value}) when key in [:hostname, :nickname] do
    if is_binary(value) and value != "" do
      {:ok, "--#{hyphenate(key)}=#{value}"}
    else
      {:error, {:invalid_login_option, key}}
    end
  end

  defp encode_option({:accept_dns, value}) when is_boolean(value) do
    {:ok, boolean_argument("accept-dns", value)}
  end

  defp encode_option({key, _value}), do: {:error, {:invalid_login_option, key}}

  defp boolean_argument(flag, true), do: "--#{flag}"
  defp boolean_argument(flag, false), do: "--#{flag}=false"

  defp hyphenate(key), do: key |> Atom.to_string() |> String.replace("_", "-")
end
