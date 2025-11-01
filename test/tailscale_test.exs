defmodule TailscaleTest do
  use ExUnit.Case, async: false
  doctest Tailscale

  setup do
    %{cli_path: cli_path, daemon_path: daemon_path, test_dir: mock_dir} =
      MockTailscale.create_mocks()

    state_dir =
      Path.join(System.tmp_dir!(), "tailscale_state_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)

    socket_path = Path.join(state_dir, "tailscaled.sock")

    opts = [
      name: :"test_tailscale_#{:erlang.unique_integer([:positive])}",
      daemon_path: daemon_path,
      cli_path: cli_path,
      tailscale_dir: state_dir,
      socket_path: socket_path
    ]

    on_exit(fn ->
      MockTailscale.cleanup_mocks(mock_dir)
      File.rm_rf!(state_dir)
    end)

    %{opts: opts, state_dir: state_dir}
  end

  describe "start_link/1" do
    test "starts with default options", %{opts: opts} do
      assert {:ok, pid} = Tailscale.start_link(opts)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom name", %{opts: opts} do
      opts = Keyword.put(opts, :name, :custom_tailscale)
      assert {:ok, pid} = Tailscale.start_link(opts)
      assert Process.whereis(:custom_tailscale) == pid
      GenServer.stop(pid)
    end

    test "returns validation error when daemon binary does not exist", %{opts: opts} do
      opts = Keyword.put(opts, :daemon_path, "/nonexistent/tailscaled")
      assert {:error, message} = Tailscale.start_link(opts)
      assert message =~ "not found"
    end

    test "returns validation error when cli binary does not exist", %{opts: opts} do
      opts = Keyword.put(opts, :cli_path, "/nonexistent/tailscale")
      assert {:error, message} = Tailscale.start_link(opts)
      assert message =~ "not found"
    end

    test "returns validation error when daemon path is not executable", %{opts: opts, state_dir: state_dir} do
      non_executable = Path.join(state_dir, "not_executable")
      File.write!(non_executable, "#!/bin/bash\necho test")
      File.chmod!(non_executable, 0o644)

      opts = Keyword.put(opts, :daemon_path, non_executable)
      assert {:error, message} = Tailscale.start_link(opts)
      assert message =~ "not executable"
    end
  end

  describe "child_spec/1" do
    test "returns valid child_spec", %{opts: opts} do
      spec = Tailscale.child_spec(opts)

      assert spec.id == Tailscale
      assert spec.start == {Tailscale, :start_link, [opts]}
      # Note: GenServer default child_spec doesn't include :type, :restart, :shutdown
      # These are handled by the supervisor
    end
  end

  describe "daemon_pid/1" do
    test "returns daemon PID when started", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      assert {:ok, daemon_pid} = Tailscale.daemon_pid(server_pid)
      assert is_pid(daemon_pid)
      assert Process.alive?(daemon_pid)

      GenServer.stop(server_pid)
    end
  end

  describe "version/1" do
    test "returns version string", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      assert {:ok, version} = Tailscale.version(server_pid)
      assert is_binary(version)

      GenServer.stop(server_pid)
    end
  end

  describe "online?/1" do
    test "returns true when online", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      result = Tailscale.online?(server_pid)
      assert is_boolean(result)
      assert result == true

      GenServer.stop(server_pid)
    end
  end

  describe "cli/3" do
    test "executes status command with JSON output", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      assert {:ok, result} = Tailscale.cli(server_pid, "status", ["--json"])
      assert is_map(result)
      assert result["Self"]["HostName"] == "mock-host"
      assert result["Self"]["Online"] == true

      GenServer.stop(server_pid)
    end

    test "executes ip command", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      assert {:ok, result} = Tailscale.cli(server_pid, "ip", [])
      assert is_binary(result)
      assert result =~ "100.64.0.1"

      GenServer.stop(server_pid)
    end

    test "executes version command", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      assert {:ok, result} = Tailscale.cli(server_pid, "version", [])
      assert is_binary(result)
      assert result =~ "1.88.3"

      GenServer.stop(server_pid)
    end

    test "returns error for unknown command", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      Process.sleep(100)

      assert {:error, {exit_code, output}} = Tailscale.cli(server_pid, "invalid", [])
      assert exit_code == 1
      assert output =~ "unknown command"

      GenServer.stop(server_pid)
    end
  end

  describe "supervision" do
    test "can be supervised", %{opts: opts} do
      children = [{Tailscale, opts}]

      assert {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      Process.sleep(100)

      [{Tailscale, child_pid, :worker, [Tailscale]}] = Supervisor.which_children(supervisor)
      assert Process.alive?(child_pid)

      Supervisor.stop(supervisor)
    end
  end
end
