defmodule Tailscale.Serve do
  @moduledoc false

  alias Tailscale.LocalAPI

  @owned ["TCP", "Web", "AllowFunnel"]

  def normalize(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case endpoint(entry) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        if length(Enum.uniq_by(entries, & &1.https)) == length(entries),
          do: {:ok, Enum.sort_by(entries, & &1.https)},
          else: {:error, :duplicate_serve_port}

      error ->
        error
    end
  end

  def normalize(_), do: {:error, :invalid_serve}

  defp endpoint(%{https: port, to: to} = entry)
       when map_size(entry) == 2 and is_integer(port) and port in 1..65_535 and is_binary(to) do
    case URI.new(to) do
      {:ok,
       %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil, port: target_port} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             target_port in 1..65_535 ->
        {:ok, %{https: port, to: URI.to_string(%{uri | host: String.downcase(host)})}}

      _ ->
        {:error, :invalid_serve_target}
    end
  end

  defp endpoint(_), do: {:error, :invalid_serve}

  def decode(nil), do: {:ok, []}

  def decode(raw) when is_map(raw) do
    with true <- (raw["Foreground"] || %{}) == %{},
         web when is_map(web) <- raw["Web"] || %{},
         {:ok, endpoints, names} <- decode_web(web),
         true <- Enum.all?(names, &(&1 == List.first(names))),
         {:ok, _} <- normalize(endpoints),
         {:ok, expected} <- build(%{}, endpoints, List.first(names)),
         true <- canonical(Map.take(raw, @owned)) == canonical(expected) do
      {:ok, Enum.sort_by(endpoints, & &1.https)}
    else
      _ -> {:error, :unsupported_serve_configuration}
    end
  end

  def decode(_), do: {:error, :unsupported_serve_configuration}

  defp decode_web(web) do
    Enum.reduce_while(web, {:ok, [], []}, fn {address, value}, {:ok, endpoints, names} ->
      with [name, port] when name != "" <- String.split(address, ":"),
           {port, ""} <- Integer.parse(port),
           %{"Handlers" => %{"/" => %{"Proxy" => target}}} <- value do
        {:cont, {:ok, [%{https: port, to: target} | endpoints], [name | names]}}
      else
        _ -> {:halt, {:error, :unsupported_serve_configuration}}
      end
    end)
  end

  def reconcile(opts, endpoints, dns_name) do
    with {:ok, current, headers} <- LocalAPI.request(opts, "GET", "serve-config"),
         {:ok, desired} <- build(current || %{}, endpoints, dns_name) do
      result =
        if canonical(current) == canonical(desired), do: :ok, else: update(opts, desired, headers)

      with :ok <- result, do: {:ok, endpoints}
    end
  end

  def build(current, endpoints, dns_name) do
    cond do
      map_size(current["Foreground"] || %{}) > 0 ->
        {:error, :serve_foreground_conflict}

      endpoints != [] and (not is_binary(dns_name) or dns_name == "") ->
        {:error, :awaiting_dns_name}

      true ->
        tcp = Map.new(endpoints, &{to_string(&1.https), %{"HTTPS" => true}})

        web =
          Map.new(
            endpoints,
            &{"#{dns_name}:#{&1.https}", %{"Handlers" => %{"/" => %{"Proxy" => &1.to}}}}
          )

        {:ok,
         current
         |> Map.drop(@owned)
         |> Map.merge(%{"TCP" => tcp, "Web" => web, "AllowFunnel" => %{}})}
    end
  end

  defp update(opts, desired, headers) do
    with {_, etag} <- List.keyfind(headers, "etag", 0),
         {:ok, _, _} <-
           LocalAPI.request(opts, "POST", "serve-config", desired, [{"if-match", etag}]),
         {:ok, actual, _} <- LocalAPI.request(opts, "GET", "serve-config") do
      if canonical(actual) == canonical(desired) do
        :ok
      else
        {:error, :serve_readback_mismatch}
      end
    else
      nil -> {:error, :missing_serve_etag}
      error -> error
    end
  end

  defp canonical(nil), do: %{}
  defp canonical(config), do: Map.reject(config, fn {_key, value} -> value in [nil, %{}] end)
end
