defmodule Tailscale.Configuration do
  @moduledoc false

  import Bitwise

  @defaults %{
    hostname: "",
    accept_dns: true,
    accept_routes: false,
    ssh: false,
    advertise_routes: [],
    serve: []
  }
  @fields %{
    hostname: "Hostname",
    accept_dns: "CorpDNS",
    accept_routes: "RouteAll",
    ssh: "RunSSH",
    advertise_routes: "AdvertiseRoutes"
  }

  def normalize(config) when is_map(config) do
    with true <- Enum.all?(Map.keys(config), &Map.has_key?(@defaults, &1)),
         {:ok, hostname} <- hostname(Map.get(config, :hostname, "")),
         {:ok, routes} <- routes(Map.get(config, :advertise_routes, [])),
         {:ok, serve} <- serve(Map.get(config, :serve, [])),
         true <-
           Enum.all?(
             [:accept_dns, :accept_routes, :ssh],
             &is_boolean(Map.get(config, &1, @defaults[&1]))
           ) do
      {:ok,
       Map.merge(@defaults, config)
       |> Map.merge(%{hostname: hostname, advertise_routes: routes, serve: serve})}
    else
      false -> {:error, :invalid_configuration}
      error -> error
    end
  end

  def normalize(_), do: {:error, :invalid_configuration}

  def observed(prefs, serve) do
    Map.new(@fields, fn {key, field} -> {key, Map.get(prefs, field, @defaults[key])} end)
    |> Map.update!(:advertise_routes, &Enum.sort(&1 || []))
    |> Map.put(:serve, serve)
  end

  def preferences(config), do: Map.new(@fields, fn {key, field} -> {field, config[key]} end)

  def patch(config, current) do
    config
    |> preferences()
    |> Enum.reject(fn {key, value} -> equivalent?(key, current[key], value) end)
    |> Enum.flat_map(fn {key, value} -> [{key, value}, {key <> "Set", true}] end)
    |> Map.new()
  end

  defp equivalent?("AdvertiseRoutes", old, new), do: Enum.sort(old || []) == new
  defp equivalent?(_key, old, new), do: old == new

  defp hostname(""), do: {:ok, ""}

  defp hostname(value) when is_binary(value) do
    value = String.downcase(value)

    if byte_size(value) <= 63 and Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, value),
      do: {:ok, value},
      else: {:error, :invalid_hostname}
  end

  defp hostname(_), do: {:error, :invalid_hostname}

  defp routes(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case route(value) do
        {:ok, route} -> {:cont, {:ok, [route | acc]}}
        _ -> {:halt, {:error, :invalid_route}}
      end
    end)
    |> case do
      {:ok, routes} -> {:ok, Enum.sort(Enum.uniq(routes))}
      error -> error
    end
  end

  defp routes(_), do: {:error, :invalid_route}

  defp route(value) when is_binary(value) do
    with [ip, prefix] <- String.split(value, "/"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(ip)),
         {prefix, ""} <- Integer.parse(prefix) do
      route({ip, prefix})
    else
      _ -> {:error, :invalid_route}
    end
  end

  defp route({ip, prefix})
       when is_tuple(ip) and tuple_size(ip) in [4, 8] and is_integer(prefix) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    bits = tuple_size(ip) * width

    if prefix in 0..bits and
         Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 < 1 <<< width)) do
      number = Enum.reduce(Tuple.to_list(ip), 0, &((&2 <<< width) + &1))
      network = (number >>> (bits - prefix)) <<< (bits - prefix)

      address =
        for offset <- (bits - width)..0//-width, do: band(network >>> offset, (1 <<< width) - 1)

      {:ok, to_string(:inet.ntoa(List.to_tuple(address))) <> "/#{prefix}"}
    else
      {:error, :invalid_route}
    end
  end

  defp route(_), do: {:error, :invalid_route}

  defp serve(entries) when is_list(entries) do
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

  defp serve(_), do: {:error, :invalid_serve}

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
end
