defmodule TailscaleIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @default_socket_path "/var/run/tailscale/tailscaled.sock"

  setup do
    cli_path =
      System.get_env("TAILSCALE_CLI_PATH") ||
        System.find_executable("tailscale") ||
        flunk("tailscale executable not found")

    socket_path = System.get_env("TAILSCALE_SOCKET", @default_socket_path)

    unless File.exists?(socket_path) do
      flunk("tailscaled socket not found at #{socket_path}")
    end

    opts = [
      name: __MODULE__,
      cli_path: cli_path,
      start_daemon: false,
      socket_path: socket_path,
      timeout: 15_000
    ]

    assert {:ok, server} = Tailscale.start_link(opts)

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    %{server: server}
  end

  test "uses the installed client to communicate with the connected daemon", %{server: server} do
    assert :ok = Tailscale.await_ready(server, timeout: 10_000)
    assert {:ok, version} = Tailscale.version(server)
    assert version =~ ~r/^\d+\.\d+\.\d+$/

    assert {:ok, status} = Tailscale.status(server)
    assert status["BackendState"] == "Running"
    assert status["Self"]["Online"] == true
    assert status["TailscaleIPs"] != []
    assert Tailscale.online?(server)

    assert {:ok, %Tailscale.Preferences{advertised_routes: advertised_routes}} =
             Tailscale.preferences(server)

    assert {:ok,
            %{
              advertised: ^advertised_routes,
              approved: approved_routes,
              primary: primary_routes
            }} = Tailscale.route_status(server)

    assert is_list(approved_routes)
    assert is_list(primary_routes)

    assert {:ok, ipv4} = Tailscale.cli(server, "ip", ["--4"])
    assert {:ok, _address} = ipv4 |> String.to_charlist() |> :inet.parse_address()
  end
end
