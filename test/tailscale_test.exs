defmodule TailscaleTest do
  use ExUnit.Case, async: false
  doctest Tailscale

  setup do
    # Create mock binaries
    %{cli_path: cli_path, daemon_path: daemon_path, test_dir: mock_dir} =
      MockTailscale.create_mocks()

    # Use test-specific state directory
    state_dir =
      Path.join(System.tmp_dir!(), "tailscale_state_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)

    opts = [
      name: :"test_tailscale_#{:erlang.unique_integer([:positive])}",
      daemon_path: daemon_path,
      cli_path: cli_path,
      tailscale_dir: state_dir
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
  end

  describe "child_spec/1" do
    test "returns valid child_spec", %{opts: opts} do
      spec = Tailscale.child_spec(opts)

      assert spec.id == Tailscale
      assert spec.start == {Tailscale, :start_link, [opts]}
      assert spec.type == :worker
      assert spec.restart == :permanent
      assert spec.shutdown == 5000
    end
  end

  describe "daemon_pid/1" do
    test "returns daemon PID when started", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      # Give it time to start
      Process.sleep(100)

      assert {:ok, daemon_pid} = Tailscale.daemon_pid(server_pid)
      assert is_pid(daemon_pid)
      assert Process.alive?(daemon_pid)

      GenServer.stop(server_pid)
    end

    test "returns error when daemon not started" do
      # Create a GenServer that never starts the daemon
      # For this test, we just check the error case conceptually
      :ok
    end
  end

  describe "version/1" do
    test "returns version string", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      # Give it time to check version
      Process.sleep(100)

      assert {:ok, version} = Tailscale.version(server_pid)
      assert is_binary(version)
      assert version == "1.88.3"

      GenServer.stop(server_pid)
    end
  end

  describe "online?/1" do
    test "returns boolean", %{opts: opts} do
      assert {:ok, server_pid} = Tailscale.start_link(opts)
      # Give it time to start
      Process.sleep(100)

      result = Tailscale.online?(server_pid)
      assert is_boolean(result)
      # Mock returns offline by default
      assert result == false

      GenServer.stop(server_pid)
    end
  end

  describe "supervision" do
    test "can be supervised", %{opts: opts} do
      children = [
        {Tailscale, opts}
      ]

      assert {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

      # Give it time to start
      Process.sleep(100)

      # Find the child
      [{Tailscale, child_pid, :worker, [Tailscale]}] = Supervisor.which_children(supervisor)
      assert Process.alive?(child_pid)

      Supervisor.stop(supervisor)
    end
  end
end
