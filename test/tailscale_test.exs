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

  # Helper functions

  defp start_and_wait(opts) do
    {:ok, pid} = Tailscale.start_link(opts)
    wait_for_daemon(pid)
    pid
  end

  defp wait_for_daemon(pid, attempts \\ 50) do
    case Tailscale.daemon_pid(pid) do
      {:ok, daemon_pid} when is_pid(daemon_pid) ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_daemon(pid, attempts - 1)

      _ ->
        raise "Daemon failed to start within timeout"
    end
  end

  describe "start_link/1" do
    test "starts with default options", %{opts: opts} do
      pid = start_and_wait(opts)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with custom name", %{opts: opts} do
      opts = Keyword.put(opts, :name, :custom_tailscale)
      pid = start_and_wait(opts)
      assert Process.whereis(:custom_tailscale) == pid
      GenServer.stop(pid)
    end

    test "starts with custom timeout", %{opts: opts} do
      opts = Keyword.put(opts, :timeout, 10_000)
      pid = start_and_wait(opts)
      assert Process.alive?(pid)
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

    test "returns validation error when daemon path is not executable", %{
      opts: opts,
      state_dir: state_dir
    } do
      non_executable = Path.join(state_dir, "not_executable")
      File.write!(non_executable, "#!/bin/bash\necho test")
      File.chmod!(non_executable, 0o644)

      opts = Keyword.put(opts, :daemon_path, non_executable)
      assert {:error, message} = Tailscale.start_link(opts)
      assert message =~ "not executable"
    end

    test "returns validation error when cli path is not executable", %{
      opts: opts,
      state_dir: state_dir
    } do
      non_executable = Path.join(state_dir, "not_executable_cli")
      File.write!(non_executable, "#!/bin/bash\necho test")
      File.chmod!(non_executable, 0o644)

      opts = Keyword.put(opts, :cli_path, non_executable)
      assert {:error, message} = Tailscale.start_link(opts)
      assert message =~ "not executable"
    end
  end

  describe "child_spec/1" do
    test "returns valid child_spec", %{opts: opts} do
      spec = Tailscale.child_spec(opts)

      assert spec.id == Tailscale
      assert spec.start == {Tailscale, :start_link, [opts]}
    end
  end

  describe "daemon_pid/1" do
    test "returns daemon PID when started", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, daemon_pid} = Tailscale.daemon_pid(pid)
      assert is_pid(daemon_pid)
      assert Process.alive?(daemon_pid)

      GenServer.stop(pid)
    end
  end

  describe "version/1" do
    test "returns version string", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, version} = Tailscale.version(pid)
      assert is_binary(version)
      assert version =~ "1.88.3"

      GenServer.stop(pid)
    end
  end

  describe "status/1" do
    test "returns status map with JSON data", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, status} = Tailscale.status(pid)
      assert is_map(status)
      assert status["Self"]["HostName"] == "mock-host"
      assert status["Self"]["Online"] == true

      GenServer.stop(pid)
    end
  end

  describe "login/2" do
    test "attempts login with auth key", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.login(pid, "tskey-mock-12345")
      assert is_binary(result)
      assert result =~ "login.tailscale.com"

      GenServer.stop(pid)
    end
  end

  describe "online?/1" do
    test "returns true when online", %{opts: opts} do
      pid = start_and_wait(opts)

      result = Tailscale.online?(pid)
      assert is_boolean(result)
      assert result == true

      GenServer.stop(pid)
    end
  end

  describe "cli/3" do
    test "executes status command with JSON output", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "status", ["--json"])
      assert is_map(result)
      assert result["Self"]["HostName"] == "mock-host"
      assert result["Self"]["Online"] == true

      GenServer.stop(pid)
    end

    test "executes ip command", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "ip", [])
      assert is_binary(result)
      assert result =~ "100.64.0.1"

      GenServer.stop(pid)
    end

    test "executes version command", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "version", [])
      assert is_binary(result)
      assert result =~ "1.88.3"

      GenServer.stop(pid)
    end

    test "executes up command", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "up", [])
      assert is_binary(result)
      assert result =~ "Success"

      GenServer.stop(pid)
    end

    test "executes down command", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "down", [])
      assert is_binary(result)
      assert result =~ "Success"

      GenServer.stop(pid)
    end

    test "executes netcheck command", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "netcheck", [])
      assert is_binary(result)
      assert result =~ "Report"

      GenServer.stop(pid)
    end

    test "executes whois command with JSON", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:ok, result} = Tailscale.cli(pid, "whois", ["100.64.0.1", "--json"])
      assert is_map(result)
      assert result["Node"]["Name"] == "mock-node"

      GenServer.stop(pid)
    end

    test "returns error for unknown command", %{opts: opts} do
      pid = start_and_wait(opts)

      assert {:error, {exit_code, output}} = Tailscale.cli(pid, "invalid", [])
      assert exit_code == 1
      assert output =~ "unknown command"

      GenServer.stop(pid)
    end
  end

  describe "concurrent instances" do
    test "can run multiple instances simultaneously", %{opts: opts1, state_dir: _state_dir} do
      %{cli_path: cli_path2, daemon_path: daemon_path2, test_dir: mock_dir2} =
        MockTailscale.create_mocks()

      state_dir2 =
        Path.join(System.tmp_dir!(), "tailscale_state_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(state_dir2)
      socket_path2 = Path.join(state_dir2, "tailscaled.sock")

      opts2 = [
        name: :"test_tailscale_#{:erlang.unique_integer([:positive])}",
        daemon_path: daemon_path2,
        cli_path: cli_path2,
        tailscale_dir: state_dir2,
        socket_path: socket_path2
      ]

      pid1 = start_and_wait(opts1)
      pid2 = start_and_wait(opts2)

      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      assert {:ok, daemon1} = Tailscale.daemon_pid(pid1)
      assert {:ok, daemon2} = Tailscale.daemon_pid(pid2)
      assert daemon1 != daemon2

      assert {:ok, _} = Tailscale.version(pid1)
      assert {:ok, _} = Tailscale.version(pid2)

      GenServer.stop(pid1)
      GenServer.stop(pid2)

      MockTailscale.cleanup_mocks(mock_dir2)
      File.rm_rf!(state_dir2)
    end
  end

  describe "supervision" do
    test "can be supervised", %{opts: opts} do
      children = [{Tailscale, opts}]

      assert {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

      Process.sleep(100)

      [{Tailscale, child_pid, :worker, [Tailscale]}] = Supervisor.which_children(supervisor)
      assert Process.alive?(child_pid)

      wait_for_daemon(child_pid)
      assert {:ok, daemon_pid} = Tailscale.daemon_pid(child_pid)
      assert Process.alive?(daemon_pid)

      Supervisor.stop(supervisor)
    end

    test "supervisor restarts child after crash", %{opts: opts} do
      children = [{Tailscale, opts}]

      assert {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      Process.sleep(100)

      [{Tailscale, original_pid, :worker, [Tailscale]}] = Supervisor.which_children(supervisor)
      wait_for_daemon(original_pid)

      Process.exit(original_pid, :kill)
      Process.sleep(100)

      [{Tailscale, new_pid, :worker, [Tailscale]}] = Supervisor.which_children(supervisor)
      assert Process.alive?(new_pid)
      assert new_pid != original_pid

      Supervisor.stop(supervisor)
    end
  end

  describe "daemon lifecycle" do
    test "daemon is started automatically on init", %{opts: opts} do
      pid = start_and_wait(opts)
      {:ok, daemon_pid} = Tailscale.daemon_pid(pid)

      assert Process.alive?(daemon_pid)

      GenServer.stop(pid)
    end
  end

  describe "timeout handling" do
    test "respects custom timeout setting", %{opts: opts} do
      opts = Keyword.put(opts, :timeout, 10_000)
      pid = start_and_wait(opts)

      # Verify it started successfully with custom timeout
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
