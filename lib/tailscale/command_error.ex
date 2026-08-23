defmodule Tailscale.CommandError do
  @moduledoc """
  Describes a failed invocation of the Tailscale CLI.

  Arguments are intentionally omitted because commands such as `login` can
  contain credentials.
  """

  @type reason :: :exit_status | :timeout | :task_exit

  @type t :: %__MODULE__{
          command: String.t(),
          exit_code: non_neg_integer() | nil,
          output: String.t(),
          reason: reason()
        }

  @enforce_keys [:command, :output, :reason]
  defexception [:command, :exit_code, :output, :reason]

  @impl true
  def message(%__MODULE__{command: command, reason: :timeout, output: output}) do
    append_output("tailscale #{command} timed out", output)
  end

  def message(%__MODULE__{command: command, reason: :task_exit, output: output}) do
    append_output("tailscale #{command} command task exited", output)
  end

  def message(%__MODULE__{
        command: command,
        reason: :exit_status,
        exit_code: exit_code,
        output: output
      }) do
    append_output("tailscale #{command} exited with status #{exit_code}", output)
  end

  defp append_output(message, ""), do: message
  defp append_output(message, output), do: "#{message}: #{output}"
end
