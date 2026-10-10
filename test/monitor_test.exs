defmodule Tailscale.MonitorTest do
  use ExUnit.Case, async: true
  import Tailscale.Test.Fixture, only: [eventually: 1]
  alias Tailscale.{Monitor, Snapshot}
  alias Tailscale.Test.{Fixture, UnixHTTP}

  setup do
    {:ok, daemon} = Fixture.daemon()
    opts = Fixture.options(__MODULE__, UnixHTTP.socket(daemon))
    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert :ok = Monitor.ready(opts[:monitor])
    %{daemon: daemon, opts: opts, table: opts[:table], monitor: opts[:monitor]}
  end

  test "initial snapshot, incremental peer replacements/removals and duplicate event suppression",
       ctx do
    assert :offline == PropertyTable.get(ctx.table, ["state"])
    :ok = PropertyTable.subscribe(ctx.table, ["peers", :_, "online"])

    peer = %{
      "ID" => 42,
      "StableID" => "n42",
      "Online" => true,
      "Addresses" => ["100.1.2.3/32"],
      "Name" => "peer.ts.net."
    }

    UnixHTTP.notify(ctx.daemon, %{"PeersChanged" => [peer]})
    assert_receive {Tailscale, ["peers", "n42", "online"], nil, true, %{new_timestamp: timestamp}}
    assert is_integer(timestamp)
    assert PropertyTable.get(ctx.table, ["peers", "n42", "ipv4"]) == {100, 1, 2, 3}
    UnixHTTP.notify(ctx.daemon, %{"PeersChanged" => [peer]})
    refute_receive {Tailscale, ["peers", "n42", "online"], _, _, _}, 50

    UnixHTTP.notify(ctx.daemon, %{
      "PeersChanged" => [%{"ID" => 42, "StableID" => "n42", "Online" => false}]
    })

    assert_receive {Tailscale, ["peers", "n42", "online"], true, false, _}
    eventually(fn -> assert PropertyTable.get(ctx.table, ["peers", "n42", "ipv4"]) == nil end)
    UnixHTTP.notify(ctx.daemon, %{"PeersRemoved" => [42]})
    assert_receive {Tailscale, ["peers", "n42", "online"], false, nil, _}
  end

  test "disconnect marks unavailable, clears obsolete data and rebuilds an empty peer snapshot",
       ctx do
    UnixHTTP.notify(ctx.daemon, %{
      "State" => 6,
      "PeersChanged" => [%{"ID" => 1, "StableID" => "n1", "Online" => true}]
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["state"]) == :online end)
    PropertyTable.subscribe(ctx.table, ["state"])
    UnixHTTP.disconnect(ctx.daemon)
    assert_receive {Tailscale, ["state"], _, :unavailable, _}
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) >= 2 end)
    assert PropertyTable.match(ctx.table, ["peers"]) == []
    assert PropertyTable.get(ctx.table, ["state"]) == :offline
  end

  test "quiet streams stay connected without periodic status or configuration requests", ctx do
    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    requests = UnixHTTP.state(ctx.daemon).requests
    Process.sleep(1_200)
    assert PropertyTable.get(ctx.table, ["monitor", "generation"]) == 1
    assert PropertyTable.get(ctx.table, ["monitor", "connected"]) == true
    assert UnixHTTP.state(ctx.daemon).requests == requests
    refute Enum.any?(requests, &String.contains?(&1.path, "/status"))
  end

  test "interrupted authentication removes a stale URL and accepts a new attempt", ctx do
    url = "https://login.tailscale.com/a/interrupted"
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "url"]) == url end)
    PropertyTable.subscribe(ctx.table, ["auth", "url"])
    UnixHTTP.disconnect(ctx.daemon)
    assert_receive {Tailscale, ["auth", "url"], ^url, nil, _}
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) >= 2 end)
    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
    assert :ok = Tailscale.Controller.login(ctx.opts[:controller], :interactive)
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url <> "-new"})
    assert_receive {Tailscale, ["auth", "url"], nil, new_url, _}
    assert new_url == url <> "-new"
  end

  test "a replaced stream cannot change state or trigger another reconnect", ctx do
    {:ready, %{worker: old_worker}} = :sys.get_state(ctx.monitor)
    UnixHTTP.disconnect(ctx.daemon)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) == 2 end)
    {:ready, %{worker: worker}} = :sys.get_state(ctx.monitor)
    refute worker == old_worker

    assert {:error, :stale_stream} =
             :gen_statem.call(ctx.monitor, {:notification, old_worker, %{"State" => 6}})

    send(ctx.monitor, {:watch_ended, old_worker, {:error, :disconnected}})
    send(ctx.monitor, {:EXIT, old_worker, :normal})
    assert :ok = Monitor.ready(ctx.monitor)
    assert {:ready, %{worker: ^worker, generation: 2}} = :sys.get_state(ctx.monitor)
    assert PropertyTable.get(ctx.table, ["state"]) == :offline
  end

  test "authentication URL notifications, completion and error redaction", ctx do
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/example"})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticating
    end)

    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticated end)
    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
    UnixHTTP.notify(ctx.daemon, %{"State" => 2, "ErrMessage" => "secret backend error"})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["auth", "error"]) == :authentication_failed
    end)
  end

  test "login waiters have independent deadlines and are cleared on completion", ctx do
    assert :ok = Monitor.auth(ctx.monitor, :starting)
    short = Task.async(fn -> Monitor.await_login(ctx.monitor, 100) end)
    long = Task.async(fn -> Monitor.await_login(ctx.monitor, 5_000) end)
    eventually(fn -> assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 2 end)
    assert :ok = Monitor.ready(ctx.monitor)
    assert Task.await(short) == {:error, :timeout}
    assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 1
    url = "https://login.tailscale.com/a/shared"
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    assert Task.await(long) == {:ok, url}
    assert {:ready, %{login_waiters: %{}}} = :sys.get_state(ctx.monitor)
    assert elem(:sys.get_state(ctx.monitor), 1).login_waiters == %{}
  end

  test "starting from stopped waits for a URL or a running notification", ctx do
    UnixHTTP.notify(ctx.daemon, %{"State" => 4})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["backend_state"]) == :stopped end)
    assert :ok = Monitor.auth(ctx.monitor, :starting)
    login = Task.async(fn -> Monitor.await_login(ctx.monitor, 5_000) end)
    eventually(fn -> assert map_size(elem(:sys.get_state(ctx.monitor), 1).login_waiters) == 1 end)
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    assert Task.await(login) == :ok
  end

  test "a stopped snapshot preserves a new login across unrelated notifications" do
    snapshot = %Snapshot{backend: :stopped, auth_attempt: true}
    snapshot = Snapshot.update(snapshot, %{"Prefs" => %{}})
    assert snapshot.auth_attempt

    url = "https://login.tailscale.com/a/resuming"
    snapshot = Snapshot.update(snapshot, %{"BrowseToURL" => url})
    assert snapshot.url == url
    assert snapshot.auth_attempt

    failed = Snapshot.update(snapshot, %{"ErrMessage" => "private error"})
    assert failed.error == :authentication_failed
    assert failed.url == nil
    assert Snapshot.update(failed, %{"Prefs" => %{}}).error == :authentication_failed

    stopped = Snapshot.update(snapshot, %{"State" => 4})
    assert stopped.url == nil
    refute stopped.auth_attempt
  end

  test "snapshot tolerates missing fields and removes missing values on replacement" do
    snapshot =
      Snapshot.update(%Snapshot{}, %{
        "InitialStatus" => %{
          "Peer" => %{"pubkey" => %{"NodeID" => 10, "ID" => "n10", "Online" => true}}
        }
      })

    assert Snapshot.properties(snapshot)[["peers", "n10", "online"]]
    snapshot = Snapshot.update(snapshot, %{"PeersRemoved" => [10], "State" => 999})
    assert snapshot.peers == %{}
    assert snapshot.backend == :unknown
    assert Snapshot.properties(snapshot)[["state"]] == :unavailable
    assert Snapshot.update(snapshot, %{}) == snapshot
  end
end
