defmodule Tailscale.SecretFile do
  @moduledoc false

  alias Tailscale.Naming

  @type context :: %{required(:directory) => Path.t()}
  @type t :: %{required(:directory) => Path.t(), required(:path) => Path.t()}

  @spec context(Path.t(), atom()) :: {:ok, context()} | {:error, term()}
  def context(runtime_dir, instance) do
    directory = Path.join(runtime_dir, Naming.instance_id(instance))

    with :ok <- secure_directory(runtime_dir, 0o755),
         :ok <- secure_directory(directory, 0o700) do
      {:ok, %{directory: directory}}
    end
  end

  @spec cleanup_abandoned(context()) :: :ok
  def cleanup_abandoned(%{directory: directory}) do
    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "login-"))
        |> Enum.each(&File.rm_rf(Path.join(directory, &1)))

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  @spec create(context(), String.t()) :: {:ok, t()} | {:error, term()}
  def create(context, auth_key) when is_binary(auth_key) and auth_key != "" do
    with {:ok, directory} <- create_random_directory(context.directory, 5) do
      write_secret(directory, auth_key)
    end
  end

  def create(_context, _auth_key), do: {:error, :invalid_auth_key}

  @spec cleanup(t() | nil) :: :ok
  def cleanup(nil), do: :ok

  def cleanup(%{directory: directory}) do
    File.rm_rf(directory)
    :ok
  end

  defp create_random_directory(_parent, 0), do: {:error, :secret_directory_collision}

  defp create_random_directory(parent, attempts) do
    random = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    directory = Path.join(parent, "login-#{random}")

    case File.mkdir(directory) do
      :ok ->
        case File.chmod(directory, 0o700) do
          :ok -> {:ok, directory}
          {:error, reason} -> cleanup_error(directory, {:secret_directory_unavailable, reason})
        end

      {:error, :eexist} ->
        create_random_directory(parent, attempts - 1)

      {:error, reason} ->
        {:error, {:secret_directory_unavailable, reason}}
    end
  end

  defp write_secret(directory, auth_key) do
    path = Path.join(directory, "auth-key")

    result =
      File.open(path, [:write, :binary, :exclusive], fn device ->
        IO.binwrite(device, auth_key)
      end)

    case result do
      {:ok, :ok} ->
        case File.chmod(path, 0o600) do
          :ok -> {:ok, %{directory: directory, path: path}}
          {:error, reason} -> cleanup_error(directory, {:secret_file_unavailable, reason})
        end

      {:ok, {:error, reason}} ->
        cleanup_error(directory, {:secret_file_unavailable, reason})

      {:error, reason} ->
        cleanup_error(directory, {:secret_file_unavailable, reason})
    end
  end

  defp cleanup_error(directory, error) do
    File.rm_rf(directory)
    {:error, error}
  end

  defp secure_directory(path, mode) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> File.chmod(path, mode)
      {:ok, _stat} -> {:error, {:unsafe_runtime_path, path}}
      {:error, :enoent} -> create_secure_directory(path, mode)
      {:error, reason} -> {:error, {:runtime_directory_unavailable, path, reason}}
    end
  end

  defp create_secure_directory(path, mode) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok -> File.chmod(path, mode)
        {:error, :eexist} -> secure_directory(path, mode)
        {:error, reason} -> {:error, {:runtime_directory_unavailable, path, reason}}
      end
    end
  end
end
