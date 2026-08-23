defmodule TailscaleIntegrationTest do
  use ExUnit.Case, async: false

  alias Tailscale.Preferences
  alias Tailscale.Status

  @moduletag :integration
  @default_socket_path "/var/run/tailscale/tailscaled.sock"

  setup do
    cli_path =
      System.get_env("TAILSCALE_CLI_PATH") ||
        System.find_executable("tailscale") ||
        flunk("tailscale executable not found")

    socket_path = System.get_env("TAILSCALE_SOCKET", @default_socket_path)
    unless File.exists?(socket_path), do: flunk("tailscaled socket not found at #{socket_path}")

    runtime_dir = Path.join(System.tmp_dir!(), "tailscale_integration_runtime")

    opts = [
      name: __MODULE__,
      cli_path: cli_path,
      start_daemon: false,
      socket_path: socket_path,
      runtime_dir: runtime_dir,
      command_timeout: 15_000,
      status_interval: 1_000
    ]

    assert {:ok, supervisor} = Tailscale.start_link(opts)

    on_exit(fn ->
      try do
        if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      catch
        :exit, _reason -> :ok
      end

      File.rm_rf!(runtime_dir)
    end)

    %{server: __MODULE__}
  end

  test "normalizes state from a real connected daemon", %{server: server} do
    assert :ok = Tailscale.await_ready(server, timeout: 10_000)

    assert :ok =
             Tailscale.await_online(server,
               timeout: 10_000,
               require: [:authenticated, :tailscale_ipv4]
             )

    assert {:ok, version} = Tailscale.version(server)
    assert version =~ ~r/^\d+\.\d+\.\d+$/

    assert {:ok,
            %Status{
              backend_state: :running,
              authenticated: true,
              online: true,
              ipv4: ipv4
            }} = Tailscale.status(server)

    assert {:ok, _address} = ipv4 |> String.to_charlist() |> :inet.parse_address()

    assert {:ok, %Preferences{advertised_routes: advertised_routes}} =
             Tailscale.preferences(server)

    assert {:ok,
            %{
              advertised: ^advertised_routes,
              approved: approved_routes,
              primary: primary_routes
            }} = Tailscale.route_status(server)

    assert is_list(approved_routes)
    assert is_list(primary_routes)

    case Tailscale.profiles(server) do
      {:ok, profiles} ->
        assert Enum.all?(profiles, &match?(%Tailscale.Profile{}, &1))

      {:error, %Tailscale.CommandError{output: output}} ->
        assert output =~ "profiles access denied"
    end

    assert {:ok, cli_ipv4} = Tailscale.cli(server, "ip", ["--4"], mode: :read)
    assert {:ok, _address} = cli_ipv4 |> String.to_charlist() |> :inet.parse_address()
  end
end
