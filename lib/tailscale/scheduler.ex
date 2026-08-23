defmodule Tailscale.Scheduler do
  @moduledoc false

  @spec enqueue(:queue.queue(reference()), reference()) :: :queue.queue(reference())
  def enqueue(queue, id), do: :queue.in(id, queue)

  @spec delete(:queue.queue(reference()), reference()) :: :queue.queue(reference())
  def delete(queue, id) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == id))
    |> :queue.from_list()
  end

  @spec next(:queue.queue(reference()), map()) ::
          {:ok, reference(), :queue.queue(reference())} | :empty
  def next(queue, operations) do
    case :queue.out(queue) do
      {{:value, id}, remaining} ->
        if Map.has_key?(operations, id),
          do: {:ok, id, remaining},
          else: next(remaining, operations)

      {:empty, _queue} ->
        :empty
    end
  end

  @spec daemon_operation_ids(map()) :: [reference()]
  def daemon_operation_ids(operations) do
    operations
    |> Enum.filter(fn {_id, operation} -> operation.requires_daemon? end)
    |> Enum.map(&elem(&1, 0))
  end
end
