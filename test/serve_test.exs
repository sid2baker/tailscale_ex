defmodule Tailscale.ServeTest do
  use ExUnit.Case, async: true
  alias Tailscale.Serve
  alias Tailscale.Test.UnixHTTP

  @endpoints [%{https: 443, to: "http://127.0.0.1:80"}]

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
