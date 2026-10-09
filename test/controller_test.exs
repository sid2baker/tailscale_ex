defmodule Tailscale.ControllerTest do
  use ExUnit.Case, async: true
  import Tailscale.Test.Fixture, only: [eventually: 1]
  alias Tailscale.{Controller, Monitor}
  alias Tailscale.Test.{Fixture, UnixHTTP}

  setup do
    {:ok, daemon} = Fixture.daemon()

    opts =
      Fixture.options(__MODULE__, UnixHTTP.socket(daemon),
        auth_url_ttl: 80,
        config: %{hostname: "app-default", accept_dns: false}
      )

    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(opts[:data_dir]) end)
    assert :ok = Monitor.ready(opts[:monitor])

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "state"]) == :ready
    end)

    %{daemon: daemon, opts: opts, controller: opts[:controller], table: opts[:table]}
  end

  test "startup reads daemon settings; only explicit reset applies application defaults", ctx do
    assert configuration(ctx).hostname == ""
    assert configuration(ctx).accept_dns
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
    assert :ok = Controller.reset(ctx.controller)
    assert configuration(ctx).hostname == "app-default"
    refute configuration(ctx).accept_dns
    assert UnixHTTP.state(ctx.daemon).prefs["Unmanaged"] == "kept"
  end

  test "configuration replacement, removal, and idempotent readback", ctx do
    dns(ctx)
    config = %{hostname: "nerves", ssh: true, serve: [%{https: 443, to: "http://127.0.0.1"}]}
    assert :ok = Controller.configure(ctx.controller, config)
    assert configuration(ctx).hostname == "nerves"
    assert configuration(ctx).serve == config.serve
    first = UnixHTTP.state(ctx.daemon)
    assert first.prefs["Unmanaged"] == "kept"
    assert first.serve["TCP"]["443"] == %{"HTTPS" => true}
    assert :ok = Controller.configure(ctx.controller, config)
    assert writes(UnixHTTP.state(ctx.daemon)) == writes(first)
    assert :ok = Controller.configure(ctx.controller, %{})
    assert UnixHTTP.state(ctx.daemon).serve["TCP"] == %{}
    assert UnixHTTP.state(ctx.daemon).prefs["RunSSH"] == false
    assert configuration(ctx).serve == []
  end

  test "concurrent calls serialize complete configuration replacements", ctx do
    tasks =
      for index <- 1..8,
          do:
            Task.async(fn ->
              Controller.configure(ctx.controller, %{hostname: "node-#{index}"})
            end)

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == configuration(ctx).hostname
  end

  test "failed mutations return errors and are never retried, even after a notification", ctx do
    for status <- [503, 400] do
      UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"PATCH", "/localapi/v0/prefs"}], status))

      assert {:error, {:http, ^status}} =
               Controller.configure(ctx.controller, %{hostname: "rejected"})

      assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, status}
      assert configuration(ctx).hostname == ""
      count = writes(UnixHTTP.state(ctx.daemon))
      UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
      UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
      Process.sleep(150)
      assert writes(UnixHTTP.state(ctx.daemon)) == count
      assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == ""
    end

    assert :ok = Controller.configure(ctx.controller, %{hostname: "caller-retried"})
    assert configuration(ctx).hostname == "caller-retried"
  end

  test "external preference changes and reconnects refresh the cache without writes", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.prefs["Hostname"], "external"))
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
    eventually(fn -> assert %{hostname: "external"} = configuration(ctx) end)
    UnixHTTP.disconnect(ctx.daemon)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) >= 2 end)
    eventually(fn -> assert %{hostname: "external"} = configuration(ctx) end)
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
  end

  test "failed background reads clear the cache and retry only reads", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/prefs"}], 503))
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})
    eventually(fn -> assert configuration(ctx) == nil end)
    assert PropertyTable.get(ctx.table, ["configuration", "error"]) == {:http, 503}
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    eventually(fn -> assert is_map(configuration(ctx)) end)
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
  end

  test "failed configure readback recovers the cache without replaying the mutation", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"GET", "/localapi/v0/serve-config"}], 503))

    assert {:error, {:http, 503}} =
             Controller.configure(ctx.controller, %{hostname: "partially-applied"})

    assert configuration(ctx) == nil
    assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == "partially-applied"
    count = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}})
    eventually(fn -> assert is_map(configuration(ctx)) end)
    assert configuration(ctx).hostname == "partially-applied"
    assert writes(UnixHTTP.state(ctx.daemon)) == count
  end

  test "Serve without DNS fails immediately and is not applied after login", ctx do
    config = %{serve: [%{https: 443, to: "http://localhost:80"}]}
    assert {:error, :awaiting_dns_name} = Controller.configure(ctx.controller, config)
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
    dns(ctx)
    UnixHTTP.notify(ctx.daemon, %{"State" => 6})
    Process.sleep(150)
    assert UnixHTTP.state(ctx.daemon).serve == nil
    assert :ok = Controller.configure(ctx.controller, config)
    assert UnixHTTP.state(ctx.daemon).serve["Web"]["device.ts.net:443"]
  end

  test "partial changes are observed and Serve CAS conflicts require an explicit retry", ctx do
    dns(ctx)
    UnixHTTP.update(ctx.daemon, &put_in(&1.failures[{"POST", "/localapi/v0/serve-config"}], 412))
    config = %{hostname: "partial", serve: [%{https: 443, to: "http://localhost"}]}
    assert {:error, {:http, 412}} = Controller.configure(ctx.controller, config)
    assert configuration(ctx).hostname == "partial"
    assert configuration(ctx).serve == []
    count = writes(UnixHTTP.state(ctx.daemon))
    UnixHTTP.update(ctx.daemon, &%{&1 | failures: %{}, etag: 9})
    Process.sleep(150)
    assert writes(UnixHTTP.state(ctx.daemon)) == count
    assert :ok = Controller.configure(ctx.controller, config)
    assert configuration(ctx).serve == config.serve

    assert Enum.any?(UnixHTTP.state(ctx.daemon).requests, fn request ->
             request.method == "POST" and request.path == "/localapi/v0/serve-config" and
               request.headers["if-match"] == "9"
           end)
  end

  test "unsupported external Serve config is reported rather than represented as empty", ctx do
    UnixHTTP.update(ctx.daemon, &%{&1 | serve: %{"TCP" => %{"80" => %{"HTTP" => true}}}})
    UnixHTTP.notify(ctx.daemon, %{"Prefs" => %{}})

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "error"]) ==
               :unsupported_serve_configuration
    end)

    assert configuration(ctx) == nil
    assert writes(UnixHTTP.state(ctx.daemon)) == 0
  end

  test "interactive login watches first and never reapplies application defaults", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.prefs["Hostname"], "existing"))
    assert :ok = Controller.login(ctx.controller, :interactive)
    assert UnixHTTP.state(ctx.daemon).prefs["Hostname"] == "existing"
    paths = Enum.map(UnixHTTP.state(ctx.daemon).requests, & &1.path)
    assert hd(paths) =~ "watch-ipn-bus"
    assert "/localapi/v0/start" in paths
    assert "/localapi/v0/login-interactive" in paths
    refute PropertyTable.get(ctx.table, ["state"]) == :online
    UnixHTTP.notify(ctx.daemon, %{"BrowseToURL" => "https://login.tailscale.com/a/test"})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "url"]) != nil end)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["auth", "error"]) == :url_expired end)
    assert :ok = Controller.login(ctx.controller, :interactive)

    UnixHTTP.notify(ctx.daemon, %{
      "BrowseToURL" => "https://login.tailscale.com/a/new",
      "State" => 6
    })

    eventually(fn -> assert PropertyTable.get(ctx.table, ["state"]) == :online end)
    before = writes(UnixHTTP.state(ctx.daemon))
    assert :ok = Controller.login(ctx.controller, :interactive)
    assert writes(UnixHTTP.state(ctx.daemon)) == before
  end

  test "auth-key is sent via Start and activates a new profile without being retained", ctx do
    assert :ok = Controller.login(ctx.controller, {:auth_key, "tskey-not-a-real-key"})
    requests = UnixHTTP.state(ctx.daemon).requests

    assert Enum.any?(
             requests,
             &(&1.path == "/localapi/v0/start" and &1.body == %{"AuthKey" => :redacted})
           )

    assert Enum.any?(requests, &(&1.path == "/localapi/v0/login-interactive"))
    refute inspect(:sys.get_state(ctx.controller)) =~ "tskey-not-a-real-key"
    refute inspect(configuration(ctx)) =~ "tskey"
    assert :ok = Controller.logout(ctx.controller)
    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
  end

  test "key enrollment with an existing node key does not trigger interactive login", ctx do
    UnixHTTP.update(ctx.daemon, &put_in(&1.status["HaveNodeKey"], true))
    assert :ok = Controller.login(ctx.controller, {:auth_key, "tskey-test-existing"})

    refute Enum.any?(
             UnixHTTP.state(ctx.daemon).requests,
             &(&1.path == "/localapi/v0/login-interactive")
           )

    assert UnixHTTP.state(ctx.daemon).prefs["LoggedOut"] == false
  end

  defp dns(ctx) do
    UnixHTTP.notify(ctx.daemon, %{"SelfChange" => %{"ID" => 1, "Name" => "device.ts.net."}})
    eventually(fn -> assert PropertyTable.get(ctx.table, ["dns_name"]) == "device.ts.net" end)
  end

  defp configuration(ctx), do: PropertyTable.get(ctx.table, ["configuration", "value"])
  defp writes(state), do: Enum.count(state.requests, &(&1.method in ["POST", "PATCH"]))
end
