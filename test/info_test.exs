defmodule Tailscale.InfoTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Tailscale.Info

  test "prints a friendly message before the application starts" do
    assert Process.whereis(Tailscale.Properties) == nil
    assert capture_io(fn -> assert :ok = Tailscale.info() end) == "Tailscale is not started.\n"
  end

  test "formats grouped status, readable addresses, configuration and errors" do
    report =
      Info.format(%{
        ["state"] => :online,
        ["backend_state"] => :running,
        ["auth", "state"] => :authenticated,
        ["daemon", "state"] => :external,
        ["version"] => "1.102.3",
        ["monitor", "connected"] => true,
        ["hostname"] => "device",
        ["dns_name"] => "device.ts.net",
        ["ipv4"] => {100, 1, 2, 3},
        ["ipv6"] => {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1},
        ["configuration", "value"] => %{hostname: "device"},
        ["configuration", "state"] => :error,
        ["configuration", "error"] => :unsupported_serve_configuration,
        ["health"] => ["A health warning"]
      })

    assert report =~ "Status: online"
    assert report =~ "Observer: connected"
    assert report =~ "100.1.2.3, fd7a:115c:a1e0::1"
    assert report =~ "device.ts.net"
    assert report =~ "Configuration (error)"
    assert report =~ "hostname: \"device\""
    assert report =~ "Serve: unavailable"
    assert report =~ "Configuration error: unsupported serve configuration"
    assert report =~ "Health warnings:"
    assert report =~ "A health warning"
    assert report =~ "Peers (0)"
  end

  test "prints every peer in stable name order, without inspect truncation" do
    properties =
      for n <- 75..1//-1,
          name = "peer-" <> String.pad_leading(to_string(n), 3, "0"),
          {field, value} <- [
            {"hostname", name},
            {"dns_name", name <> ".ts.net"},
            {"online", rem(n, 2) == 0},
            {"ipv4", {100, 1, 0, n}}
          ],
          into: %{},
          do: {["peers", to_string(n), field], value}

    report = Info.format(properties)
    assert report =~ "Peers (75)"
    assert report =~ "\"peer-001\" (offline)"
    assert report =~ "\"peer-002\" (online)"
    assert report =~ "100.1.0.75"
    refute report =~ "..."
    names = Regex.scan(~r/^  "(peer-\d+)"/m, report, capture: :all_but_first) |> List.flatten()
    assert names == Enum.map(1..75, &("peer-" <> String.pad_leading(to_string(&1), 3, "0")))
  end

  test "missing data is readable and login URLs never appear, including in health text" do
    url = "https://login.tailscale.com/a/secret"

    report =
      Info.format(%{
        ["auth", "url"] => url,
        ["health"] => ["Visit #{url}"],
        ["monitor", "error"] => :disconnected,
        ["auth", "error"] => :authentication_failed,
        ["hostname"] => "unsafe\n\e[31mname",
        ["peers", "n1", "online"] => false
      })

    refute report =~ url
    refute report =~ "\e"
    assert report =~ "[redacted]"
    assert report =~ "Observer: disconnected"
    assert report =~ "Observer error: disconnected"
    assert report =~ "Authentication error: authentication failed"
    assert report =~ "Addresses: none"
    assert report =~ "Unavailable"
    assert report =~ "\"n1\" (offline)"
  end
end
