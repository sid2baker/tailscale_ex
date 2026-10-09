defmodule Tailscale.ConfigurationTest do
  use ExUnit.Case, async: true
  alias Tailscale.{Configuration, Serve}

  test "normalizes managed values and CIDR networks" do
    assert {:ok, config} =
             Configuration.normalize(%{
               hostname: "Nerves-Livebook",
               advertise_routes: ["10.1.2.3/16", {{10, 1, 1, 1}, 16}, "2001:db8::ff/64"]
             })

    assert config.hostname == "nerves-livebook"
    assert config.advertise_routes == ["10.1.0.0/16", "2001:db8::/64"]
    assert config.accept_dns
  end

  test "rejects unsupported fields, credentials and malformed settings without including values" do
    for input <- [
          %{auth_key: "secret"},
          %{hostname: "bad_host"},
          %{ssh: "yes"},
          %{advertise_routes: ["1.2.3.4/33"]},
          %{advertise_routes: [{{999, 0, 0, 0}, 24}]},
          %{serve: [%{https: 0, to: "http://localhost"}]},
          %{serve: [%{https: 443, to: "http://user:secret@localhost"}]},
          %{serve: [%{https: 443, to: "ftp://localhost"}]}
        ] do
      assert {:error, reason} = Configuration.normalize(input)
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

    assert {:ok, desired} =
             Serve.build(current, [%{https: 443, to: "http://127.0.0.1:80"}], "device.ts.net")

    assert desired["TCP"] == %{"443" => %{"HTTPS" => true}}
    assert desired["Web"]["device.ts.net:443"]["Handlers"]["/"]["Proxy"] == "http://127.0.0.1:80"
    assert desired["AllowFunnel"] == %{}
    assert desired["Services"] == current["Services"]
    assert desired["Extension"] == 1
    assert {:ok, removed} = Serve.build(desired, [], nil)
    assert removed["TCP"] == %{}

    assert {:error, :awaiting_dns_name} =
             Serve.build(%{}, [%{https: 443, to: "http://localhost"}], nil)

    assert {:error, :serve_foreground_conflict} =
             Serve.build(%{"Foreground" => %{"session" => %{}}}, [], nil)
  end

  test "observed preferences expose only managed fields, preserving false and normalizing nil routes" do
    prefs = %{
      "Hostname" => "external.example",
      "CorpDNS" => false,
      "RouteAll" => true,
      "RunSSH" => false,
      "AdvertiseRoutes" => nil,
      "Persist" => %{"PrivateNodeKey" => "private"}
    }

    assert Configuration.observed(prefs, []) == %{
             hostname: "external.example",
             accept_dns: false,
             accept_routes: true,
             ssh: false,
             advertise_routes: [],
             serve: []
           }
  end

  test "preference patch only touches managed differences" do
    {:ok, config} = Configuration.normalize(%{})

    current =
      Map.merge(Configuration.preferences(config), %{
        "Unmanaged" => true,
        "AdvertiseRoutes" => nil
      })

    assert Configuration.patch(config, current) == %{}

    assert Configuration.patch(%{config | ssh: true}, current) == %{
             "RunSSH" => true,
             "RunSSHSet" => true
           }
  end
end
