defmodule Tailscale.Binary do
  @moduledoc """
  Downloads and installs pinned Tailscale binaries for the current Linux ABI.

  Installation is explicit: this module is not called automatically by
  `Tailscale.start_link/1`. Archives are downloaded from Tailscale's stable
  package repository, checked against their published SHA-256 checksum, and
  extracted into a versioned directory.
  """

  alias Tailscale.Platform

  @base_url "https://pkgs.tailscale.com/stable"
  @default_install_dir "/data/tailscale/bin"
  @default_timeout 60_000
  @hash_chunk_size 1_048_576
  @version_pattern ~r/^\d+\.\d+\.\d+$/
  @sha256_pattern ~r/^[0-9a-f]{64}$/

  @type paths :: %{
          required(:arch) => Platform.architecture(),
          required(:cli_path) => Path.t(),
          required(:daemon_path) => Path.t(),
          required(:version) => String.t()
        }

  @type downloader :: (String.t(), Path.t() -> :ok | {:error, term()})

  @type option ::
          {:version, String.t()}
          | {:install_dir, Path.t()}
          | {:sha256, String.t()}
          | {:timeout, pos_integer()}
          | {:cacertfile, Path.t()}
          | {:base_url, String.t()}
          | {:download, downloader()}

  @type options :: [option()]

  @doc """
  Ensures that a pinned Tailscale version is installed for the current Linux ABI.

  The required `:version` must be an exact version such as `"1.102.3"`.

  ## Options

    * `:version` - exact Tailscale version to install (required)
    * `:install_dir` - root for versioned installations (default: `#{@default_install_dir}`)
    * `:sha256` - expected archive checksum; otherwise the official `.sha256` file is fetched
    * `:timeout` - HTTP request timeout in milliseconds (default: `#{@default_timeout}`)
    * `:cacertfile` - custom PEM CA certificate bundle for HTTPS
    * `:base_url` - HTTPS package mirror (default: `#{@base_url}`)
    * `:download` - custom `(url, destination -> result)` downloader

  The returned paths can be passed directly to `Tailscale.start_link/1`.

  ## Example

      {:ok, binaries} =
        Tailscale.Binary.ensure_installed(
          version: "1.102.3",
          install_dir: "/data/tailscale/bin"
        )

      Tailscale.start_link(
        daemon_path: binaries.daemon_path,
        cli_path: binaries.cli_path
      )

  """
  @spec ensure_installed(options()) :: {:ok, paths()} | {:error, term()}
  def ensure_installed(opts) when is_list(opts) do
    with {:ok, platform} <- Platform.detect(),
         {:ok, config} <- build_config(opts, platform) do
      lock = {{__MODULE__, config.final_dir}, self()}
      :global.trans(lock, fn -> ensure_installed_locked(config) end)
    end
  end

  def ensure_installed(_opts), do: {:error, :invalid_options}

  defp build_config(opts, platform) do
    with {:ok, version} <- fetch_version(opts),
         {:ok, install_dir} <- fetch_path(opts, :install_dir, @default_install_dir),
         {:ok, timeout} <- fetch_timeout(opts),
         {:ok, cacertfile} <- fetch_optional_path(opts, :cacertfile),
         {:ok, base_url} <- fetch_base_url(opts),
         {:ok, sha256} <- fetch_optional_checksum(opts),
         {:ok, custom_downloader} <- fetch_custom_downloader(opts) do
      artifact_arch = artifact_arch(platform.arch)
      archive_basename = "tailscale_#{version}_#{artifact_arch}"
      final_dir = Path.join([install_dir, version, artifact_arch])

      downloader =
        custom_downloader ||
          fn url, destination ->
            http_download(url, destination, timeout, cacertfile)
          end

      {:ok,
       %{
         archive_basename: archive_basename,
         archive_url: "#{base_url}/#{archive_basename}.tgz",
         checksum_url: "#{base_url}/#{archive_basename}.tgz.sha256",
         cli_path: Path.join(final_dir, "tailscale"),
         daemon_path: Path.join(final_dir, "tailscaled"),
         downloader: downloader,
         final_dir: final_dir,
         platform: platform,
         sha256: sha256,
         version: version
       }}
    end
  end

  defp ensure_installed_locked(config) do
    if installed?(config) do
      {:ok, installed_paths(config)}
    else
      install(config)
    end
  end

  defp install(config) do
    parent_dir = Path.dirname(config.final_dir)
    work_dir = Path.join(parent_dir, ".install-#{System.unique_integer([:positive])}")

    with :ok <- make_directory(parent_dir),
         {:ok, _removed} <- File.rm_rf(config.final_dir),
         :ok <- make_directory(work_dir) do
      try do
        download_and_install(config, work_dir)
      after
        File.rm_rf(work_dir)
      end
    end
  end

  defp download_and_install(config, work_dir) do
    archive_path = Path.join(work_dir, "archive.tgz")

    with {:ok, expected_checksum} <- expected_checksum(config, work_dir),
         :ok <- download(config, config.archive_url, archive_path),
         {:ok, actual_checksum} <- file_sha256(archive_path),
         :ok <- verify_checksum(expected_checksum, actual_checksum),
         {:ok, staged_dir} <- extract_binaries(config, archive_path, work_dir),
         :ok <- publish(staged_dir, config) do
      {:ok, installed_paths(config)}
    end
  end

  defp expected_checksum(%{sha256: checksum}, _work_dir) when is_binary(checksum) do
    {:ok, checksum}
  end

  defp expected_checksum(config, work_dir) do
    checksum_path = Path.join(work_dir, "archive.tgz.sha256")

    with :ok <- download(config, config.checksum_url, checksum_path),
         {:ok, contents} <- File.read(checksum_path),
         {:ok, checksum} <- parse_checksum(contents) do
      {:ok, checksum}
    else
      {:error, {:invalid_checksum, _value}} = error -> error
      {:error, reason} -> {:error, {:checksum_unavailable, reason}}
    end
  end

  defp download(config, url, destination) do
    case config.downloader.(url, destination) do
      :ok ->
        if File.regular?(destination) do
          :ok
        else
          {:error, {:download_failed, url, :file_not_created}}
        end

      {:error, reason} ->
        {:error, {:download_failed, url, reason}}

      other ->
        {:error, {:download_failed, url, {:invalid_downloader_result, other}}}
    end
  end

  defp extract_binaries(config, archive_path, work_dir) do
    extracted_dir = Path.join(work_dir, "extracted")
    archive_root = config.archive_basename
    source_dir = Path.join(extracted_dir, archive_root)
    staged_dir = Path.join(work_dir, "staged")
    archive_files = Enum.map(["tailscale", "tailscaled"], &Path.join(archive_root, &1))

    with :ok <- make_directory(source_dir),
         :ok <- extract_archive(archive_path, extracted_dir, archive_files),
         :ok <- make_directory(staged_dir),
         :ok <- stage_binary(Path.join(source_dir, "tailscale"), staged_dir),
         :ok <- stage_binary(Path.join(source_dir, "tailscaled"), staged_dir) do
      {:ok, staged_dir}
    end
  end

  defp extract_archive(archive_path, destination, files) do
    options = [
      :compressed,
      {:cwd, String.to_charlist(destination)},
      {:files, Enum.map(files, &String.to_charlist/1)}
    ]

    case :erl_tar.extract(String.to_charlist(archive_path), options) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_archive, reason}}
    end
  end

  defp stage_binary(source, staged_dir) do
    destination = Path.join(staged_dir, Path.basename(source))

    with true <- File.regular?(source),
         :ok <- File.cp(source, destination),
         :ok <- File.chmod(destination, 0o755) do
      :ok
    else
      false -> {:error, {:invalid_archive, {:missing_binary, Path.basename(source)}}}
      {:error, reason} -> {:error, {:install_failed, reason}}
    end
  end

  defp publish(staged_dir, config) do
    case File.rename(staged_dir, config.final_dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if installed?(config), do: :ok, else: {:error, {:install_failed, :eexist}}

      {:error, reason} ->
        {:error, {:install_failed, reason}}
    end
  end

  defp installed?(config) do
    executable?(config.cli_path) and executable?(config.daemon_path)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp installed_paths(config) do
    %{
      arch: config.platform.arch,
      cli_path: config.cli_path,
      daemon_path: config.daemon_path,
      version: config.version
    }
  end

  defp file_sha256(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          hash_device(device, :crypto.hash_init(:sha256))
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:checksum_failed, reason}}
    end
  end

  defp hash_device(device, context) do
    case IO.binread(device, @hash_chunk_size) do
      data when is_binary(data) -> hash_device(device, :crypto.hash_update(context, data))
      :eof -> {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, {:checksum_failed, reason}}
    end
  end

  defp verify_checksum(checksum, checksum), do: :ok

  defp verify_checksum(expected, actual) do
    {:error, {:checksum_mismatch, %{expected: expected, actual: actual}}}
  end

  defp fetch_version(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} when is_binary(version) ->
        if Regex.match?(@version_pattern, version) do
          {:ok, version}
        else
          {:error, {:invalid_version, version}}
        end

      {:ok, version} ->
        {:error, {:invalid_version, version}}

      :error ->
        {:error, {:missing_option, :version}}
    end
  end

  defp fetch_path(opts, key, default) do
    case Keyword.get(opts, key, default) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      path -> {:error, {:invalid_option, key, path}}
    end
  end

  defp fetch_optional_path(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      path -> {:error, {:invalid_option, key, path}}
    end
  end

  defp fetch_timeout(opts) do
    case Keyword.get(opts, :timeout, @default_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      timeout -> {:error, {:invalid_option, :timeout, timeout}}
    end
  end

  defp fetch_base_url(opts) do
    case opts |> Keyword.get(:base_url, @base_url) |> trim_base_url() do
      "https://" <> _rest = url -> {:ok, url}
      url -> {:error, {:invalid_option, :base_url, url}}
    end
  end

  defp trim_base_url(url) when is_binary(url), do: String.trim_trailing(url, "/")
  defp trim_base_url(url), do: url

  defp fetch_optional_checksum(opts) do
    case Keyword.get(opts, :sha256) do
      nil -> {:ok, nil}
      checksum when is_binary(checksum) -> parse_checksum(checksum)
      checksum -> {:error, {:invalid_checksum, checksum}}
    end
  end

  defp parse_checksum(contents) do
    checksum =
      contents
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> to_string()
      |> String.downcase()

    if Regex.match?(@sha256_pattern, checksum) do
      {:ok, checksum}
    else
      {:error, {:invalid_checksum, contents}}
    end
  end

  defp fetch_custom_downloader(opts) do
    case Keyword.get(opts, :download) do
      nil -> {:ok, nil}
      downloader when is_function(downloader, 2) -> {:ok, downloader}
      downloader -> {:error, {:invalid_option, :download, downloader}}
    end
  end

  defp artifact_arch(:i386), do: "386"
  defp artifact_arch(arch), do: Atom.to_string(arch)

  defp make_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:install_failed, reason}}
    end
  end

  defp http_download(url, destination, timeout, cacertfile) do
    with {:ok, _started} <- Application.ensure_all_started(:inets),
         {:ok, _started} <- Application.ensure_all_started(:ssl) do
      request = {String.to_charlist(url), []}
      http_options = [timeout: timeout, connect_timeout: timeout] ++ ssl_options(cacertfile)
      request_options = [stream: String.to_charlist(destination)]

      case :httpc.request(:get, request, http_options, request_options) do
        {:ok, :saved_to_file} ->
          :ok

        {:ok, {{_version, status, _reason}, _headers, body}} ->
          {:error, {:http_status, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ssl_options(nil), do: []

  defp ssl_options(cacertfile) do
    match_fun = :public_key.pkix_verify_hostname_match_fun(:https)

    [
      ssl: [
        verify: :verify_peer,
        cacertfile: String.to_charlist(cacertfile),
        customize_hostname_check: [match_fun: match_fun]
      ]
    ]
  end
end
