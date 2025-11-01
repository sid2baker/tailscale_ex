defmodule Tailscale.CLITest do
  use ExUnit.Case, async: false

  alias Tailscale.CLI

  setup do
    %{cli_path: cli_path, daemon_path: daemon_path, test_dir: mock_dir} =
      MockTailscale.create_mocks()

    state_dir =
      Path.join(System.tmp_dir!(), "tailscale_cli_state_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)

    opts = [
      name: :"test_cli_#{:erlang.unique_integer([:positive])}",
      daemon_path: daemon_path,
      cli_path: cli_path,
      tailscale_dir: state_dir
    ]

    {:ok, server} = Tailscale.start_link(opts)
    Process.sleep(100)

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      MockTailscale.cleanup_mocks(mock_dir)
      File.rm_rf!(state_dir)
    end)

    %{server: server}
  end

  test "version returns version string", %{server: server} do
    assert {:ok, version} = CLI.version(server)
    assert version =~ ~r/\d+\.\d+\.\d+/
  end

  test "status with JSON returns map", %{server: server} do
    assert {:ok, status} = CLI.status(server, json: true)
    assert is_map(status)
    assert Map.has_key?(status, "Self")
  end

  test "status without JSON returns string", %{server: server} do
    assert {:ok, status} = CLI.status(server, [])
    assert is_binary(status)
  end

  test "ip returns list of IPs", %{server: server} do
    assert {:ok, ips} = CLI.ip(server)
    assert is_list(ips)
    assert length(ips) >= 1
  end

  test "up command works", %{server: server} do
    assert {:ok, result} = CLI.up(server, hostname: "test")
    assert is_binary(result)
  end

  test "down command works", %{server: server} do
    assert {:ok, result} = CLI.down(server)
    assert is_binary(result)
  end

  test "set command works", %{server: server} do
    assert {:ok, result} = CLI.set(server, hostname: "new-name")
    assert is_binary(result)
  end

  test "login command works", %{server: server} do
    assert {:ok, result} = CLI.login(server, auth_key: "fake")
    assert is_binary(result)
  end

  test "logout command works", %{server: server} do
    assert {:ok, result} = CLI.logout(server)
    assert is_binary(result)
  end

  test "netcheck command works", %{server: server} do
    assert {:ok, result} = CLI.netcheck(server)
    assert is_binary(result)
  end

  test "metrics command works", %{server: server} do
    assert {:ok, result} = CLI.metrics(server)
    assert is_binary(result)
  end

  test "bugreport command works", %{server: server} do
    assert {:ok, result} = CLI.bugreport(server)
    assert is_binary(result)
  end

  test "licenses command works", %{server: server} do
    assert {:ok, result} = CLI.licenses(server)
    assert is_binary(result)
  end

  test "whois with JSON works", %{server: server} do
    assert {:ok, data} = CLI.whois(server, "100.64.0.1", json: true)
    assert is_map(data)
  end

  test "exit_node with JSON works", %{server: server} do
    assert {:ok, data} = CLI.exit_node(server, json: true)
    assert is_list(data) or is_map(data)
  end

  test "invalid command returns error", %{server: server} do
    assert {:error, {1, output}} = CLI.exec_command(server, ["invalid-xyz"])
    assert is_binary(output)
  end
end
