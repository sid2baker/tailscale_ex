defmodule Tailscale.StatusTest do
  use ExUnit.Case, async: true

  alias Tailscale.Peer
  alias Tailscale.Status

  test "preserves unknown values when startup fields are absent" do
    assert {:ok,
            %Status{
              backend_state: :starting,
              authenticated: :unknown,
              online: :unknown,
              ipv4: nil,
              hostname: nil,
              peers: []
            }} = Status.from_cli(%{"BackendState" => "Starting", "Self" => nil, "Peer" => nil})
  end

  test "normalizes explicit logged-out state" do
    assert {:ok, %Status{backend_state: :needs_login, authenticated: false, online: :unknown}} =
             Status.from_cli(%{"BackendState" => "NeedsLogin"})
  end

  test "preserves future backend states without creating atoms" do
    assert {:ok, %Status{backend_state: {:unknown, "FutureState"}}} =
             Status.from_cli(%{"BackendState" => "FutureState"})
  end

  test "normalizes peers and ignores malformed optional addresses" do
    raw = %{
      "BackendState" => "Running",
      "HaveNodeKey" => true,
      "TailscaleIPs" => ["bad", "100.64.0.1", "fd7a:115c:a1e0::1"],
      "Self" => %{"Online" => true},
      "Peer" => %{
        "node-key" => %{
          "ID" => "peer-1",
          "HostName" => "peer",
          "Online" => false,
          "TailscaleIPs" => ["100.64.0.2"]
        }
      }
    }

    assert {:ok,
            %Status{
              ipv4: "100.64.0.1",
              ipv6: "fd7a:115c:a1e0::1",
              peers: [%Peer{id: "peer-1", hostname: "peer", online: false}]
            }} = Status.from_cli(raw)
  end

  test "rejects non-map responses" do
    assert {:error, {:invalid_status_response, "not-json"}} = Status.from_cli("not-json")
  end
end
