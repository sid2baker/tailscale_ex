defmodule Tailscale.LocalAPI.Frames do
  @moduledoc false

  # The limit applies to each frame, not to a socket chunk (which can contain many).
  defstruct buffer: "", limit: 4_194_304

  def feed(%__MODULE__{} = state, chunk) do
    split(state.buffer <> chunk, %{state | buffer: ""}, [])
  end

  defp split(data, state, acc) do
    case :binary.match(data, "\n") do
      {index, 1} when index <= state.limit ->
        <<frame::binary-size(^index), _newline, rest::binary>> = data

        case decode(frame) do
          :empty -> split(rest, state, acc)
          {:ok, value} -> split(rest, state, [value | acc])
          error -> error
        end

      :nomatch when byte_size(data) <= state.limit ->
        {:ok, %{state | buffer: :binary.copy(data)}, Enum.reverse(acc)}

      _ ->
        {:error, :frame_too_large}
    end
  end

  defp decode(frame) do
    if String.trim(frame) == "" do
      :empty
    else
      case JSON.decode(frame) do
        {:ok, value} when is_map(value) -> {:ok, value}
        _ -> {:error, :invalid_notification}
      end
    end
  end
end
