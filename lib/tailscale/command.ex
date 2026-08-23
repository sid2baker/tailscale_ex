defmodule Tailscale.Command do
  @moduledoc false

  alias Tailscale.CommandError
  alias Tailscale.Telemetry

  @type result :: {:ok, String.t() | map() | list()} | {:error, CommandError.t()}

  @spec run(map(), atom(), :read | :mutation, String.t(), [String.t()], pos_integer()) :: result()
  def run(config, operation, mode, command, args, timeout) do
    started_at = System.monotonic_time()
    metadata = %{instance: config.name, operation: operation}
    Telemetry.execute([:command, :start], %{system_time: System.system_time()}, metadata)
    execute_and_report(config, mode, command, args, timeout, started_at, metadata)
  end

  defp execute_and_report(config, mode, command, args, timeout, started_at, metadata) do
    result = execute_with_retry(config, mode, command, args, timeout, metadata)
    duration = System.monotonic_time() - started_at
    outcome = if match?({:ok, _value}, result), do: :ok, else: :error

    Telemetry.execute(
      [:command, :stop],
      %{duration: duration},
      Map.put(metadata, :outcome, outcome)
    )

    result
  rescue
    exception ->
      duration = System.monotonic_time() - started_at

      Telemetry.execute(
        [:command, :exception],
        %{duration: duration},
        Map.merge(metadata, %{kind: :error, reason: exception.__struct__})
      )

      reraise exception, __STACKTRACE__
  end

  defp execute_with_retry(config, mode, command, args, timeout, metadata) do
    case safe_execute(config, command, args, timeout) do
      {:transport_error, reason} when mode == :read ->
        Telemetry.execute(
          [:command, :exception],
          %{system_time: System.system_time()},
          Map.merge(metadata, %{kind: :transport, reason: reason, retry: true})
        )

        safe_execute(config, command, args, timeout)
        |> normalize_transport_error(command, metadata)

      result ->
        normalize_transport_error(result, command, metadata)
    end
  end

  defp safe_execute(config, command, args, timeout) do
    execute(config, command, args, timeout)
  rescue
    exception -> {:transport_error, sanitized_exception(exception)}
  catch
    :exit, reason -> {:transport_error, sanitized_reason(reason)}
  end

  defp normalize_transport_error({:transport_error, reason}, command, metadata) do
    Telemetry.execute(
      [:command, :exception],
      %{system_time: System.system_time()},
      Map.merge(metadata, %{kind: :exit, reason: reason, retry: false})
    )

    {:error,
     %CommandError{
       command: command,
       exit_code: nil,
       output: "command transport failed: #{reason}",
       reason: :task_exit
     }}
  end

  defp normalize_transport_error(result, _command, _metadata), do: result

  defp execute(config, command, args, timeout) do
    arguments = ["--socket=#{config.socket_path}", command] ++ args
    options = [stderr_to_stdout: true, timeout: timeout]
    redactions = secret_values(command, args)

    case MuonTrap.cmd(config.cli_path, arguments, options) do
      {output, 0} ->
        {:ok, output |> redact(redactions) |> decode()}

      {output, :timeout} ->
        {:error, command_error(command, :timeout, nil, redact(output, redactions))}

      {output, exit_code} ->
        {:error, command_error(command, :exit_status, exit_code, redact(output, redactions))}
    end
  end

  defp decode(output) do
    trimmed = String.trim(output)

    case JSON.decode(trimmed) do
      {:ok, decoded} -> decoded
      _error -> trimmed
    end
  end

  defp command_error(command, reason, exit_code, output) do
    %CommandError{
      command: command,
      reason: reason,
      exit_code: exit_code,
      output: String.trim(output)
    }
  end

  defp secret_values("login", args) do
    args
    |> Enum.filter(&String.starts_with?(&1, "--auth-key=file:"))
    |> Enum.flat_map(fn argument ->
      path = String.replace_prefix(argument, "--auth-key=file:", "")

      case File.read(path) do
        {:ok, secret} -> [secret]
        {:error, _reason} -> []
      end
    end)
  end

  defp secret_values(_command, _args), do: []

  defp redact(output, secrets) do
    Enum.reduce(secrets, output, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp sanitized_exception(exception), do: exception.__struct__

  defp sanitized_reason(reason) when reason in [:epipe, :econnreset, :closed], do: reason
  defp sanitized_reason(_reason), do: :command_task_failed
end
