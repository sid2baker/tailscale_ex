defmodule Tailscale.SubnetRouter do
  @moduledoc false

  @default_paths %{
    ipv4: "/proc/sys/net/ipv4/ip_forward",
    ipv6: "/proc/sys/net/ipv6/conf/all/forwarding",
    sysctl: "/etc/sysctl.d/99-tailscale.conf"
  }

  @type family :: :ipv4 | :ipv6
  @type paths :: %{
          required(:ipv4) => Path.t(),
          required(:ipv6) => Path.t(),
          required(:sysctl) => Path.t()
        }
  @type advertisement :: %{required(:argument) => String.t(), required(:families) => [family()]}

  @spec advertisement(term()) :: {:ok, advertisement()} | {:error, term()}
  def advertisement([]), do: {:error, :routes_required}

  def advertisement(routes) when is_list(routes) do
    with {:ok, parsed_routes} <- parse_routes(routes) do
      unique_routes = Enum.uniq_by(parsed_routes, &elem(&1, 0))

      {:ok,
       %{
         argument: "--advertise-routes=#{unique_routes |> Enum.map_join(",", &elem(&1, 0))}",
         families: unique_routes |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
       }}
    end
  end

  def advertisement(routes), do: {:error, {:invalid_routes, routes}}

  @doc false
  @spec ensure_supported() :: :ok | {:error, term()}
  def ensure_supported, do: ensure_linux()

  @spec forwarding_status() :: {:ok, %{ipv4: boolean(), ipv6: boolean()}} | {:error, term()}
  def forwarding_status do
    forwarding_status(@default_paths)
  end

  @doc false
  @spec forwarding_status(paths()) ::
          {:ok, %{ipv4: boolean(), ipv6: boolean()}} | {:error, term()}
  def forwarding_status(paths) do
    with :ok <- ensure_linux(),
         {:ok, ipv4?} <- read_forwarding(:ipv4, paths.ipv4),
         {:ok, ipv6?} <- read_forwarding(:ipv6, paths.ipv6) do
      {:ok, %{ipv4: ipv4?, ipv6: ipv6?}}
    end
  end

  @spec require_forwarding([family()]) :: :ok | {:error, term()}
  def require_forwarding(families) do
    require_forwarding(families, @default_paths)
  end

  @doc false
  @spec require_forwarding([family()], paths()) :: :ok | {:error, term()}
  def require_forwarding(families, paths) do
    with :ok <- ensure_linux(),
         {:ok, disabled} <- disabled_families(families, paths) do
      case disabled do
        [] -> :ok
        families -> {:error, {:forwarding_disabled, families}}
      end
    end
  end

  @spec enable_forwarding(keyword()) :: :ok | {:error, term()}
  def enable_forwarding(opts) do
    enable_forwarding(opts, @default_paths)
  end

  @doc false
  @spec enable_forwarding(keyword(), paths()) :: :ok | {:error, term()}
  def enable_forwarding(opts, paths) when is_list(opts) do
    with :ok <- ensure_linux(),
         {:ok, families} <- fetch_families(opts),
         {:ok, persist?} <- fetch_persistence(opts),
         :ok <- maybe_persist(families, persist?, paths.sysctl) do
      write_forwarding(families, paths)
    end
  end

  def enable_forwarding(opts, _paths), do: {:error, {:invalid_options, opts}}

  defp parse_routes(routes) do
    Enum.reduce_while(routes, {:ok, []}, fn route, {:ok, parsed} ->
      case parse_route(route) do
        {:ok, parsed_route} -> {:cont, {:ok, [parsed_route | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end)
  end

  defp parse_route(route) when is_binary(route) do
    normalized_route = String.trim(route)

    with [address, prefix] <- String.split(normalized_route, "/", parts: 2),
         {:ok, parsed_address} <- parse_address(address),
         family <- address_family(parsed_address),
         {prefix_length, ""} <- Integer.parse(prefix),
         true <- valid_prefix?(family, prefix_length) do
      {:ok, {normalized_route, family}}
    else
      _reason -> {:error, {:invalid_route, route}}
    end
  end

  defp parse_route(route), do: {:error, {:invalid_route, route}}

  defp parse_address(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed_address} -> {:ok, parsed_address}
      {:error, _reason} -> :error
    end
  end

  defp address_family(address) when tuple_size(address) == 4, do: :ipv4
  defp address_family(address) when tuple_size(address) == 8, do: :ipv6

  defp valid_prefix?(:ipv4, prefix), do: prefix in 0..32
  defp valid_prefix?(:ipv6, prefix), do: prefix in 0..128

  defp disabled_families(families, paths) do
    families
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn family, {:ok, disabled} ->
      case read_forwarding(family, Map.fetch!(paths, family)) do
        {:ok, true} -> {:cont, {:ok, disabled}}
        {:ok, false} -> {:cont, {:ok, [family | disabled]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, disabled} -> {:ok, Enum.reverse(disabled)}
      error -> error
    end)
  end

  defp read_forwarding(family, path) do
    case File.read(path) do
      {:ok, value} -> parse_forwarding_value(family, path, String.trim(value))
      {:error, reason} -> {:error, {:forwarding_status_unavailable, family, path, reason}}
    end
  end

  defp parse_forwarding_value(_family, _path, "1"), do: {:ok, true}
  defp parse_forwarding_value(_family, _path, "0"), do: {:ok, false}

  defp parse_forwarding_value(family, path, value) do
    {:error, {:invalid_forwarding_value, family, path, value}}
  end

  defp fetch_families(opts) do
    case Keyword.get(opts, :families, [:ipv4, :ipv6]) do
      families when is_list(families) and families != [] ->
        if Enum.all?(families, &(&1 in [:ipv4, :ipv6])) do
          {:ok, Enum.uniq(families)}
        else
          {:error, {:invalid_option, :families, families}}
        end

      families ->
        {:error, {:invalid_option, :families, families}}
    end
  end

  defp fetch_persistence(opts) do
    case Keyword.get(opts, :persist, false) do
      false -> {:ok, false}
      :sysctl_d -> {:ok, true}
      persist -> {:error, {:invalid_option, :persist, persist}}
    end
  end

  defp maybe_persist(_families, false, _path), do: :ok

  defp maybe_persist(families, true, path) do
    contents =
      families
      |> Enum.map_join("\n", fn
        :ipv4 -> "net.ipv4.ip_forward = 1"
        :ipv6 -> "net.ipv6.conf.all.forwarding = 1"
      end)
      |> Kernel.<>("\n")

    with :ok <- make_directory(Path.dirname(path)) do
      write_file(path, contents, :sysctl)
    end
  end

  defp write_forwarding(families, paths) do
    Enum.reduce_while(families, :ok, fn family, :ok ->
      case write_file(Map.fetch!(paths, family), "1\n", family) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_file(path, contents, target) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, {:forwarding_write_failed, target, path, reason}}
    end
  end

  defp make_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:forwarding_write_failed, :sysctl, path, reason}}
    end
  end

  defp ensure_linux do
    case :os.type() do
      {:unix, :linux} -> :ok
      os_type -> {:error, {:unsupported_os, os_type}}
    end
  end
end
