defmodule Tailscaled.InstallTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Tailscaled.Install

  @moduletag :tmp_dir

  test "detects Linux hosts without using cross-compilation metadata" do
    assert Install.architecture!(:host, "armv7-nerves-linux-gnueabihf", "x86_64-pc-linux-gnu") ==
             "amd64"

    assert Install.architecture!(:host, nil, "aarch64-unknown-linux-musl") == "arm64"
  end

  test "uses toolchain architecture, not the board name or build host" do
    for {triple, expected} <- [
          {"aarch64-nerves-linux-gnu", "arm64"},
          {"armv6-nerves-linux-gnueabihf", "arm"},
          {"armv7-nerves-linux-gnueabihf", "arm"},
          {"x86_64-nerves-linux-musl", "amd64"},
          {"i686-buildroot-linux-gnu", "386"},
          {"riscv64-nerves-linux-gnu", "riscv64"}
        ] do
      assert Install.architecture!(:custom_board, triple, "x86_64-apple-darwin") == expected
    end
  end

  test "unknown targets and non-Linux hosts fail rather than guessing" do
    for {target, triple, host} <- [
          {:rpi4, nil, "x86_64-pc-linux-gnu"},
          {:custom, "", "x86_64-pc-linux-gnu"},
          {:custom, "powerpc-linux-gnu", "x86_64-pc-linux-gnu"},
          {:custom, "armeb-linux-gnueabi", "x86_64-pc-linux-gnu"},
          {:host, nil, "aarch64-apple-darwin"}
        ] do
      assert_raise Mix.Error, ~r/pass --arch explicitly/, fn ->
        Install.architecture!(target, triple, host)
      end
    end
  end

  test "validates task arguments before downloading" do
    assert_raise OptionParser.ParseError, fn -> Install.run(["--unknown"]) end

    for args <- [[], [""], ["first", "second"], ["--arch", "arm64"]] do
      assert_raise Mix.Error, ~r/Usage: mix tailscaled\.install DESTINATION/, fn ->
        Install.run(args)
      end
    end

    assert_raise Mix.Error, ~r/Unsupported archive/, fn ->
      Install.run(["rootfs_overlay/usr/sbin/tailscaled", "--arch", "bad"])
    end
  end

  test "installs only the checked daemon, executable, at the requested destination", %{
    tmp_dir: dir
  } do
    archive = archive!(dir, "arm64")
    download = downloader(archive, "arm64")
    destination = Path.join(dir, "rootfs_overlay/usr/sbin/tailscaled")
    other_target = Path.join(dir, "bin/tailscaled")
    File.mkdir_p!(Path.dirname(other_target))
    File.write!(other_target, "host binary")

    assert :ok = Install.install!("arm64", destination, download)
    assert File.read!(destination) == "target binary"
    assert Bitwise.band(File.stat!(destination).mode, 0o777) == 0o755
    assert File.ls!(Path.dirname(destination)) == ["tailscaled"]
    assert File.read!(other_target) == "host binary"

    assert :ok = Install.install!("arm64", destination, download)
    assert File.read!(destination) == "target binary"
  end

  test "checksum failure preserves the existing binary", %{tmp_dir: dir} do
    destination = Path.join(dir, "tailscaled")
    File.write!(destination, "existing binary")
    download = downloader(archive!(dir, "amd64"), "amd64", String.duplicate("0", 64))

    assert_raise Mix.Error, ~r/SHA-256 mismatch/, fn ->
      Install.install!("amd64", destination, download)
    end

    assert File.read!(destination) == "existing binary"
    refute Enum.any?(File.ls!(dir), &String.ends_with?(&1, ".tmp"))
  end

  test "wrong architecture archive or invalid archive cannot replace a binary", %{tmp_dir: dir} do
    destination = Path.join(dir, "tailscaled")
    File.write!(destination, "existing binary")

    for archive <- [archive!(dir, "arm"), "not a tar archive"] do
      assert_raise Mix.Error, ~r/Archive does not contain/, fn ->
        Install.install!("amd64", destination, downloader(archive, "amd64"))
      end

      assert File.read!(destination) == "existing binary"
    end
  end

  defp archive!(directory, arch) do
    path = Path.join(directory, "archive.tgz")
    prefix = "tailscale_1.102.3_#{arch}"

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {String.to_charlist("#{prefix}/tailscaled"), "target binary"},
          {String.to_charlist("#{prefix}/tailscale"), "unneeded CLI"},
          {~c"unrelated", "not extracted"}
        ],
        [:compressed]
      )

    File.read!(path)
  end

  defp downloader(archive, arch, checksum \\ nil) do
    checksum = checksum || :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
    url = "https://pkgs.tailscale.com/stable/tailscale_1.102.3_#{arch}.tgz"

    fn
      ^url -> archive
      checksum_url when checksum_url == url <> ".sha256" -> checksum <> "\n"
    end
  end
end
