defmodule TailscaledTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import Tailscaled.Test.Fixture, only: [eventually: 1]
  alias Tailscaled.Test.{Fixture, UnixHTTP}

  setup do
    {:ok, daemon} = Fixture.daemon()
    directory = Path.join(System.tmp_dir!(), "tsx-api-#{System.unique_integer([:positive])}")

    start_supervised!(
      {Fixture,
       socket: Tailscaled.Test.UnixHTTP.socket(daemon), data_dir: directory, manage_daemon: false}
    )

    on_exit(fn -> File.rm_rf(directory) end)
    assert :ok = Tailscaled.Monitor.ready(Tailscaled.Monitor)
    eventually(fn -> assert is_map(Tailscaled.get_configuration()) end)
    %{daemon: daemon}
  end

  test "public cache, prefix and wildcard events, unsubscribe, and diagnostics", ctx do
    assert :ok = Tailscaled.subscribe(["auth"])
    assert Tailscaled.get(["auth", "url"]) == nil
    assert Tailscaled.get(["absent"], :default) == :default
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/private"})
    assert_receive {Tailscaled, ["auth", "url"], nil, url, %{new_timestamp: timestamp}}
    assert is_integer(timestamp)
    assert Tailscaled.get(["auth", "url"]) == url
    assert {["auth", "url"], url} in Tailscaled.get_by_prefix(["auth"])
    refute capture_io(fn -> assert :ok = Tailscaled.info() end) =~ url
    assert :ok = Tailscaled.unsubscribe(["auth"])
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/other"})
    refute_receive {Tailscaled, ["auth", "url"], _, _, _}, 50
    assert :ok = Tailscaled.subscribe(["peers", :_, "online"])

    UnixHTTP.notify(ctx.daemon, %{
      "PeersChanged" => [%{"ID" => 1, "StableID" => "n1", "Online" => true}]
    })

    assert_receive {Tailscaled, ["peers", "n1", "online"], nil, true, _}
  end

  test "cache APIs stay available even if controller is suspended" do
    :sys.suspend(Tailscaled.Controller)

    try do
      assert Tailscaled.get(["state"]) == :offline
      assert is_list(Tailscaled.get_by_prefix([]))
      assert is_map(Tailscaled.get_configuration())
      assert capture_io(fn -> assert :ok = Tailscaled.info() end) =~ "Tailscale"
      assert :ok = Tailscaled.subscribe(["state"])
      assert :ok = Tailscaled.unsubscribe(["state"])
    after
      :sys.resume(Tailscaled.Controller)
    end
  end

  test "explicit refresh observes external Serve edits without notifications or writes", ctx do
    endpoints = [%{https: 443, to: "http://localhost:8080"}]
    {:ok, serve} = Tailscaled.Serve.build(%{}, endpoints, "device.ts.net")
    UnixHTTP.update(ctx.daemon, &%{&1 | serve: serve, etag: 2})
    before = UnixHTTP.state(ctx.daemon).requests
    assert Tailscaled.get_configuration().serve == []
    assert UnixHTTP.state(ctx.daemon).requests == before

    assert :ok = Tailscaled.refresh_configuration()
    assert Tailscaled.get_configuration().serve == endpoints
    assert Tailscaled.get(["configuration", "state"]) == :ready

    assert [
             %{method: "GET", path: "/localapi/v0/prefs"},
             %{method: "GET", path: "/localapi/v0/serve-config"}
           ] = Enum.drop(UnixHTTP.state(ctx.daemon).requests, length(before))
  end

  test "explicit refresh reports read failures and invalidates unreadable cache fields", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/serve-config"}], 403))
    assert {:error, {:http, 403}} = Tailscaled.refresh_configuration()
    refute Map.has_key?(Tailscaled.get_configuration(), :serve)
    assert Tailscaled.get(["configuration", "error"]) == {:http, 403}

    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/prefs"}], 403))
    assert {:error, {:http, 403}} = Tailscaled.refresh_configuration()
    assert Tailscaled.get_configuration() == nil

    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    assert :ok = Tailscaled.refresh_configuration()
    assert Tailscaled.get_configuration().serve == []
    assert Tailscaled.get(["configuration", "error"]) == nil
    refute Enum.any?(UnixHTTP.state(ctx.daemon).requests, &(&1.method in ["POST", "PATCH"]))
  end

  test "invalid UTF-8 Serve targets return validation errors without crashing", ctx do
    controller = Process.whereis(Tailscaled.Controller)
    before = UnixHTTP.state(ctx.daemon).requests

    for command <- [&Tailscaled.configure/1, &Tailscaled.update_configuration/1] do
      assert {:error, :invalid_serve_target} = command.(%{serve: [%{https: 443, to: <<255>>}]})
    end

    assert Process.whereis(Tailscaled.Controller) == controller
    assert Process.alive?(controller)
    assert UnixHTTP.state(ctx.daemon).requests == before
  end

  test "up and down change the running preference without claiming connectivity", ctx do
    assert :ok = Tailscaled.up()
    assert UnixHTTP.state(ctx.daemon).prefs["WantRunning"] == true
    assert Tailscaled.get(["state"]) == :offline
    assert Tailscaled.get(["auth", "state"]) == :needs_login
    assert :ok = Tailscaled.down()
    assert UnixHTTP.state(ctx.daemon).prefs["WantRunning"] == false

    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"PATCH", "/localapi/v0/prefs"}], 403))
    assert {:error, {:http, 403}} = Tailscaled.up()
    assert {:error, {:http, 403}} = Tailscaled.down()
  end

  test "public validation and replacement/defaults" do
    assert {:error, _} = Tailscaled.configure(%{auth_key: "private"})
    assert {:error, :invalid_options} = Tailscaled.login(force: true)

    for key <- ["", nil, 123, ~c"key", String.duplicate("x", 4097)] do
      assert {:error, :invalid_auth_key} = Tailscaled.login(auth_key: key)
    end

    assert {:error, :invalid_options} = Tailscaled.login(auth_key: "key", force: true)

    for timeout <- [nil, 0, -1, :infinity, 1.5, 4_294_967_296] do
      assert {:error, :invalid_options} = Tailscaled.login(timeout: timeout)
    end

    assert :ok = Tailscaled.configure(%{hostname: "new", accept_dns: true})
    assert %{hostname: "new", accept_dns: true} = Tailscaled.get_configuration()
    assert :ok = Tailscaled.reset_to_defaults()
    assert %{hostname: "", accept_dns: false} = Tailscaled.get_configuration()
    eventually(fn -> assert Tailscaled.get(["configuration", "state"]) == :ready end)
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
      assert {:error, ^reason} = Tailscaled.update_configuration(input)
    end

    refute Enum.any?(UnixHTTP.state(ctx.daemon).requests, &(&1.method in ["POST", "PATCH"]))
    assert :ok = Tailscaled.configure(%{hostname: "runtime"})
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    eventually(fn -> assert Tailscaled.get(["state"]) == :online end)
    assert :ok = Tailscaled.update_configuration(%{accept_dns: true})
    assert %{hostname: "runtime", accept_dns: true} = Tailscaled.get_configuration()
    assert :ok = Tailscaled.configure(%{})
    assert %{hostname: "", accept_dns: false} = Tailscaled.get_configuration()
  end

  test "browser login returns the delayed URL without touching caller subscriptions", ctx do
    parent = self()
    url = "https://login.tailscale.com/a/delayed"

    login =
      Task.async(fn ->
        :ok = Tailscaled.subscribe(["auth"])
        send(self(), :unrelated)
        result = Tailscaled.login()
        assert_receive :unrelated
        assert_receive {Tailscaled, ["auth", "url"], nil, ^url, _}
        send(parent, :login_returned)
        assert_receive {Tailscaled, ["auth", "url"], ^url, nil, _}
        result
      end)

    eventually(fn ->
      assert map_size(elem(:sys.get_state(Tailscaled.Monitor), 1).login_waiters) == 1
    end)

    assert :ok = Tailscaled.update_configuration(%{hostname: "while-waiting"})
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    assert_receive :login_returned
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    assert Task.await(login) == {:ok, url}
    assert elem(:sys.get_state(Tailscaled.Monitor), 1).login_waiters == %{}
  end

  test "browser login returns a URL already recovered during initiation", ctx do
    url = "https://login.tailscale.com/a/fallback"
    UnixHTTP.update(ctx.daemon, &put_in(&1.status["AuthURL"], url))
    assert {:ok, ^url} = Tailscaled.login()
    assert elem(:sys.get_state(Tailscaled.Monitor), 1).login_waiters == %{}
  end

  test "browser login is a no-op when already online", ctx do
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    eventually(fn -> assert Tailscaled.get(["state"]) == :online end)
    :sys.get_state(Tailscaled.Controller)
    before = UnixHTTP.state(ctx.daemon).requests
    assert :ok = Tailscaled.login()
    assert UnixHTTP.state(ctx.daemon).requests == before
  end

  test "URL wait timeout removes only the waiter, without cancelling enrollment", ctx do
    assert {:error, :timeout} = Tailscaled.login(timeout: 20)
    assert elem(:sys.get_state(Tailscaled.Monitor), 1).login_waiters == %{}
    assert Tailscaled.get(["auth", "state"]) == :authenticating
    before = UnixHTTP.state(ctx.daemon).requests
    url = "https://login.tailscale.com/a/after-timeout"
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => url})
    eventually(fn -> assert Tailscaled.get(["auth", "url"]) == url end)
    assert UnixHTTP.state(ctx.daemon).requests == before
  end

  test "auth failure, approval, logout and disconnect resolve URL waiters", ctx do
    for {action, reason} <- [
          {fn -> UnixHTTP.notify(ctx.daemon, %{"ErrMessage" => "private"}) end,
           :authentication_failed},
          {fn -> UnixHTTP.notify(ctx.daemon, %{"State" => 3}) end, :needs_approval},
          {fn -> Tailscaled.logout() end, :logged_out},
          {fn -> UnixHTTP.disconnect(ctx.daemon) end, :disconnected}
        ] do
      UnixHTTP.notify(ctx.daemon, %{"State" => 2})
      eventually(fn -> assert Tailscaled.get(["backend_state"]) == :needs_login end)
      login = Task.async(fn -> Tailscaled.login(timeout: 1_000) end)

      eventually(fn ->
        assert map_size(elem(:sys.get_state(Tailscaled.Monitor), 1).login_waiters) == 1
      end)

      action.()
      assert Task.await(login) == {:error, reason}
      assert elem(:sys.get_state(Tailscaled.Monitor), 1).login_waiters == %{}
    end
  end

  test "auth keys reach LocalAPI without appearing in controller state or OTP diagnostics", ctx do
    key = "tskey-not-a-real-key"
    :ok = :sys.log(Tailscaled.Controller, true)
    assert :ok = Tailscaled.login(auth_key: key)

    assert Enum.any?(UnixHTTP.state(ctx.daemon).requests, fn request ->
             request.path == "/localapi/v0/start" and request.body == %{"AuthKey" => :redacted}
           end)

    refute inspect(:sys.get_state(Tailscaled.Controller)) =~ key
    refute capture_io(fn -> assert :ok = Tailscaled.info() end) =~ key

    refute inspect(:sys.get_status(Tailscaled.Controller), limit: :infinity) =~ key
    refute inspect(:sys.log(Tailscaled.Controller, :get), limit: :infinity) =~ key

    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"POST", "/localapi/v0/start"}], 403))
    assert {:error, {:http, 403}} = Tailscaled.login(auth_key: key)
    assert Tailscaled.get(["auth", "error"]) == {:http, 403}
    refute inspect(:sys.get_state(Tailscaled.Controller)) =~ key
    refute inspect(:sys.get_status(Tailscaled.Controller), limit: :infinity) =~ key
    refute inspect(:sys.log(Tailscaled.Controller, :get), limit: :infinity) =~ key
    refute capture_io(fn -> assert :ok = Tailscaled.info() end) =~ key
  end
end
