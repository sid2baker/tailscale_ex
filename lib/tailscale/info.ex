defmodule Tailscale.Info do
  @moduledoc false

  def print do
    if Process.whereis(Tailscale.Properties) do
      Tailscale.get_by_prefix([]) |> Map.new() |> format() |> IO.puts()
    else
      IO.puts("Tailscale is not started.")
    end
  end

  def format(properties) do
    peers = peers(properties)

    [
      "Tailscale",
      "  Status: #{value(properties[["state"]])}",
      "  Backend: #{value(properties[["backend_state"]])}",
      "  Authentication: #{value(properties[["auth", "state"]])}",
      "  Daemon: #{value(properties[["daemon", "state"]])}",
      "  Version: #{value(properties[["version"]])}",
      "  Observer: #{connection(properties[["monitor", "connected"]])}",
      "  Hostname: #{value(properties[["hostname"]])}",
      "  DNS name: #{value(properties[["dns_name"]])}",
      "  Addresses: #{addresses(properties[["ipv4"]], properties[["ipv6"]])}",
      error("Observer", properties[["monitor", "error"]]),
      error("Authentication", properties[["auth", "error"]]),
      health(properties[["health"]] || []),
      "",
      "Configuration (#{value(properties[["configuration", "state"]])})",
      configuration(properties[["configuration", "value"]]),
      error("Configuration", properties[["configuration", "error"]]),
      "",
      "Peers (#{length(peers)})",
      if(peers == [], do: "  None observed", else: Enum.map(peers, &peer/1))
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> redact(properties[["auth", "url"]])
  end

  defp peers(properties) do
    properties
    |> Enum.reduce(%{}, fn
      {["peers", id, field], value}, peers ->
        Map.update(peers, id, %{field => value}, &Map.put(&1, field, value))

      _, peers ->
        peers
    end)
    |> Enum.sort_by(fn {id, fields} -> {fields["hostname"] || fields["dns_name"] || id, id} end)
  end

  defp peer({id, fields}) do
    online =
      case fields["online"] do
        true -> "online"
        false -> "offline"
        nil -> "unknown"
      end

    [
      "  #{value(fields["hostname"] || fields["dns_name"] || id)} (#{online})",
      "    ID: #{value(id)}; DNS: #{value(fields["dns_name"])}",
      "    Addresses: #{addresses(fields["ipv4"], fields["ipv6"])}"
    ]
  end

  defp configuration(nil), do: "  Unavailable"

  defp configuration(config) do
    text = inspect(config, pretty: true, width: 78, limit: :infinity, printable_limit: :infinity)
    text = if Map.has_key?(config, :serve), do: text, else: text <> "\nServe: unavailable"
    text |> String.split("\n") |> Enum.map(&("  " <> &1))
  end

  defp health([]), do: nil
  defp health(warnings), do: ["  Health warnings:" | Enum.map(warnings, &("    " <> value(&1)))]
  defp error(_label, nil), do: nil
  defp error(label, reason), do: "  #{label} error: #{value(reason)}"
  defp connection(true), do: "connected"
  defp connection(_), do: "disconnected"

  defp addresses(ipv4, ipv6) do
    case Enum.reject([ipv4, ipv6], &is_nil/1) do
      [] -> "none"
      ips -> Enum.map_join(ips, ", ", &to_string(:inet.ntoa(&1)))
    end
  end

  defp value(nil), do: "unknown"
  defp value(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")
  defp value(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp redact(text, url) when is_binary(url) and url != "",
    do: String.replace(text, url, "[redacted]")

  defp redact(text, _url), do: text
end
