defmodule Tailscale.SubnetRouterTest do
  use ExUnit.Case, async: true

  alias Tailscale.SubnetRouter

  setup do
    test_dir =
      Path.join(System.tmp_dir!(), "tailscale_subnet_test_#{System.unique_integer([:positive])}")

    paths = %{
      ipv4: Path.join(test_dir, "proc/ipv4"),
      ipv6: Path.join(test_dir, "proc/ipv6"),
      sysctl: Path.join(test_dir, "etc/sysctl.d/99-tailscale.conf")
    }

    File.mkdir_p!(Path.dirname(paths.ipv4))
    File.write!(paths.ipv4, "0\n")
    File.write!(paths.ipv6, "0\n")

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{paths: paths}
  end

  describe "normalize_routes/1" do
    test "canonicalizes and deduplicates IPv4 and IPv6 routes" do
      assert {:ok, ["192.168.1.0/24", "10.0.0.0/8", "fd00:1234::/64"]} =
               SubnetRouter.normalize_routes([
                 " 192.168.1.42/24 ",
                 "10.0.0.0/8",
                 "192.168.1.0/24",
                 "fd00:1234::abcd/64"
               ])
    end

    test "accepts an empty route list" do
      assert {:ok, []} = SubnetRouter.normalize_routes([])
    end

    test "rejects malformed addresses and prefixes" do
      invalid_routes = [
        "192.168.1.0",
        "192.168.1.0/33",
        "fd00::/129",
        "not-an-address/24",
        "192.168.1.0/twenty-four",
        ""
      ]

      for route <- invalid_routes do
        assert {:error, {:invalid_route, ^route}} = SubnetRouter.normalize_routes([route])
      end
    end

    test "rejects non-list and non-string routes" do
      assert {:error, {:invalid_routes, "192.168.1.0/24"}} =
               SubnetRouter.normalize_routes("192.168.1.0/24")

      assert {:error, {:invalid_route, :invalid}} = SubnetRouter.normalize_routes([:invalid])
    end
  end

  describe "forwarding_status/1" do
    test "returns the state of both forwarding families", %{paths: paths} do
      File.write!(paths.ipv4, "1\n")

      assert {:ok, %{ipv4: true, ipv6: false}} = SubnetRouter.forwarding_status(paths)
    end

    test "reports an unavailable forwarding control", %{paths: paths} do
      File.rm!(paths.ipv6)

      assert {:error, {:forwarding_status_unavailable, :ipv6, path, :enoent}} =
               SubnetRouter.forwarding_status(paths)

      assert path == paths.ipv6
    end

    test "rejects unexpected kernel values", %{paths: paths} do
      File.write!(paths.ipv4, "unexpected\n")

      assert {:error, {:invalid_forwarding_value, :ipv4, path, "unexpected"}} =
               SubnetRouter.forwarding_status(paths)

      assert path == paths.ipv4
    end
  end

  describe "enable_forwarding/2" do
    test "enables both families for the current boot", %{paths: paths} do
      assert :ok = SubnetRouter.enable_forwarding([], paths)
      assert File.read!(paths.ipv4) == "1\n"
      assert File.read!(paths.ipv6) == "1\n"
      refute File.exists?(paths.sysctl)
    end

    test "can enable only one family", %{paths: paths} do
      assert :ok = SubnetRouter.enable_forwarding([families: [:ipv4]], paths)
      assert File.read!(paths.ipv4) == "1\n"
      assert File.read!(paths.ipv6) == "0\n"
    end

    test "persists an idempotent sysctl.d configuration", %{paths: paths} do
      File.mkdir_p!(Path.dirname(paths.sysctl))
      File.write!(paths.sysctl, "old duplicated configuration\n")

      assert :ok = SubnetRouter.enable_forwarding([persist: :sysctl_d], paths)

      assert File.read!(paths.sysctl) ==
               "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n"

      assert :ok = SubnetRouter.enable_forwarding([persist: :sysctl_d], paths)

      assert File.read!(paths.sysctl) ==
               "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n"
    end

    test "rejects invalid options", %{paths: paths} do
      assert {:error, {:invalid_option, :families, [:ipv5]}} =
               SubnetRouter.enable_forwarding([families: [:ipv5]], paths)

      assert {:error, {:invalid_option, :persist, true}} =
               SubnetRouter.enable_forwarding([persist: true], paths)

      assert {:error, {:invalid_options, [unknown: true]}} =
               SubnetRouter.enable_forwarding([unknown: true], paths)
    end
  end
end
