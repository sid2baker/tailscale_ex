defmodule Tailscale.Call do
  @moduledoc false

  @spec operation(GenServer.server(), map(), timeout()) :: term()
  def operation(server, specification, timeout \\ :infinity) do
    id = make_ref()
    envelope_timeout = if timeout == :infinity, do: :infinity, else: timeout + 250

    try do
      GenServer.call(server, {:operation, id, specification}, envelope_timeout)
    catch
      :exit, reason ->
        safe_cancel(server, id)
        unavailable(reason)
    end
  end

  @spec deferred(GenServer.server(), (reference() -> term()), pos_integer()) :: term()
  def deferred(server, message_builder, timeout) do
    id = make_ref()

    try do
      GenServer.call(server, message_builder.(id), timeout + 250)
    catch
      :exit, reason ->
        safe_cancel(server, id)
        unavailable(reason)
    end
  end

  @spec call(GenServer.server(), term(), timeout()) :: term()
  def call(server, message, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, reason -> unavailable(reason)
  end

  @spec cast(GenServer.server(), term()) :: :ok | {:error, :server_unavailable}
  def cast(server, message) do
    GenServer.cast(server, message)
    :ok
  catch
    :exit, _reason -> {:error, :server_unavailable}
    :error, _reason -> {:error, :server_unavailable}
  end

  defp safe_cancel(server, id) do
    cast(server, {:cancel_operation, id})
    :ok
  end

  defp unavailable(_reason), do: {:error, :server_unavailable}
end
