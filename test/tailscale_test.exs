defmodule TailscaleTest do
  use ExUnit.Case, async: false
  import Tailscale.Test.Fixture, only: [eventually: 1]
  alias Tailscale.Test.{Fixture, UnixHTTP}

  setup do
    {:ok, daemon} = Fixture.daemon()
    directory = Path.join(System.tmp_dir!(), "tsx-api-#{System.unique_integer([:positive])}")

    start_supervised!(
      {Fixture,
       socket: Tailscale.Test.UnixHTTP.socket(daemon), data_dir: directory, manage_daemon: false}
    )

    on_exit(fn -> File.rm_rf(directory) end)
    assert :ok = Tailscale.Monitor.ready(Tailscale.Monitor)
    eventually(fn -> assert is_map(Tailscale.get_configuration()) end)
    %{daemon: daemon}
  end

  test "public cache, prefix and wildcard events, unsubscribe, and diagnostics", ctx do
    assert :ok = Tailscale.subscribe(["auth"])
    assert Tailscale.get(["auth", "url"]) == nil
    assert Tailscale.get(["absent"], :default) == :default
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/private"})
    assert_receive {Tailscale, ["auth", "url"], nil, url, %{new_timestamp: timestamp}}
    assert is_integer(timestamp)
    assert Tailscale.get(["auth", "url"]) == url
    assert {["auth", "url"], url} in Tailscale.get_by_prefix(["auth"])
    refute inspect(Tailscale.info()) =~ url
    assert :ok = Tailscale.unsubscribe(["auth"])
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/other"})
    refute_receive {Tailscale, ["auth", "url"], _, _, _}, 50
    assert :ok = Tailscale.subscribe(["peers", :_, "online"])

    UnixHTTP.notify(ctx.daemon, %{
      "PeersChanged" => [%{"ID" => 1, "StableID" => "n1", "Online" => true}]
    })

    assert_receive {Tailscale, ["peers", "n1", "online"], nil, true, _}
  end

  test "cache APIs stay available even if controller is suspended" do
    :sys.suspend(Tailscale.Controller)

    try do
      assert Tailscale.get(["state"]) == :offline
      assert is_list(Tailscale.get_by_prefix([]))
      assert is_map(Tailscale.get_configuration())
      assert :ok = Tailscale.subscribe(["state"])
      assert :ok = Tailscale.unsubscribe(["state"])
    after
      :sys.resume(Tailscale.Controller)
    end
  end

  test "public validation and replacement/defaults" do
    assert {:error, _} = Tailscale.configure(%{auth_key: "private"})
    assert {:error, :invalid_options} = Tailscale.login(force: true)

    for key <- ["", nil, 123, ~c"key", String.duplicate("x", 4097)] do
      assert {:error, :invalid_auth_key} = Tailscale.login(auth_key: key)
    end

    assert {:error, :invalid_options} = Tailscale.login(auth_key: "key", force: true)
    assert :ok = Tailscale.configure(%{hostname: "new"})
    assert Tailscale.get_configuration().hostname == "new"
    assert :ok = Tailscale.reset_to_defaults()
    assert Tailscale.get_configuration().hostname == ""
    eventually(fn -> assert Tailscale.get(["configuration", "state"]) == :ready end)
  end

  test "auth keys pass directly to LocalAPI without being retained in controller state", ctx do
    key = "tskey-not-a-real-key"
    assert :ok = Tailscale.login(auth_key: key)

    assert Enum.any?(UnixHTTP.state(ctx.daemon).requests, fn request ->
             request.path == "/localapi/v0/start" and request.body == %{"AuthKey" => :redacted}
           end)

    refute inspect(:sys.get_state(Tailscale.Controller)) =~ key
    refute inspect(Tailscale.info()) =~ key

    assert %{message: :redacted} =
             Tailscale.Controller.format_status(%{message: {:login, {:auth_key, key}}})

    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"POST", "/localapi/v0/start"}], 403))
    assert {:error, {:http, 403}} = Tailscale.login(auth_key: key)
    assert Tailscale.get(["auth", "error"]) == {:http, 403}
    refute inspect(:sys.get_state(Tailscale.Controller)) =~ key
    refute inspect(Tailscale.info()) =~ key
  end
end
