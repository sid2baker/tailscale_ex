defmodule TailscaleTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
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
    refute capture_io(fn -> assert :ok = Tailscale.info() end) =~ url
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
      assert capture_io(fn -> assert :ok = Tailscale.info() end) =~ "Tailscale"
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

    for timeout <- [nil, 0, -1, :infinity, 1.5, 4_294_967_296] do
      assert {:error, :invalid_options} = Tailscale.login(timeout: timeout)
    end

    assert :ok = Tailscale.configure(%{hostname: "new", accept_dns: true})
    assert %{hostname: "new", accept_dns: true} = Tailscale.get_configuration()
    assert :ok = Tailscale.reset_to_defaults()
    assert %{hostname: "", accept_dns: false} = Tailscale.get_configuration()
    eventually(fn -> assert Tailscale.get(["configuration", "state"]) == :ready end)
  end

  test "public partial updates validate input and preserve unspecified settings", ctx do
    for {input, reason} <- [
          {nil, :invalid_configuration},
          {[hostname: "not-a-map"], :invalid_configuration},
          {%{auth_key: "private"}, :invalid_configuration},
          {%{"hostname" => "string-key"}, :invalid_configuration},
          {%{accept_dns: nil}, :invalid_configuration},
          {%{hostname: "invalid name"}, :invalid_hostname},
          {%{advertise_routes: ["invalid"]}, :invalid_route},
          {%{serve: nil}, :invalid_serve}
        ] do
      assert {:error, ^reason} = Tailscale.update_configuration(input)
    end

    refute Enum.any?(UnixHTTP.state(ctx.daemon).requests, &(&1.method in ["POST", "PATCH"]))
    assert :ok = Tailscale.configure(%{hostname: "runtime"})
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    eventually(fn -> assert Tailscale.get(["state"]) == :online end)
    assert :ok = Tailscale.update_configuration(%{accept_dns: true})
    assert %{hostname: "runtime", accept_dns: true} = Tailscale.get_configuration()
    assert :ok = Tailscale.configure(%{})
    assert %{hostname: "", accept_dns: false} = Tailscale.get_configuration()
  end

  test "browser login returns the delayed URL without touching caller subscriptions", ctx do
    parent = self()
    url = "https://login.tailscale.com/a/delayed"

    login =
      Task.async(fn ->
        :ok = Tailscale.subscribe(["auth"])
        send(self(), :unrelated)
        result = Tailscale.login()
        assert_receive :unrelated
        assert_receive {Tailscale, ["auth", "url"], nil, ^url, _}
        send(parent, :login_returned)
        assert_receive {Tailscale, ["auth", "url"], ^url, nil, _}
        result
      end)

    eventually(fn ->
      assert map_size(elem(:sys.get_state(Tailscale.Monitor), 1).login_waiters) == 1
    end)

    assert :ok = Tailscale.update_configuration(%{hostname: "while-waiting"})
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    assert_receive :login_returned
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    assert Task.await(login) == {:ok, url}
    assert elem(:sys.get_state(Tailscale.Monitor), 1).login_waiters == %{}
  end

  test "browser login returns a URL already recovered during initiation", ctx do
    url = "https://login.tailscale.com/a/fallback"
    UnixHTTP.update(ctx.daemon, &put_in(&1.status["AuthURL"], url))
    assert {:ok, ^url} = Tailscale.login()
    assert elem(:sys.get_state(Tailscale.Monitor), 1).login_waiters == %{}
  end

  test "browser login is a no-op when already online", ctx do
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    eventually(fn -> assert Tailscale.get(["state"]) == :online end)
    :sys.get_state(Tailscale.Controller)
    before = UnixHTTP.state(ctx.daemon).requests
    assert :ok = Tailscale.login()
    assert UnixHTTP.state(ctx.daemon).requests == before
  end

  test "URL wait timeout removes only the waiter, without cancelling enrollment", ctx do
    assert {:error, :timeout} = Tailscale.login(timeout: 20)
    assert elem(:sys.get_state(Tailscale.Monitor), 1).login_waiters == %{}
    assert Tailscale.get(["auth", "state"]) == :authenticating
    before = UnixHTTP.state(ctx.daemon).requests
    url = "https://login.tailscale.com/a/after-timeout"
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    eventually(fn -> assert Tailscale.get(["auth", "url"]) == url end)
    assert UnixHTTP.state(ctx.daemon).requests == before
  end

  test "auth failure, approval, logout and disconnect resolve URL waiters", ctx do
    for {action, reason} <- [
          {fn -> UnixHTTP.notify(ctx.daemon, %{"ErrMessage" => "private"}) end,
           :authentication_failed},
          {fn -> UnixHTTP.notify(ctx.daemon, %{"State" => 3}) end, :needs_approval},
          {fn -> Tailscale.logout() end, :logged_out},
          {fn -> UnixHTTP.disconnect(ctx.daemon) end, :disconnected}
        ] do
      UnixHTTP.notify(ctx.daemon, %{"State" => 2})
      eventually(fn -> assert Tailscale.get(["backend_state"]) == :needs_login end)
      login = Task.async(fn -> Tailscale.login(timeout: 1_000) end)

      eventually(fn ->
        assert map_size(elem(:sys.get_state(Tailscale.Monitor), 1).login_waiters) == 1
      end)

      action.()
      assert Task.await(login) == {:error, reason}
      assert elem(:sys.get_state(Tailscale.Monitor), 1).login_waiters == %{}
    end
  end

  test "auth keys pass directly to LocalAPI without being retained in controller state", ctx do
    key = "tskey-not-a-real-key"
    assert :ok = Tailscale.login(auth_key: key)

    assert Enum.any?(UnixHTTP.state(ctx.daemon).requests, fn request ->
             request.path == "/localapi/v0/start" and request.body == %{"AuthKey" => :redacted}
           end)

    refute inspect(:sys.get_state(Tailscale.Controller)) =~ key
    refute capture_io(fn -> assert :ok = Tailscale.info() end) =~ key

    assert %{message: :redacted} =
             Tailscale.Controller.format_status(%{message: {:login, {:auth_key, key}}})

    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"POST", "/localapi/v0/start"}], 403))
    assert {:error, {:http, 403}} = Tailscale.login(auth_key: key)
    assert Tailscale.get(["auth", "error"]) == {:http, 403}
    refute inspect(:sys.get_state(Tailscale.Controller)) =~ key
    refute capture_io(fn -> assert :ok = Tailscale.info() end) =~ key
  end
end
