defmodule TailscaleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Tailscale.CommandError
  alias Tailscale.DaemonManager
  alias Tailscale.Health
  alias Tailscale.Naming
  alias Tailscale.Preferences
  alias Tailscale.Profile
  alias Tailscale.Status

  def telemetry_handler(event, measurements, metadata, recipient) do
    send(recipient, {:telemetry, event, measurements, metadata})
  end

  setup do
    mocks = MockTailscale.create_mocks()
    unique = System.unique_integer([:positive])
    state_dir = Path.join(System.tmp_dir!(), "tailscale_state_#{unique}")
    runtime_dir = Path.join(System.tmp_dir!(), "tailscale_runtime_#{unique}")
    socket_path = Path.join(state_dir, "tailscaled.sock")
    name = :"tailscale_test_#{unique}"

    opts = [
      name: name,
      daemon_path: mocks.daemon_path,
      cli_path: mocks.cli_path,
      tailscale_dir: state_dir,
      socket_path: socket_path,
      runtime_dir: runtime_dir,
      command_timeout: 1_000,
      status_interval: 10_000,
      daemon_log_level: false,
      daemon_restart_min: 10,
      daemon_restart_max: 50,
      daemon_restart_stable: 100,
      daemon_restart_jitter: 0
    ]

    on_exit(fn ->
      MockTailscale.cleanup_mocks(mocks.test_dir)
      File.rm_rf!(state_dir)
      File.rm_rf!(runtime_dir)
    end)

    Map.merge(mocks, %{
      name: name,
      opts: opts,
      runtime_dir: runtime_dir,
      socket_path: socket_path,
      state_dir: state_dir
    })
  end

  describe "supervision and lifecycle" do
    test "starts an internally supervised daemon and client", context do
      root = start_instance(context)

      assert Process.alive?(root)
      assert Process.whereis(context.name)

      assert {:ok, %Health{client: :running, daemon: :running, socket: :ready}} =
               Tailscale.health(context.name)

      assert {:ok, pid} = daemon_pid(context)
      assert Process.alive?(pid)
    end

    test "restarts tailscaled without restarting the public server", context do
      _root = start_instance(context)
      server = Process.whereis(context.name)
      {:ok, daemon} = daemon_pid(context)

      Process.exit(daemon, :kill)

      assert_eventually(fn ->
        match?({:ok, %Health{daemon: :restarting}}, Tailscale.health(context.name))
      end)

      assert :ok = Tailscale.await_ready(context.name, timeout: 2_000)
      assert Process.whereis(context.name) == server
      assert {:ok, replacement} = daemon_pid(context)
      assert replacement != daemon
    end

    test "bounded restart loops do not kill Tailscale.Server", context do
      :ok = MockTailscale.configure_daemon_exits(context.test_dir, 3)
      _root = start_instance(context, await?: false)
      server = Process.whereis(context.name)

      assert :ok = Tailscale.await_ready(context.name, timeout: 3_000)
      assert Process.whereis(context.name) == server
      assert File.read!(Path.join(context.test_dir, "daemon-start-count")) == "4"
    end

    test "calls remain tuple-safe while the internal server restarts", context do
      _root = start_instance(context)
      server = Process.whereis(context.name)
      Process.exit(server, :kill)

      results = for _index <- 1..20, do: Tailscale.status(context.name)
      assert Enum.all?(results, fn {tag, _value} -> tag in [:ok, :error] end)
      assert_eventually(fn -> is_pid(Process.whereis(context.name)) end)
      assert :ok = Tailscale.await_ready(context.name, timeout: 2_000)
    end

    test "one_for_all restarts tasks, manager, and server after a server crash", context do
      _root = start_instance(context)
      original_server = Process.whereis(context.name)
      original_manager = GenServer.whereis(manager(context))

      Process.exit(original_server, :kill)

      assert_eventually(fn ->
        server = Process.whereis(context.name)
        is_pid(server) and server != original_server
      end)

      assert :ok = Tailscale.await_ready(context.name, timeout: 2_000)
      assert GenServer.whereis(manager(context)) != original_manager
    end

    test "supports an external daemon", context do
      File.mkdir_p!(Path.dirname(context.socket_path))
      File.touch!(context.socket_path)
      opts = Keyword.put(context.opts, :start_daemon, false)
      _root = start_instance(%{context | opts: opts})

      assert {:ok, %Health{daemon: :external, socket: :ready}} = Tailscale.health(context.name)
      assert {:ok, %Status{backend_state: :running}} = Tailscale.status(context.name)
    end

    test "multiple named instances remain isolated", context do
      _first = start_instance(context)
      second_mocks = MockTailscale.create_mocks()
      second_name = :"second_#{System.unique_integer([:positive])}"
      second_state = Path.join(context.state_dir, "second")

      second_opts =
        context.opts
        |> Keyword.put(:name, second_name)
        |> Keyword.put(:daemon_path, second_mocks.daemon_path)
        |> Keyword.put(:cli_path, second_mocks.cli_path)
        |> Keyword.put(:tailscale_dir, second_state)
        |> Keyword.put(:socket_path, Path.join(second_state, "tailscaled.sock"))
        |> Keyword.put(:runtime_dir, Path.join(context.runtime_dir, "second"))

      on_exit(fn -> MockTailscale.cleanup_mocks(second_mocks.test_dir) end)
      {:ok, second_root} = Tailscale.start_link(second_opts)
      on_exit(fn -> stop_root(second_root) end)

      assert :ok = Tailscale.await_ready(second_name, timeout: 2_000)
      assert :ok = Tailscale.set(context.name, hostname: "first")
      assert :ok = Tailscale.set(second_name, hostname: "second")

      assert {:ok, %Preferences{hostname: "first"}} = Tailscale.preferences(context.name)
      assert {:ok, %Preferences{hostname: "second"}} = Tailscale.preferences(second_name)
    end
  end

  describe "lifecycle chaos" do
    test "killing tailscaled during a status read returns a lifecycle error", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "status", 0.3)
      task = Task.async(fn -> Tailscale.status(context.name) end)
      assert_eventually(fn -> command_started?(context.test_dir, "status") end)
      {:ok, daemon} = daemon_pid(context)
      Process.exit(daemon, :kill)

      assert {:error, :daemon_restarting} = Task.await(task, 2_000)
      assert Process.alive?(Process.whereis(context.name))
      assert :ok = Tailscale.await_ready(context.name, timeout: 2_000)
    end

    test "killing tailscaled during login cleans secrets and preserves the server", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "login", 0.3)
      task = Task.async(fn -> Tailscale.login(context.name, auth_key: "tskey-chaos") end)
      assert_eventually(fn -> command_started?(context.test_dir, "login") end)
      {:ok, daemon} = daemon_pid(context)
      Process.exit(daemon, :kill)

      assert {:error, :daemon_restarting} = Task.await(task, 2_000)
      refute secret_directories(context)
      assert Process.alive?(Process.whereis(context.name))
    end

    test "killing tailscaled during profile switching cancels the mutation", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "switch", 0.3)
      task = Task.async(fn -> Tailscale.switch_profile(context.name, "profile-2") end)
      assert_eventually(fn -> command_started?(context.test_dir, "switch") end)
      {:ok, daemon} = daemon_pid(context)
      Process.exit(daemon, :kill)

      assert {:error, :daemon_restarting} = Task.await(task, 2_000)
      refute "switch profile-2" in MockTailscale.mutation_log(context.test_dir)
    end

    test "reports QEMU-style epipe exits structurally", context do
      _root = start_instance(context)
      {:ok, daemon} = daemon_pid(context)
      Process.exit(daemon, :epipe)

      assert_eventually(fn ->
        match?(
          {:ok, %Health{daemon: :restarting, last_daemon_exit: %{reason: :epipe}}},
          Tailscale.health(context.name)
        )
      end)
    end
  end

  describe "normalized status and health" do
    test "returns a typed status", context do
      _root = start_instance(context)

      assert {:ok,
              %Status{
                backend_state: :running,
                authenticated: true,
                online: true,
                ipv4: "100.64.0.1",
                hostname: "mock-host",
                peers: []
              }} = Tailscale.status(context.name)
    end

    test "preserves unknown startup fields", context do
      _root = start_instance(context)

      :ok =
        MockTailscale.configure_status(context.test_dir,
          backend_state: "Starting",
          online: "null",
          have_node_key: "null"
        )

      assert {:ok,
              %Status{
                backend_state: :starting,
                authenticated: :unknown,
                online: :unknown
              }} = Tailscale.status(context.name)
    end

    test "returns lifecycle errors instead of exiting", context do
      assert {:error, :server_unavailable} = Tailscale.status(:missing_tailscale_server)

      _root = start_instance(context)
      {:ok, daemon} = daemon_pid(context)
      Process.exit(daemon, :kill)

      assert_eventually(fn ->
        Tailscale.status(context.name) == {:error, :daemon_restarting}
      end)
    end

    test "normalizes route state", context do
      _root = start_instance(context)
      advertised = ["192.168.10.0/24", "10.20.0.0/16"]

      :ok =
        MockTailscale.configure_route_status(context.test_dir,
          approved: advertised,
          primary: ["192.168.10.0/24"]
        )

      assert :ok = Tailscale.set(context.name, advertise_routes: advertised)

      assert {:ok,
              %{
                advertised: ^advertised,
                approved: ^advertised,
                primary: ["192.168.10.0/24"]
              }} = Tailscale.route_status(context.name)
    end
  end

  describe "concurrent scheduler" do
    test "runs reads concurrently", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "status", 0.2)

      started = System.monotonic_time(:millisecond)
      tasks = for _index <- 1..2, do: Task.async(fn -> Tailscale.status(context.name) end)
      assert Enum.all?(Task.await_many(tasks, 2_000), &match?({:ok, %Status{}}, &1))
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 350
    end

    test "serializes mutations in FIFO order", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "set", 0.1)

      first = Task.async(fn -> Tailscale.set(context.name, hostname: "first") end)
      Process.sleep(20)
      second = Task.async(fn -> Tailscale.switch_profile(context.name, "profile-2") end)
      Process.sleep(20)
      third = Task.async(fn -> Tailscale.set(context.name, ssh: false) end)

      assert [:ok, :ok, :ok] == Task.await_many([first, second, third], 3_000)
      assert MockTailscale.mutation_log(context.test_dir) == ["set", "switch profile-2", "set"]
    end

    test "cancels a queued mutation when its caller dies", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "set", 0.3)

      first = Task.async(fn -> Tailscale.set(context.name, hostname: "first") end)
      Process.sleep(30)
      doomed = spawn(fn -> Tailscale.switch_profile(context.name, "never-run") end)
      Process.sleep(30)
      Process.exit(doomed, :kill)

      assert :ok = Task.await(first, 2_000)
      refute "switch never-run" in MockTailscale.mutation_log(context.test_dir)
    end

    test "cancels an active mutation and cleans secrets when its caller dies", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "login", 0.5)

      caller = spawn(fn -> Tailscale.login(context.name, auth_key: "tskey-abandoned") end)
      assert_eventually(fn -> command_started?(context.test_dir, "login") end)
      Process.exit(caller, :kill)

      assert_eventually(fn -> active_operation_count(context.name) == 0 end)
      refute secret_directories(context)
      refute "login" in MockTailscale.mutation_log(context.test_dir)
    end

    test "cancels active work on timeout", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "status", 0.5)

      assert {:error, %CommandError{reason: :timeout}} =
               Tailscale.cli(context.name, "status", ["--json"], mode: :read, timeout: 50)

      assert_eventually(fn -> active_operation_count(context.name) == 0 end)
    end

    test "single-flight polling skips ticks while a poll is active", context do
      :ok = MockTailscale.configure_delay(context.test_dir, "status", 0.15)
      opts = Keyword.put(context.opts, :status_interval, 20)
      _root = start_instance(%{context | opts: opts}, await?: false)
      Process.sleep(420)

      status_events =
        context.test_dir
        |> MockTailscale.command_log()
        |> Enum.filter(&String.contains?(&1, " status "))

      assert alternating_start_finish?(status_events)
    end
  end

  describe "typed enrollment and profiles" do
    test "uses a protected volatile auth-key file and removes it", context do
      _root = start_instance(context)
      key = "tskey-secret-#{System.unique_integer([:positive])}"
      parent = self()
      handler = "secret-test-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          [[:tailscale, :command, :start], [:tailscale, :command, :stop]],
          &__MODULE__.telemetry_handler/4,
          parent
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        capture_log(fn ->
          assert :ok =
                   Tailscale.login(context.name,
                     auth_key: key,
                     hostname: "gateway",
                     nickname: "factory",
                     accept_dns: false
                   )
        end)

      refute log =~ key
      refute inspect(:sys.get_state(context.name)) =~ key
      auth_argument = File.read!(Path.join(context.test_dir, "login-auth-argument"))
      assert String.starts_with?(auth_argument, "file:")
      refute auth_argument =~ key
      refute File.exists?(String.replace_prefix(auth_argument, "file:", ""))
      refute secret_directories(context)

      assert_receive {:telemetry, _event, _measurements, metadata}
      refute inspect(metadata) =~ key
    end

    test "cleans abandoned volatile login directories during startup", context do
      instance_dir = Path.join(context.runtime_dir, Naming.instance_id(context.name))
      abandoned = Path.join(instance_dir, "login-abandoned")
      File.mkdir_p!(abandoned)
      File.write!(Path.join(abandoned, "auth-key"), "abandoned-secret")

      _root = start_instance(context)
      refute File.exists?(abandoned)
    end

    test "never sends the key to the long-lived server during an active login", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_delay(context.test_dir, "login", 0.3)
      key = "tskey-process-secret"
      task = Task.async(fn -> Tailscale.login(context.name, auth_key: key) end)

      assert_eventually(fn -> command_started?(context.test_dir, "login") end)
      state = :sys.get_state(context.name)
      refute inspect(state) =~ key
      secret_path = active_login_secret_path(state)
      assert file_mode(secret_path) == 0o600
      assert file_mode(Path.dirname(secret_path)) == 0o700
      {processes, 0} = System.cmd("ps", ["-eo", "args"])
      refute processes =~ key
      assert processes =~ "--auth-key=file:"

      assert :ok = Task.await(task, 2_000)
    end

    test "redacts an auth key even if the CLI echoes it", context do
      _root = start_instance(context)
      File.touch!(Path.join(context.test_dir, "echo-auth-error"))
      key = "tskey-echoed-by-cli"

      assert {:error, %CommandError{output: "[REDACTED]"}} =
               Tailscale.login(context.name, auth_key: key)

      refute inspect(:sys.get_state(context.name)) =~ key
    end

    test "validates login options without echoing secrets", context do
      _root = start_instance(context)
      secret = "do-not-echo"

      assert {:error, {:invalid_login_option, :auth_key}} =
               Tailscale.login(context.name, auth_key: nil)

      assert {:error, {:unknown_login_options, [:unknown]}} =
               Tailscale.login(context.name, auth_key: secret, unknown: true)

      refute inspect(Tailscale.LoginOptions.encode(auth_key: secret, unknown: true)) =~ secret
    end

    test "lists, selects, switches, and removes typed profiles", context do
      _root = start_instance(context)

      assert {:ok, [%Profile{id: "profile-1", selected?: true} = profile]} =
               Tailscale.profiles(context.name)

      assert {:ok, ^profile} = Tailscale.current_profile(context.name)
      assert :ok = Tailscale.switch_profile(context.name, "profile-2")
      assert :ok = Tailscale.remove_profile(context.name, "profile-2")

      assert MockTailscale.mutation_log(context.test_dir) == [
               "switch profile-2",
               "switch remove profile-2"
             ]
    end

    test "supports broader typed preferences and readback", context do
      _root = start_instance(context)

      assert :ok =
               Tailscale.set(context.name,
                 hostname: "gateway",
                 accept_dns: false,
                 ssh: false,
                 advertise_routes: ["192.168.1.42/24"]
               )

      assert {:ok,
              %Preferences{
                hostname: "gateway",
                accept_dns: false,
                ssh: false,
                advertised_routes: ["192.168.1.0/24"]
              }} = Tailscale.preferences(context.name)
    end
  end

  describe "readiness and subscriptions" do
    test "distinguishes daemon readiness from online readiness", context do
      _root = start_instance(context)
      :ok = MockTailscale.configure_status(context.test_dir, online: false)

      assert :ok = Tailscale.await_ready(context.name, timeout: 500)
      assert {:ok, %Status{online: false}} = Tailscale.status(context.name)

      assert {:error, {:online_timeout, %Status{online: false}}} =
               Tailscale.await_online(context.name,
                 timeout: 80,
                 require: [:authenticated, :tailscale_ipv4]
               )

      :ok = MockTailscale.configure_status(context.test_dir, online: true)
      assert {:ok, %Status{online: true}} = Tailscale.status(context.name)

      assert :ok =
               Tailscale.await_online(context.name,
                 timeout: 500,
                 require: [:authenticated, :tailscale_ipv4]
               )
    end

    test "sends immediate, deduplicated snapshots with monotonic generations", context do
      opts = Keyword.put(context.opts, :status_interval, 30)
      _root = start_instance(%{context | opts: opts})

      assert :ok = Tailscale.subscribe(context.name)
      assert_receive {:tailscale, :status_changed, initial_generation, %Status{}}
      assert_receive {:tailscale, :health_changed, ^initial_generation, %Health{}}

      :ok = MockTailscale.configure_status(context.test_dir, hostname: "changed")

      assert_receive {:tailscale, :status_changed, generation, %Status{hostname: "changed"}}, 500
      assert generation > initial_generation
      refute_receive {:tailscale, :status_changed, _generation, %Status{hostname: "changed"}}, 120
    end

    test "subscribers converge after daemon restart", context do
      opts = Keyword.put(context.opts, :status_interval, 30)
      _root = start_instance(%{context | opts: opts})
      assert :ok = Tailscale.subscribe(context.name)
      flush_events()
      {:ok, daemon} = daemon_pid(context)
      Process.exit(daemon, :kill)

      assert_receive {:tailscale, :health_changed, restarting_generation,
                      %Health{daemon: :restarting}},
                     500

      assert_receive {:tailscale, :status_changed, _generation, %Status{online: :unknown}},
                     1_000

      assert_receive {:tailscale, :health_changed, running_generation, %Health{daemon: :running}},
                     1_000

      assert running_generation > restarting_generation

      assert_eventually(fn ->
        match?({:ok, %Status{online: true}}, Tailscale.status(context.name))
      end)
    end

    test "automatically removes dead subscribers", context do
      _root = start_instance(context)

      parent = self()

      subscriber =
        spawn(fn ->
          :ok = Tailscale.subscribe(context.name)
          send(parent, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      send(subscriber, :stop)

      assert_eventually(fn ->
        state = :sys.get_state(context.name)
        not Map.has_key?(state.subscriptions.subscribers, subscriber)
      end)
    end
  end

  describe "generic CLI" do
    test "requires explicit read or mutation mode", context do
      _root = start_instance(context)

      assert {:error, :invalid_cli_mode} = Tailscale.cli(context.name, "ip", [], [])
      assert {:ok, ips} = Tailscale.cli(context.name, "ip", [], mode: :read)
      assert ips =~ "100.64.0.1"
    end

    test "returns structured command errors", context do
      _root = start_instance(context)

      assert {:error,
              %CommandError{
                command: "invalid",
                exit_code: 1,
                reason: :exit_status,
                output: output
              }} = Tailscale.cli(context.name, "invalid", [], mode: :read)

      assert output =~ "unknown command"
    end
  end

  defp start_instance(context, opts \\ []) do
    await? = Keyword.get(opts, :await?, true)
    {:ok, root} = Tailscale.start_link(context.opts)
    on_exit(fn -> stop_root(root) end)

    assert_eventually(fn -> is_pid(Process.whereis(context.name)) end)
    if await?, do: assert(:ok == Tailscale.await_ready(context.name, timeout: 2_000))
    root
  end

  defp stop_root(root) do
    if is_pid(root) and Process.alive?(root), do: Supervisor.stop(root)
  catch
    :exit, _reason -> :ok
  end

  defp manager(context), do: Naming.via(context.name, :daemon_manager)
  defp daemon_pid(context), do: DaemonManager.daemon_pid(manager(context))

  defp active_operation_count(server) do
    server |> :sys.get_state() |> Map.fetch!(:operations) |> map_size()
  end

  defp secret_directories(context) do
    instance = Naming.instance_id(context.name)
    Path.wildcard(Path.join([context.runtime_dir, instance, "login-*"])) != []
  end

  defp active_login_secret_path(state) do
    state.operations
    |> Map.values()
    |> Enum.find(&(&1.kind == :login))
    |> Map.fetch!(:arguments)
    |> Enum.find(&String.starts_with?(&1, "--auth-key=file:"))
    |> String.replace_prefix("--auth-key=file:", "")
  end

  defp file_mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  defp command_started?(test_dir, command) do
    Enum.any?(MockTailscale.command_log(test_dir), &String.starts_with?(&1, "start #{command} "))
  end

  defp alternating_start_finish?(events) do
    events
    |> Enum.map(&(String.split(&1, " ", parts: 2) |> hd()))
    |> Enum.with_index()
    |> Enum.all?(fn
      {"start", index} -> rem(index, 2) == 0
      {"finish", index} -> rem(index, 2) == 1
    end)
  end

  defp flush_events do
    receive do
      {:tailscale, _event, _generation, _value} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp assert_eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met before timeout")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
    end
  end
end
