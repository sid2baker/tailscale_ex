defmodule Tailscale.DaemonIntegrationTest do
  use ExUnit.Case, async: false
  import Tailscale.Test.Fixture, only: [eventually: 1, eventually: 2]
  alias Tailscale.{Controller, LocalAPI, Monitor}
  alias Tailscale.Test.Fixture

  @moduletag :integration
  @moduletag timeout: 90_000

  setup do
    binary = System.fetch_env!("TAILSCALED_TEST_BINARY")
    directory = Path.join(System.tmp_dir!(), "tsx-real-#{System.unique_integer([:positive])}")

    opts =
      Fixture.options(__MODULE__, Path.join(directory, "run/tailscaled.sock"),
        data_dir: directory,
        daemon_path: binary,
        manage_daemon: true,
        tun: :userspace,
        config: %{hostname: "must-not-apply", accept_dns: false},
        retry_min: 100,
        retry_max: 500
      )

    start_supervised!({Fixture, opts})
    on_exit(fn -> File.rm_rf(directory) end)
    assert :ok = Monitor.ready(opts[:monitor], 10_000)

    eventually(fn ->
      assert PropertyTable.get(opts[:table], ["configuration", "state"]) == :ready
    end)

    %{opts: opts, table: opts[:table], directory: directory}
  end

  test "real daemon owns preferences, including memory-only preferences before enrollment", ctx do
    assert PropertyTable.get(ctx.table, ["state"]) == :offline
    assert configuration(ctx).hostname == ""

    assert :ok =
             Controller.configure(ctx.opts[:controller], %{
               hostname: "tsx-integration",
               accept_dns: false
             })

    assert configuration(ctx).hostname == "tsx-integration"

    assert {:ok, %{"Hostname" => "tsx-integration", "CorpDNS" => false}, _} =
             LocalAPI.request(ctx.opts, "GET", "prefs")

    assert :ok = Controller.update_configuration(ctx.opts[:controller], %{accept_routes: true})

    assert {:ok, %{"Hostname" => "tsx-integration", "CorpDNS" => false, "RouteAll" => true}, _} =
             LocalAPI.request(ctx.opts, "GET", "prefs")

    # Restarting the controller rehydrates from the still-running daemon, not defaults.
    assert :ok = Supervisor.terminate_child(ctx.opts[:supervisor], Controller)
    PropertyTable.delete(ctx.table, ["configuration", "value"])
    assert {:ok, _} = Supervisor.restart_child(ctx.opts[:supervisor], Controller)
    eventually(fn -> assert PropertyTable.get(ctx.table, ["configuration", "value"]) != nil end)
    assert configuration(ctx).hostname == "tsx-integration"

    # A fresh unenrolled profile has nowhere to persist Serve configuration yet.
    assert {:ok, nil, headers} = LocalAPI.request(ctx.opts, "GET", "serve-config")
    assert List.keyfind(headers, "etag", 0)

    assert {:error, :awaiting_dns_name} =
             Tailscale.Serve.reconcile(ctx.opts, [%{https: 443, to: "http://127.0.0.1:80"}], nil)

    assert :ok = Tailscale.Serve.reconcile(ctx.opts, [], nil)

    identity = Path.join(ctx.directory, "identity")
    File.write!(Path.join(identity, "preserve-marker"), "identity storage must survive")
    daemon_pid = :sys.get_state(ctx.opts[:daemon]).pid
    generation = PropertyTable.get(ctx.table, ["monitor", "generation"])
    :ok = PropertyTable.subscribe(ctx.table, ["state"])
    GenServer.stop(daemon_pid, :shutdown)
    assert_receive {Tailscale, ["state"], _, :unavailable, _}, 10_000

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) > generation end,
      500
    )

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    assert File.read!(Path.join(identity, "preserve-marker")) == "identity storage must survive"

    # tailscaled does not persist prefs until enrollment creates a saved profile.
    # The library reports that reality rather than secretly reapplying configuration.
    assert {:ok, %{"Hostname" => ""}, _} = LocalAPI.request(ctx.opts, "GET", "prefs")
    assert configuration(ctx).hostname == ""
    PropertyTable.unsubscribe(ctx.table, ["state"])
    stop_supervised(Tailscale.Supervisor)
    start_supervised!({Fixture, ctx.opts})
    assert PropertyTable.get(ctx.table, ["state"]) != :online
    assert :ok = Monitor.ready(ctx.opts[:monitor], 10_000)

    eventually(fn ->
      assert PropertyTable.get(ctx.table, ["configuration", "state"]) == :ready
    end)

    assert configuration(ctx).hostname == ""
  end

  @tag :network
  test "real browser enrollment emits a URL and preserves the generated machine identity on restart",
       ctx do
    assert :ok = Controller.login(ctx.opts[:controller], :interactive)
    eventually(fn -> assert is_binary(PropertyTable.get(ctx.table, ["auth", "url"])) end, 2_000)
    assert PropertyTable.get(ctx.table, ["auth", "state"]) == :authenticating
    path = Path.join(ctx.directory, "identity/tailscaled.state")
    fingerprint = machine_fingerprint(path)
    generation = PropertyTable.get(ctx.table, ["monitor", "generation"])
    GenServer.stop(:sys.get_state(ctx.opts[:daemon]).pid, :shutdown)

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["monitor", "generation"]) > generation end,
      500
    )

    assert machine_fingerprint(path) == fingerprint
    # No browser completion, account enrollment, or end-to-end HTTPS assertion here.
  end

  @tag :network
  test "real invalid auth-key enrollment reaches the control server and emits a sanitized error",
       ctx do
    assert :ok =
             Controller.login(
               ctx.opts[:controller],
               {:auth_key, "tskey-auth-intentionally-invalid"}
             )

    eventually(
      fn -> assert PropertyTable.get(ctx.table, ["auth", "error"]) == :authentication_failed end,
      2_000
    )

    assert PropertyTable.get(ctx.table, ["auth", "url"]) == nil
    assert PropertyTable.get(ctx.table, ["state"]) != :online
  end

  defp configuration(ctx), do: PropertyTable.get(ctx.table, ["configuration", "value"])

  defp machine_fingerprint(path) do
    key = path |> File.read!() |> JSON.decode!() |> Map.fetch!("_machinekey")
    :crypto.hash(:sha256, key)
  end
end
