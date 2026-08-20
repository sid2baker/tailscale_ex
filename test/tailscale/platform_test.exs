defmodule Tailscale.PlatformTest do
  use ExUnit.Case, async: true

  alias Tailscale.Platform

  describe "detect/2" do
    test "normalizes supported Linux runtime architectures" do
      architectures = [
        {"x86_64-pc-linux-gnu", :amd64},
        {"amd64-unknown-linux-musl", :amd64},
        {"i686-pc-linux-gnu", :i386},
        {"aarch64-buildroot-linux-gnu", :arm64},
        {"armv7l-buildroot-linux-gnueabihf", :arm},
        {"mips-unknown-linux-gnu", :mips},
        {"mipsel-unknown-linux-gnu", :mipsle},
        {"mips64-unknown-linux-gnuabi64", :mips64},
        {"mips64el-unknown-linux-gnuabi64", :mips64le},
        {"riscv64-unknown-linux-gnu", :riscv64}
      ]

      for {system_architecture, expected_arch} <- architectures do
        assert {:ok,
                %Platform{
                  os: :linux,
                  arch: ^expected_arch,
                  system_architecture: ^system_architecture
                }} = Platform.detect({:unix, :linux}, system_architecture)
      end
    end

    test "accepts the charlist returned by Erlang" do
      assert {:ok, %Platform{arch: :arm64}} =
               Platform.detect({:unix, :linux}, ~c"aarch64-buildroot-linux-gnu")
    end

    test "rejects non-Linux operating systems" do
      assert {:error, {:unsupported_os, {:unix, :darwin}}} =
               Platform.detect({:unix, :darwin}, "x86_64-apple-darwin")
    end

    test "rejects unsupported Linux architectures" do
      assert {:error, {:unsupported_architecture, "sparc-linux-gnu"}} =
               Platform.detect({:unix, :linux}, "sparc-linux-gnu")
    end
  end
end
