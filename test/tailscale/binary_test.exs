defmodule Tailscale.BinaryTest do
  use ExUnit.Case, async: false

  alias Tailscale.Binary
  alias Tailscale.Platform

  @version "1.102.3"

  setup do
    {:ok, platform} = Platform.detect()

    test_dir =
      Path.join(System.tmp_dir!(), "tailscale_binary_test_#{System.unique_integer([:positive])}")

    install_dir = Path.join(test_dir, "installed")
    File.mkdir_p!(test_dir)

    archive_path = create_archive(test_dir, platform.arch)

    checksum =
      archive_path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{
      archive_path: archive_path,
      checksum: checksum,
      install_dir: install_dir,
      platform: platform
    }
  end

  describe "ensure_installed/1" do
    test "downloads, verifies, and installs both binaries", context do
      test_pid = self()
      download = fixture_downloader(context, fn url -> send(test_pid, {:download, url}) end)

      assert {:ok, paths} =
               Binary.ensure_installed(
                 version: @version,
                 install_dir: context.install_dir,
                 download: download
               )

      assert paths.version == @version
      assert paths.arch == context.platform.arch
      assert File.read!(paths.cli_path) == "fixture cli"
      assert File.read!(paths.daemon_path) == "fixture daemon"
      assert executable?(paths.cli_path)
      assert executable?(paths.daemon_path)

      artifact_arch = artifact_arch(context.platform.arch)
      basename = "tailscale_#{@version}_#{artifact_arch}.tgz"
      archive_url = "https://pkgs.tailscale.com/stable/#{basename}"
      checksum_url = "#{archive_url}.sha256"

      assert_received {:download, ^checksum_url}
      assert_received {:download, ^archive_url}
    end

    test "uses an existing versioned installation without downloading again", context do
      download = fixture_downloader(context)
      opts = [version: @version, install_dir: context.install_dir, download: download]

      assert {:ok, paths} = Binary.ensure_installed(opts)
      File.write!(paths.cli_path, "running cli")

      test_pid = self()
      unexpected_download = fn url, _destination -> send(test_pid, {:download, url}) end

      assert {:ok, ^paths} =
               Binary.ensure_installed(
                 version: @version,
                 install_dir: context.install_dir,
                 download: unexpected_download
               )

      assert File.read!(paths.cli_path) == "running cli"
      refute_received {:download, _url}
    end

    test "accepts an explicit checksum without fetching the checksum file", context do
      test_pid = self()

      download = fn url, destination ->
        send(test_pid, {:download, url})
        refute String.ends_with?(url, ".sha256")
        File.cp(context.archive_path, destination)
      end

      assert {:ok, _paths} =
               Binary.ensure_installed(
                 version: @version,
                 install_dir: context.install_dir,
                 sha256: String.upcase(context.checksum),
                 download: download
               )

      assert_received {:download, url}
      assert String.ends_with?(url, ".tgz")
      refute_received {:download, _url}
    end

    test "rejects an archive whose checksum does not match", context do
      download = fixture_downloader(%{context | checksum: String.duplicate("0", 64)})

      assert {:error, {:checksum_mismatch, checksums}} =
               Binary.ensure_installed(
                 version: @version,
                 install_dir: context.install_dir,
                 download: download
               )

      assert checksums.expected == String.duplicate("0", 64)
      assert checksums.actual == context.checksum
      refute File.exists?(version_dir(context))
    end

    test "rejects an archive missing one of the binaries", context do
      archive_path =
        create_archive(Path.dirname(context.archive_path), context.platform.arch, false)

      checksum =
        archive_path
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      download = fixture_downloader(%{context | archive_path: archive_path, checksum: checksum})

      assert {:error, {:invalid_archive, {:missing_binary, "tailscaled"}}} =
               Binary.ensure_installed(
                 version: @version,
                 install_dir: context.install_dir,
                 download: download
               )
    end

    test "serializes concurrent installation attempts", context do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      download = fn url, destination ->
        Agent.update(counter, &(&1 + 1))
        Process.sleep(20)

        if String.ends_with?(url, ".sha256") do
          File.write(destination, context.checksum)
        else
          File.cp(context.archive_path, destination)
        end
      end

      opts = [version: @version, install_dir: context.install_dir, download: download]
      tasks = for _index <- 1..2, do: Task.async(fn -> Binary.ensure_installed(opts) end)

      assert [ok, ok] = Enum.map(tasks, &Task.await(&1, 5_000))
      assert match?({:ok, _paths}, ok)
      assert Agent.get(counter, & &1) == 2
    end

    test "requires an exact pinned version", context do
      assert {:error, {:missing_option, :version}} =
               Binary.ensure_installed(install_dir: context.install_dir)

      assert {:error, {:invalid_version, "latest"}} =
               Binary.ensure_installed(version: "latest", install_dir: context.install_dir)
    end

    test "rejects a non-HTTPS package base URL", context do
      assert {:error, {:invalid_option, :base_url, "http://example.test"}} =
               Binary.ensure_installed(
                 version: @version,
                 install_dir: context.install_dir,
                 base_url: "http://example.test"
               )
    end
  end

  defp create_archive(test_dir, arch, include_daemon? \\ true) do
    artifact_arch = artifact_arch(arch)
    basename = "tailscale_#{@version}_#{artifact_arch}"
    suffix = if include_daemon?, do: "complete", else: "incomplete"
    archive_path = Path.join(test_dir, "#{suffix}.tgz")

    files = [
      {String.to_charlist(Path.join(basename, "tailscale")), "fixture cli"}
    ]

    files =
      if include_daemon? do
        files ++ [{String.to_charlist(Path.join(basename, "tailscaled")), "fixture daemon"}]
      else
        files
      end

    :ok = :erl_tar.create(String.to_charlist(archive_path), files, [:compressed])
    archive_path
  end

  defp fixture_downloader(context, notify \\ fn _url -> :ok end) do
    fn url, destination ->
      notify.(url)

      if String.ends_with?(url, ".sha256") do
        File.write(destination, context.checksum)
      else
        File.cp(context.archive_path, destination)
      end
    end
  end

  defp version_dir(context) do
    Path.join([context.install_dir, @version, artifact_arch(context.platform.arch)])
  end

  defp executable?(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o111) != 0
  end

  defp artifact_arch(:i386), do: "386"
  defp artifact_arch(arch), do: Atom.to_string(arch)
end
