defmodule Tailscale.RecoveryTest do
  use ExUnit.Case, async: true
  import Tailscale.Test.Fixture, only: [eventually: 1]
  alias Tailscale.{Controller, Monitor}
  alias Tailscale.Test.{Fixture, UnixHTTP}

  test "library starts before socket exists; failed login cannot claim offline or online" do
    socket =
      Path.join(System.tmp_dir!(), "tsx-delayed-#{System.unique_integer([:positive])}.sock")

    opts = Fixture.options(__MODULE__.Delayed, socket, timeout: 80)
    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert PropertyTable.get(opts[:table], ["state"]) == :unavailable
    assert {:error, :unavailable} = Monitor.ready(opts[:monitor], 20)
    Monitor.auth(opts[:monitor], {:error, :unavailable})
    assert PropertyTable.get(opts[:table], ["state"]) == :unavailable
    assert {:error, _} = Controller.configure(opts[:controller], %{hostname: "not-queued"})
    assert PropertyTable.get(opts[:table], ["configuration", "value"]) == nil
    {:ok, daemon} = Fixture.daemon(socket: socket)
    assert :ok = Monitor.ready(opts[:monitor])
    assert PropertyTable.get(opts[:table], ["state"]) == :offline
    assert PropertyTable.get(opts[:table], ["auth", "error"]) == nil

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "state"]) == :ready
    end)

    assert UnixHTTP.state(daemon).prefs["Hostname"] == ""
    assert Enum.all?(UnixHTTP.state(daemon).requests, &(&1.method == "GET"))
  end

  test "commands wait for initial readiness without caller coordination" do
    commands = [
      {Configure, fn server -> Controller.configure(server, %{hostname: "ready"}) end},
      {Update, fn server -> Controller.update_configuration(server, %{hostname: "ready"}) end},
      {Login, fn server -> Controller.login(server, :interactive) end},
      {Logout, &Controller.logout/1}
    ]

    for {name, command} <- commands do
      socket =
        Path.join(System.tmp_dir!(), "tsx-ready-#{System.unique_integer([:positive])}.sock")

      opts = Fixture.options(Module.concat(__MODULE__, name), socket, timeout: 1_000)
      start_supervised!({Fixture, opts}, id: name)
      on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
      task = Task.async(fn -> command.(opts[:controller]) end)
      eventually(fn -> assert map_size(elem(:sys.get_state(opts[:monitor]), 1).waiters) == 1 end)
      {:ok, _daemon} = Fixture.daemon(socket: socket)
      assert Task.await(task) == :ok
    end
  end

  test "unsupported daemon is rejected without configuration writes" do
    {:ok, daemon} =
      UnixHTTP.start_link(
        handler: fn request, requests ->
          response = {:watch, %{"Version" => "1.96.4", "InitialStatus" => %{}}}
          {response, [request | requests]}
        end,
        state: []
      )

    opts = Fixture.options(__MODULE__.Old, UnixHTTP.socket(daemon))
    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["monitor", "error"]) == :unsupported_version
    end)

    assert PropertyTable.get(opts[:table], ["state"]) == :unavailable
    assert Enum.all?(UnixHTTP.state(daemon), &String.contains?(&1.path, "watch-ipn-bus"))
  end

  test "missing initial snapshot times out and reconnects instead of falsely declaring ready" do
    {:ok, daemon} =
      UnixHTTP.start_link(
        handler: fn _request, state -> {{:watch, %{"Version" => "1.102.3-tbuild"}}, state} end
      )

    opts = Fixture.options(__MODULE__.Missing, UnixHTTP.socket(daemon), initial_timeout: 40)
    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert {:error, :unavailable} = Monitor.ready(opts[:monitor], 100)
    assert PropertyTable.get(opts[:table], ["monitor", "error"]) == :snapshot_timeout
    assert PropertyTable.get(opts[:table], ["state"]) == :unavailable
  end

  test "the initial deadline survives unrelated calls and is cancelled once ready" do
    {:ok, daemon} =
      UnixHTTP.start_link(
        state: 0,
        handler: fn
          %{path: "/localapi/v0/watch-ipn-bus?" <> _}, count -> {{:watch, nil}, count + 1}
          _request, count -> {{:json, 200, %{}, []}, count}
        end
      )

    opts =
      Fixture.options(__MODULE__.Deadlines, UnixHTTP.socket(daemon),
        initial_timeout: 150,
        retry_min: 100,
        retry_max: 100
      )

    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    eventually(fn -> assert match?({:connecting, _}, :sys.get_state(opts[:monitor])) end)
    {:connecting, %{worker: worker}} = :sys.get_state(opts[:monitor])
    worker_ref = Process.monitor(worker)
    ready = Task.async(fn -> Monitor.ready(opts[:monitor], 2_000) end)

    # Calls and partial stream frames must not cancel the connecting deadline.
    assert :ok = Monitor.auth(opts[:monitor], :starting)
    UnixHTTP.notify(daemon, %{"Version" => "1.102.3", "Prefs" => %{}})
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000

    eventually(fn ->
      assert {:connecting, %{worker: current}} = :sys.get_state(opts[:monitor])
      refute current == worker
      assert UnixHTTP.state(daemon) >= 2
    end)

    UnixHTTP.notify(daemon, %{"InitialStatus" => %{"BackendState" => "NeedsLogin"}})
    assert Task.await(ready) == :ok
    {:ready, %{worker: current}} = :sys.get_state(opts[:monitor])
    current_ref = Process.monitor(current)
    refute_receive {:DOWN, ^current_ref, :process, ^current, _}, 250
    assert {:ready, %{worker: ^current, generation: 1}} = :sys.get_state(opts[:monitor])
    Process.demonitor(current_ref, [:flush])
  end

  test "application restart reads daemon settings; reset applies changed defaults" do
    {:ok, daemon} = Fixture.daemon()
    opts = Fixture.options(__MODULE__.Restart, UnixHTTP.socket(daemon))
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    start_supervised!({Fixture, opts})
    assert :ok = Monitor.ready(opts[:monitor])
    assert :ok = Controller.configure(opts[:controller], %{hostname: "daemon-owned"})
    stop_supervised(Tailscale.Supervisor)
    start_supervised!({Fixture, Keyword.put(opts, :config, %{hostname: "app-default"})})
    assert :ok = Monitor.ready(opts[:monitor])

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "state"]) == :ready
    end)

    assert PropertyTable.get(opts[:table], ["configuration", "value"]).hostname == "daemon-owned"
    assert UnixHTTP.state(daemon).prefs["Hostname"] == "daemon-owned"
    assert :ok = Controller.reset(opts[:controller])
    assert PropertyTable.get(opts[:table], ["configuration", "value"]).hostname == "app-default"
  end

  test "controller restart reads daemon settings; monitor crash clears stale online cache" do
    {:ok, daemon} = Fixture.daemon()
    opts = Fixture.options(__MODULE__.Crash, UnixHTTP.socket(daemon))
    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert :ok = Monitor.ready(opts[:monitor])
    assert :ok = Tailscale.Controller.configure(opts[:controller], %{hostname: "volatile"})
    old_controller = Process.whereis(opts[:controller])
    Process.exit(old_controller, :kill)
    eventually(fn -> assert Process.whereis(opts[:controller]) not in [nil, old_controller] end)

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "value"]).hostname == "volatile"
    end)

    assert UnixHTTP.state(daemon).prefs["Hostname"] == "volatile"
    UnixHTTP.notify(daemon, %{"State" => 6})
    eventually(fn -> assert PropertyTable.get(opts[:table], ["state"]) == :online end)
    PropertyTable.subscribe(opts[:table], ["state"])
    Process.exit(Process.whereis(opts[:monitor]), :kill)
    assert_receive {Tailscale, ["state"], :online, :unavailable, _}
    eventually(fn -> assert PropertyTable.get(opts[:table], ["state"]) == :offline end)
  end
end
