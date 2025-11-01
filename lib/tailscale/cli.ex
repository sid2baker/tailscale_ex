defmodule Tailscale.CLI do
  @moduledoc """
  Direct-mapped CLI functions for Tailscale commands.

  All functions execute the corresponding Tailscale CLI command and return
  the result. Most commands return `{:ok, output}` or `{:error, reason}`.

  ## Examples

      # Connect to Tailscale
      Tailscale.CLI.up(Tailscale, hostname: "mynode")

      # Check status with JSON
      {:ok, status} = Tailscale.CLI.status(Tailscale, json: true)

      # Disconnect
      Tailscale.CLI.down(Tailscale)

  """

  require Logger

  @type cli_result :: {:ok, String.t() | map() | list()} | {:error, term()}
  @type server :: GenServer.server()

  @default_timeout 5_000

  # Utility functions

  @doc false
  @spec get_cli_path(server()) :: Path.t()
  def get_cli_path(server) do
    GenServer.call(server, {:cli_path})
  end

  @doc false
  @spec get_socket_path(server()) :: Path.t()
  def get_socket_path(server) do
    GenServer.call(server, {:socket_path})
  end

  @doc false
  @spec exec_command(server(), [String.t()], keyword()) :: cli_result()
  def exec_command(server, args, opts \\ []) when is_list(args) do
    cli_path = get_cli_path(server)
    socket_path = get_socket_path(server)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Add --socket flag to all commands
    args_with_socket = ["--socket=#{socket_path}" | args]

    muontrap_opts = [
      stderr_to_stdout: true,
      timeout: timeout
    ]

    case MuonTrap.cmd(cli_path, args_with_socket, muontrap_opts) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, :timeout} ->
        {:error, {:timeout, String.trim(output)}}

      {output, exit_code} ->
        {:error, {exit_code, String.trim(output)}}
    end
  end

  @doc false
  @spec exec_command_json(server(), [String.t()]) :: cli_result()
  def exec_command_json(server, args) when is_list(args) do
    case exec_command(server, args ++ ["--json"]) do
      {:ok, output} ->
        case JSON.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} = err -> err
        end

      error ->
        error
    end
  end

  # CLI Commands

  @doc """
  Connect to Tailscale, logging in if needed.

  ## Options

    * `:hostname` - Hostname to use for this device
    * `:advertise_exit_node` - Offer to be an exit node for outbound internet traffic
    * `:advertise_routes` - Routes to advertise to other nodes (comma-separated CIDRs)
    * `:accept_routes` - Accept routes advertised by other nodes
    * `:exit_node` - Tailscale IP of the exit node
    * `:shields_up` - Block incoming connections
    * `:auth_key` - Auth key for unattended registration
    * `:timeout` - Command timeout in milliseconds (default: #{@default_timeout})

  ## Examples

      Tailscale.CLI.up(Tailscale, hostname: "mynode", accept_routes: true)
      Tailscale.CLI.up(Tailscale, hostname: "mynode", timeout: 60_000)

  """
  @spec up(server(), keyword()) :: cli_result()
  def up(server, opts) do
    {timeout, flag_opts} = extract_timeout(opts)
    args = ["up" | build_flags(flag_opts)]
    exec_command(server, args, timeout: timeout)
  end

  @doc """
  Disconnect from Tailscale.

  ## Examples

      Tailscale.CLI.down(Tailscale)

  """
  @spec down(server()) :: cli_result()
  def down(server) do
    exec_command(server, ["down"])
  end

  @doc """
  Change specified preferences.

  ## Options

    * `:hostname` - Set hostname
    * `:advertise_exit_node` - Advertise as exit node (boolean)
    * `:advertise_routes` - Routes to advertise
    * `:accept_routes` - Accept routes (boolean)
    * `:shields_up` - Enable shields up (boolean)

  ## Examples

      Tailscale.CLI.set(Tailscale, hostname: "newname")

  """
  @spec set(server(), keyword()) :: cli_result()
  def set(server, opts) do
    args = ["set" | build_flags(opts)]
    exec_command(server, args)
  end

  @doc """
  Log in to a Tailscale account.

  ## Options

    * `:auth_key` - Authentication key
    * `:hostname` - Hostname for this device

  ## Examples

      Tailscale.CLI.login(Tailscale, auth_key: "tskey-...")

  """
  @spec login(server(), keyword()) :: cli_result()
  def login(server, opts) do
    args = ["login" | build_flags(opts)]
    exec_command(server, args)
  end

  @doc """
  Disconnect from Tailscale and expire current node key.

  ## Examples

      Tailscale.CLI.logout(Tailscale)

  """
  @spec logout(server()) :: cli_result()
  def logout(server) do
    exec_command(server, ["logout"])
  end

  @doc """
  Switch to a different Tailscale account.

  ## Examples

      Tailscale.CLI.switch(Tailscale)

  """
  @spec switch(server()) :: cli_result()
  def switch(server) do
    exec_command(server, ["switch"])
  end

  @doc """
  Print an analysis of local network conditions.

  ## Examples

      Tailscale.CLI.netcheck(Tailscale)

  """
  @spec netcheck(server()) :: cli_result()
  def netcheck(server) do
    exec_command(server, ["netcheck"])
  end

  @doc """
  Show Tailscale IP addresses for the current device.

  Returns a list of IP addresses (both IPv4 and IPv6).

  ## Examples

      {:ok, ips} = Tailscale.CLI.ip(Tailscale)

  """
  @spec ip(server()) :: cli_result()
  def ip(server) do
    case exec_command(server, ["ip"]) do
      {:ok, output} ->
        ips = output |> String.split("\n", trim: true)
        {:ok, ips}

      error ->
        error
    end
  end

  @doc """
  Show state of tailscaled and its connections.

  Returns a map with status information when called with `json: true`,
  or raw string output otherwise.

  ## Options

    * `:json` - Return JSON format (boolean)
    * `:peers` - Show peer details (boolean)
    * `:self` - Show self details only (boolean)

  ## Examples

      {:ok, status} = Tailscale.CLI.status(Tailscale, json: true)
      {:ok, text} = Tailscale.CLI.status(Tailscale, json: false)
      {:ok, text} = Tailscale.CLI.status(Tailscale, peers: true)

  """
  @spec status(server(), keyword()) :: cli_result()
  def status(server, opts) do
    json? = Keyword.get(opts, :json)
    args = ["status" | build_flags(opts)]

    if json? do
      exec_command_json(server, args)
    else
      exec_command(server, args)
    end
  end

  @doc """
  Show Tailscale metrics.

  ## Examples

        Tailscale.CLI.metrics(Tailscale)

  """
  @spec metrics(server()) :: cli_result()
  def metrics(server) do
    exec_command(server, ["metrics"])
  end

  @doc """
  Ping a host at the Tailscale layer.

  ## Options

  Pass additional flags as keyword list (e.g., `timeout: 5`, `count: 10`)

  ## Examples

      Tailscale.CLI.ping(Tailscale, "100.64.0.1", [])
      Tailscale.CLI.ping(Tailscale, "100.64.0.1", timeout: 5)

  """
  @spec ping(server(), String.t(), keyword()) :: cli_result()
  def ping(server, host, opts) do
    args = ["ping", host | build_flags(opts)]
    exec_command(server, args)
  end

  @doc """
  Connect to a port on a host, connected to stdin/stdout.

  ## Examples

      Tailscale.CLI.nc(Tailscale, "hostname", 8080)

  """
  @spec nc(server(), String.t(), integer()) :: cli_result()
  def nc(server, host, port) do
    exec_command(server, ["nc", host, to_string(port)])
  end

  @doc """
  Print Tailscale version.

  ## Examples

      {:ok, version} = Tailscale.CLI.version(Tailscale)

  """
  @spec version(server()) :: cli_result()
  def version(server) do
    exec_command(server, ["version"])
  end

  @doc """
  Send or receive files.

  ## Subcommands

    * `[:get, target_dir]` - Receive files
    * `[:cp, file, target]` - Send a file

  ## Examples

      Tailscale.CLI.file(Tailscale, [:get, "/tmp"])
      Tailscale.CLI.file(Tailscale, [:cp, "file.txt", "hostname:"])

  """
  @spec file(server(), [String.t()]) :: cli_result()
  def file(server, args) when is_list(args) do
    exec_command(server, ["file" | args])
  end

  @doc """
  Print a shareable identifier to help diagnose issues.

  ## Examples

      Tailscale.CLI.bugreport(Tailscale)

  """
  @spec bugreport(server()) :: cli_result()
  def bugreport(server) do
    exec_command(server, ["bugreport"])
  end

  @doc """
  Get TLS certificates.

  ## Examples

      Tailscale.CLI.cert(Tailscale, "example.com")

  """
  @spec cert(server(), String.t()) :: cli_result()
  def cert(server, domain) do
    exec_command(server, ["cert", domain])
  end

  @doc """
  Show machines on your tailnet configured as exit nodes.

  ## Options

    * `:json` - Return JSON format (boolean)

  ## Examples

      Tailscale.CLI.exit_node(Tailscale, json: true)
      Tailscale.CLI.exit_node(Tailscale, [])

  """
  @spec exit_node(server(), keyword()) :: cli_result()
  def exit_node(server, opts) do
    json? = Keyword.get(opts, :json)

    if json? do
      exec_command_json(server, ["exit-node"])
    else
      exec_command(server, ["exit-node"])
    end
  end

  @doc """
  Show the machine and user associated with a Tailscale IP.

  ## Options

    * `:json` - Return JSON format (boolean)

  ## Examples

      Tailscale.CLI.whois(Tailscale, "100.64.0.1", json: true)
      Tailscale.CLI.whois(Tailscale, "100.64.0.1", [])

  """
  @spec whois(server(), String.t(), keyword()) :: cli_result()
  def whois(server, ip, opts) do
    json? = Keyword.get(opts, :json)

    if json? do
      exec_command_json(server, ["whois", ip])
    else
      exec_command(server, ["whois", ip])
    end
  end

  @doc """
  Serve content and local servers on your tailnet.

  ## Examples

      Tailscale.CLI.serve(Tailscale, ["443", "http://localhost:3000"])

  """
  @spec serve(server(), [String.t()]) :: cli_result()
  def serve(server, args) when is_list(args) do
    exec_command(server, ["serve" | args])
  end

  @doc """
  Serve content and local servers on the internet via Funnel.

  ## Examples

      Tailscale.CLI.funnel(Tailscale, ["443", "on"])

  """
  @spec funnel(server(), [String.t()]) :: cli_result()
  def funnel(server, args) when is_list(args) do
    exec_command(server, ["funnel" | args])
  end

  @doc """
  SSH to a Tailscale machine.

  ## Examples

      Tailscale.CLI.ssh(Tailscale, "hostname", [])
      Tailscale.CLI.ssh(Tailscale, "hostname", ["-L", "8080:localhost:80"])

  """
  @spec ssh(server(), String.t(), [String.t()]) :: cli_result()
  def ssh(server, target, args) do
    exec_command(server, ["ssh", target | args])
  end

  @doc """
  Manage tailnet lock.

  ## Examples

      Tailscale.CLI.lock(Tailscale, ["status"])

  """
  @spec lock(server(), [String.t()]) :: cli_result()
  def lock(server, args) when is_list(args) do
    exec_command(server, ["lock" | args])
  end

  @doc """
  Get open source license information.

  ## Examples

      Tailscale.CLI.licenses(Tailscale)

  """
  @spec licenses(server()) :: cli_result()
  def licenses(server) do
    exec_command(server, ["licenses"])
  end

  @doc """
  Update Tailscale to the latest/different version.

  ## Examples

      Tailscale.CLI.update(Tailscale, [])
      Tailscale.CLI.update(Tailscale, ["--version", "1.50.0"])

  """
  @spec update(server(), [String.t()]) :: cli_result()
  def update(server, args) do
    exec_command(server, ["update" | args])
  end

  @doc """
  Configure the host to enable more Tailscale features.

  ## Examples

      Tailscale.CLI.configure(Tailscale, ["route-all", "on"])

  """
  @spec configure(server(), [String.t()]) :: cli_result()
  def configure(server, args) when is_list(args) do
    exec_command(server, ["configure" | args])
  end

  @doc """
  Diagnose the MDM and system policy configuration.

  ## Examples

      Tailscale.CLI.syspolicy(Tailscale)

  """
  @spec syspolicy(server()) :: cli_result()
  def syspolicy(server) do
    exec_command(server, ["syspolicy"])
  end

  @doc """
  Diagnose the internal DNS forwarder.

  ## Examples

      Tailscale.CLI.dns(Tailscale)

  """
  @spec dns(server()) :: cli_result()
  def dns(server) do
    exec_command(server, ["dns"])
  end

  @doc """
  Share a directory with your tailnet.

  ## Examples

        Tailscale.CLI.drive(Tailscale, ["share", "myshare", "/path/to/dir"])

  """
  @spec drive(server(), [String.t()]) :: cli_result()
  def drive(server, args) when is_list(args) do
    exec_command(server, ["drive" | args])
  end

  @doc """
  Run a web server for controlling Tailscale.

  ## Options

    * `:listen` - Address to listen on (e.g., "localhost:8088")

  ## Examples

        Tailscale.CLI.web(Tailscale, listen: "localhost:8088")

  """
  @spec web(server(), keyword()) :: cli_result()
  def web(server, opts) do
    args = ["web" | build_flags(opts)]
    exec_command(server, args)
  end

  # Helper functions

  defp extract_timeout(opts) do
    {timeout, remaining_opts} = Keyword.pop(opts, :timeout, @default_timeout)
    {timeout, remaining_opts}
  end

  defp build_flags(opts) do
    Enum.flat_map(opts, fn
      # Skip internal flags like :json and :timeout that are handled separately
      {:json, _} ->
        []

      {:timeout, _} ->
        []

      {key, true} ->
        ["--#{key |> to_string() |> String.replace("_", "-")}"]

      {key, false} ->
        ["--#{key |> to_string() |> String.replace("_", "-")}=false"]

      {key, value} when is_binary(value) or is_integer(value) ->
        ["--#{key |> to_string() |> String.replace("_", "-")}=#{value}"]

      _ ->
        []
    end)
  end
end
