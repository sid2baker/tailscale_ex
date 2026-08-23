defmodule Tailscale.Config do
  @moduledoc false

  @default_daemon_path "/usr/sbin/tailscaled"
  @default_cli_path "/usr/bin/tailscale"
  @default_tailscale_dir "/data/tailscale"
  @default_socket_path "/run/tailscale/tailscaled.sock"
  @default_runtime_dir "/run/tailscale_ex"

  @allowed_options [
    :name,
    :daemon_path,
    :cli_path,
    :start_daemon,
    :tailscale_dir,
    :socket_path,
    :tun,
    :command_timeout,
    :status_interval,
    :runtime_dir,
    :daemon_log_level,
    :daemon_stdio_window,
    :daemon_restart_min,
    :daemon_restart_max,
    :daemon_restart_stable,
    :daemon_restart_jitter
  ]

  @enforce_keys [
    :name,
    :daemon_path,
    :cli_path,
    :start_daemon,
    :tailscale_dir,
    :socket_path,
    :tun,
    :command_timeout,
    :status_interval,
    :runtime_dir,
    :daemon_log_level,
    :daemon_stdio_window,
    :daemon_restart_min,
    :daemon_restart_max,
    :daemon_restart_stable,
    :daemon_restart_jitter
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: atom(),
          daemon_path: Path.t(),
          cli_path: Path.t(),
          start_daemon: boolean(),
          tailscale_dir: Path.t(),
          socket_path: Path.t(),
          tun: Tailscale.tun(),
          command_timeout: pos_integer(),
          status_interval: pos_integer(),
          runtime_dir: Path.t(),
          daemon_log_level: Logger.level() | false,
          daemon_stdio_window: pos_integer(),
          daemon_restart_min: pos_integer(),
          daemon_restart_max: pos_integer(),
          daemon_restart_stable: pos_integer(),
          daemon_restart_jitter: float()
        }

  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    with :ok <- validate_keyword(opts),
         config <- config(opts),
         :ok <- validate_config(config),
         :ok <- validate_filesystem(config) do
      {:ok, config}
    end
  end

  def build(_opts), do: {:error, :invalid_options}

  defp config(opts) do
    %__MODULE__{
      name: Keyword.get(opts, :name, Tailscale),
      daemon_path: Keyword.get(opts, :daemon_path, @default_daemon_path),
      cli_path: Keyword.get(opts, :cli_path, @default_cli_path),
      start_daemon: Keyword.get(opts, :start_daemon, true),
      tailscale_dir: Keyword.get(opts, :tailscale_dir, @default_tailscale_dir),
      socket_path: Keyword.get(opts, :socket_path, @default_socket_path),
      tun: Keyword.get(opts, :tun, :kernel),
      command_timeout: Keyword.get(opts, :command_timeout, 30_000),
      status_interval: Keyword.get(opts, :status_interval, 1_000),
      runtime_dir: Keyword.get(opts, :runtime_dir, @default_runtime_dir),
      daemon_log_level: Keyword.get(opts, :daemon_log_level, :info),
      daemon_stdio_window: Keyword.get(opts, :daemon_stdio_window, 10_240),
      daemon_restart_min: Keyword.get(opts, :daemon_restart_min, 100),
      daemon_restart_max: Keyword.get(opts, :daemon_restart_max, 10_000),
      daemon_restart_stable: Keyword.get(opts, :daemon_restart_stable, 30_000),
      daemon_restart_jitter: Keyword.get(opts, :daemon_restart_jitter, 0.2)
    }
  end

  defp validate_keyword(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      Keyword.keys(opts) -- @allowed_options != [] ->
        {:error, {:unknown_options, Keyword.keys(opts) -- @allowed_options}}

      duplicate_keys?(opts) ->
        {:error, :duplicate_options}

      true ->
        :ok
    end
  end

  defp duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp validate_config(config) do
    validators = [
      validate_name(config.name),
      validate_boolean(:start_daemon, config.start_daemon),
      validate_tun(config.tun),
      validate_path(:daemon_path, config.daemon_path),
      validate_path(:cli_path, config.cli_path),
      validate_path(:tailscale_dir, config.tailscale_dir),
      validate_path(:socket_path, config.socket_path),
      validate_path(:runtime_dir, config.runtime_dir),
      validate_positive(:command_timeout, config.command_timeout),
      validate_positive(:status_interval, config.status_interval),
      validate_positive(:daemon_stdio_window, config.daemon_stdio_window),
      validate_positive(:daemon_restart_min, config.daemon_restart_min),
      validate_positive(:daemon_restart_max, config.daemon_restart_max),
      validate_positive(:daemon_restart_stable, config.daemon_restart_stable),
      validate_log_level(config.daemon_log_level),
      validate_jitter(config.daemon_restart_jitter),
      validate_backoff(config)
    ]

    Enum.find(validators, :ok, &(&1 != :ok))
  end

  defp validate_filesystem(config) do
    with :ok <- validate_executable(config.cli_path),
         :ok <- validate_daemon(config) do
      ensure_directory(config.runtime_dir)
    end
  end

  defp validate_daemon(%{start_daemon: false}), do: :ok

  defp validate_daemon(config) do
    with :ok <- validate_executable(config.daemon_path),
         :ok <- ensure_directory(config.tailscale_dir) do
      ensure_directory(Path.dirname(config.socket_path))
    end
  end

  defp validate_executable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0, do: :ok, else: {:error, {:not_executable, path}}

      {:ok, _stat} ->
        {:error, {:not_regular_file, path}}

      {:error, reason} ->
        {:error, {:file_unavailable, path, reason}}
    end
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:directory_unavailable, path, reason}}
    end
  end

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(name), do: {:error, {:invalid_option, :name, name}}

  defp validate_boolean(_key, value) when is_boolean(value), do: :ok
  defp validate_boolean(key, value), do: {:error, {:invalid_option, key, value}}

  defp validate_tun(tun) when tun in [:kernel, :userspace], do: :ok
  defp validate_tun(tun) when is_binary(tun) and tun != "", do: :ok
  defp validate_tun(tun), do: {:error, {:invalid_option, :tun, tun}}

  defp validate_path(_key, value) when is_binary(value) and value != "", do: :ok
  defp validate_path(key, value), do: {:error, {:invalid_option, key, value}}

  defp validate_positive(_key, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(key, value), do: {:error, {:invalid_option, key, value}}

  defp validate_log_level(false), do: :ok
  defp validate_log_level(level) when level in [:debug, :info, :notice, :warning, :error], do: :ok
  defp validate_log_level(level), do: {:error, {:invalid_option, :daemon_log_level, level}}

  defp validate_jitter(value) when is_number(value) and value >= 0 and value <= 1, do: :ok
  defp validate_jitter(value), do: {:error, {:invalid_option, :daemon_restart_jitter, value}}

  defp validate_backoff(%{daemon_restart_min: min, daemon_restart_max: max}) when min <= max,
    do: :ok

  defp validate_backoff(_config), do: {:error, :invalid_restart_backoff}
end
