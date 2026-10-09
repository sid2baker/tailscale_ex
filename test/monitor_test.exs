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
