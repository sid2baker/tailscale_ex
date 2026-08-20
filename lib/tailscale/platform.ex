defmodule Tailscale.Platform do
  @moduledoc """
  Detects the Linux runtime ABI used to select a Tailscale binary archive.

  Detection uses the architecture of the running BEAM rather than the physical
  CPU. This ensures, for example, that a 32-bit Erlang runtime on a 64-bit ARM
  CPU receives the 32-bit ARM archive.
  """

  @type architecture ::
          :amd64
          | :arm64
          | :arm
          | :i386
          | :mips
          | :mips64
          | :mips64le
          | :mipsle
          | :riscv64

  @type t :: %__MODULE__{
          os: :linux,
          arch: architecture(),
          system_architecture: String.t()
        }

  @enforce_keys [:os, :arch, :system_architecture]
  defstruct [:os, :arch, :system_architecture]

  @doc """
  Detects the operating system and architecture of the running BEAM.

  Only Linux is supported.
  """
  @spec detect() :: {:ok, t()} | {:error, term()}
  def detect do
    detect(:os.type(), :erlang.system_info(:system_architecture))
  end

  @doc false
  @spec detect(term(), String.t() | charlist()) :: {:ok, t()} | {:error, term()}
  def detect({:unix, :linux}, system_architecture)
      when is_binary(system_architecture) or is_list(system_architecture) do
    system_architecture = to_string(system_architecture)

    case normalize_architecture(system_architecture) do
      {:ok, arch} ->
        {:ok,
         %__MODULE__{
           os: :linux,
           arch: arch,
           system_architecture: system_architecture
         }}

      :error ->
        {:error, {:unsupported_architecture, system_architecture}}
    end
  end

  def detect(os_type, _system_architecture) do
    {:error, {:unsupported_os, os_type}}
  end

  defp normalize_architecture(system_architecture) do
    system_architecture
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
    |> normalize_architecture_token()
  end

  defp normalize_architecture_token(token) when token in ["x86_64", "amd64"], do: {:ok, :amd64}
  defp normalize_architecture_token(token) when token in ["aarch64", "arm64"], do: {:ok, :arm64}
  defp normalize_architecture_token("riscv64"), do: {:ok, :riscv64}

  defp normalize_architecture_token(token) do
    cond do
      Regex.match?(~r/^i[3-6]86$/, token) -> {:ok, :i386}
      String.starts_with?(token, "arm") -> {:ok, :arm}
      String.starts_with?(token, "mips64") -> {:ok, mips_architecture(token, :mips64, :mips64le)}
      String.starts_with?(token, "mips") -> {:ok, mips_architecture(token, :mips, :mipsle)}
      true -> :error
    end
  end

  defp mips_architecture(token, big_endian, little_endian) do
    if String.ends_with?(token, ["el", "le"]), do: little_endian, else: big_endian
  end
end
