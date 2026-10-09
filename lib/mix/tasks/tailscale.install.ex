defmodule Mix.Tasks.Tailscale.Install do
  use Mix.Task

  @shortdoc "Download the tested tailscaled binary for the current target"
  @moduledoc """
  Downloads Tailscale 1.102.3 from the official stable repository and verifies its
  published SHA-256 checksum. Installs only `tailscaled`; no daemon is started.

      mix tailscale.install ./bin/tailscaled
      MIX_TARGET=rpi4 mix tailscale.install rootfs_overlay/usr/sbin/tailscaled
      MIX_TARGET=custom mix tailscale.install ./bin/tailscaled --arch arm64

  Run in the application that depends on `:tailscale`. The required destination is
  the full binary filename, relative to the current directory or absolute. Parent
  directories are created; an existing binary is replaced only after verification.
  Configure `:tailscale, :daemon_path` with its path on the running device (for the
  Nerves overlay example, `/usr/sbin/tailscaled`).

  For Nerves, use your firmware's `MIX_TARGET`. Architecture detection uses
  `REBAR_TARGET_ARCH` exported by its toolchain, not the build host or board name.
  Host builds use the running Erlang VM's Linux architecture. Unknown targets fail
  instead of falling back to the host. Use separate destinations for different
  target architectures.

  ## Options

    * `--arch` - explicit Linux archive architecture: `386`, `amd64`, `arm`,
      `arm64`, `geode`, `mips`, `mipsle`, `mips64`, `mips64le`, or `riscv64`.
  """
  @requirements ["loadpaths"]
  @version "1.102.3"
  @architectures ~w(386 amd64 arm arm64 geode mips mipsle mips64 mips64le riscv64)

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [arch: :string])

    destination =
      case rest do
        [path] when path != "" -> path
        _ -> Mix.raise("Usage: mix tailscale.install DESTINATION [--arch ARCH]")
      end

    arch =
      opts[:arch] ||
        architecture!(
          Mix.target(),
          System.get_env("REBAR_TARGET_ARCH"),
          to_string(:erlang.system_info(:system_architecture))
        )

    install!(arch, destination)
    Mix.shell().info("Installed tailscaled #{@version} (#{arch}) at #{destination}")
  end

  @doc false
  def architecture!(target, target_arch, host_arch) do
    triple = if target == :host, do: host_arch, else: target_arch

    unless is_binary(triple) and String.contains?(triple, "-linux") do
      Mix.raise("Cannot determine a Linux architecture for #{target}; pass --arch explicitly")
    end

    archive_architecture!(triple |> String.split("-") |> hd())
  end

  @doc false
  def install!(arch, destination, download \\ &download!/1) do
    unless arch in @architectures, do: Mix.raise("Unsupported archive architecture: #{arch}")

    name = "tailscale_#{@version}_#{arch}"
    url = "https://pkgs.tailscale.com/stable/#{name}.tgz"
    checksum = url |> Kernel.<>(".sha256") |> download.() |> String.trim()
    archive = download.(url)
    actual = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    unless actual == checksum, do: Mix.raise("SHA-256 mismatch for #{name}.tgz")

    member = String.to_charlist("#{name}/tailscaled")

    case :erl_tar.extract({:binary, archive}, [:compressed, :memory, files: [member]]) do
      {:ok, [{^member, binary}]} -> write_binary!(destination, binary)
      _ -> Mix.raise("Archive does not contain #{name}/tailscaled")
    end
  end

  defp archive_architecture!(cpu) do
    case cpu do
      "x86_64" -> "amd64"
      "aarch64" -> "arm64"
      arm when arm in ~w(arm armv5te armv5tel armv6 armv6l armv7 armv7l armv7a armv8l) -> "arm"
      "i686" -> "386"
      "riscv64" -> "riscv64"
      other -> Mix.raise("Unsupported target architecture #{other}; pass --arch explicitly")
    end
  end

  defp download!(url) do
    Mix.shell().info("Downloading #{url}")

    case Mix.Utils.read_path(url) do
      {:ok, body} -> body
      _ -> Mix.raise("Could not download #{url}")
    end
  end

  defp write_binary!(destination, binary) do
    File.mkdir_p!(Path.dirname(destination))
    temporary = destination <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temporary, binary, [:exclusive])
      File.chmod!(temporary, 0o755)
      File.rename!(temporary, destination)
    after
      File.rm(temporary)
    end
  end
end
