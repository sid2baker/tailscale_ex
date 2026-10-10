defmodule Tailscale.ServeTest do
  use ExUnit.Case, async: true
  alias Tailscale.Serve
  alias Tailscale.Test.UnixHTTP

  @endpoints [%{https: 443, to: "http://127.0.0.1:80"}]

  test "normalizes endpoints, sorts ports, and rejects ambiguous or unsafe settings" do
    assert {:ok, endpoints} =
             Serve.normalize([
               %{https: 8443, to: "http://LOCALHOST:4000"},
               %{https: 443, to: "https://LOCALHOST:4443/app"}
             ])

    assert endpoints == [
             %{https: 443, to: "https://localhost:4443/app"},
             %{https: 8443, to: "http://localhost:4000"}
           ]

    assert {:ok, []} = Serve.normalize([])
    assert {:error, :duplicate_serve_port} = Serve.normalize(@endpoints ++ @endpoints)

    for invalid <- [
          nil,
          [%{https: 0, to: "http://localhost"}],
          [%{https: 443, to: "http://user:secret@localhost"}],
          [%{https: 443, to: "ftp://localhost"}],
          [%{https: 443, to: "http://localhost/#fragment"}],
          [%{https: 443, to: "http://localhost", unknown: true}]
        ] do
      assert {:error, reason} = Serve.normalize(invalid)
      refute inspect(reason) =~ "secret"
    end
  end

  test "Serve has exclusive node ownership, preserves services, and refuses foreground sessions" do
    current = %{
      "TCP" => %{"80" => %{}},
      "Web" => %{},
      "AllowFunnel" => %{"old:80" => true},
      "Services" => %{"svc:db" => %{}},
      "Extension" => 1
    }

    assert {:ok, desired} = Serve.build(current, @endpoints, "device.ts.net")
    assert desired["TCP"] == %{"443" => %{"HTTPS" => true}}
    assert desired["Web"]["device.ts.net:443"]["Handlers"]["/"]["Proxy"] == "http://127.0.0.1:80"
    assert desired["AllowFunnel"] == %{}
    assert desired["Services"] == current["Services"]
    assert desired["Extension"] == 1
    assert {:ok, removed} = Serve.build(desired, [], nil)
    assert removed["TCP"] == %{}

    assert {:error, :awaiting_dns_name} = Serve.build(%{}, @endpoints, nil)

    assert {:error, :serve_foreground_conflict} =
             Serve.build(%{"Foreground" => %{"session" => %{}}}, [], nil)
  end

  test "decodes supported daemon settings without dropping unsupported node settings" do
    assert {:ok, raw} =
             Serve.build(%{"Services" => %{"svc:db" => %{}}}, @endpoints, "device.ts.net")

    assert {:ok, @endpoints} = Serve.decode(raw)
    assert {:ok, []} = Serve.decode(nil)
    assert {:ok, []} = Serve.decode(%{"TCP" => nil, "Web" => %{}, "AllowFunnel" => nil})

    for unsupported <- [
          %{"TCP" => %{"80" => %{"HTTP" => true}}},
          %{"TCP" => %{"443" => %{"TCPForward" => "localhost:22"}}},
          put_in(raw, ["Web", "device.ts.net:443", "Handlers", "/other"], %{"Text" => "hello"}),
          put_in(raw, ["AllowFunnel"], %{"device.ts.net:443" => true}),
          put_in(raw, ["Foreground"], %{"session" => %{}}),
          put_in(raw, ["Web", "other.ts.net:443"], raw["Web"]["device.ts.net:443"]),
          %{"Web" => %{"invalid" => %{}}},
          %{"Web" => []},
          []
        ] do
      assert {:error, :unsupported_serve_configuration} = Serve.decode(unsupported)
    end
  end

  test "Serve sends If-Match and detects an ignored write by readback" do
    parent = self()

    server =
      start_supervised!(
        {UnixHTTP,
         handler: fn request, state ->
           send(parent, {:request, request})
           {{:json, 200, %{}, [{"etag", "version-1"}]}, state}
         end}
      )

    assert {:error, :serve_readback_mismatch} =
             Serve.reconcile([socket: UnixHTTP.socket(server)], @endpoints, "device.ts.net")

    assert_receive {:request, %{method: "GET"}}
    assert_receive {:request, %{method: "POST", headers: %{"if-match" => "version-1"}}}
    assert_receive {:request, %{method: "GET"}}
  end

  test "missing ETag or a concurrent edit cannot cause an unconditional overwrite" do
    for headers <- [[], [{"etag", "stale"}]] do
      server =
        start_supervised!(
          {UnixHTTP,
           handler: fn
             %{method: "GET"}, state -> {{:json, 200, %{}, headers}, state}
             %{method: "POST"}, state -> {{:json, 412, :empty, []}, state}
           end},
          id: make_ref()
        )

      expected = if headers == [], do: :missing_serve_etag, else: {:http, 412}

      assert {:error, ^expected} =
               Serve.reconcile([socket: UnixHTTP.socket(server)], @endpoints, "device.ts.net")
    end
  end
end
