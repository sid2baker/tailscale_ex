defmodule Tailscale.LocalAPI do
  @moduledoc false

  alias Tailscale.LocalAPI.Frames

  # InitialState | InitialPrefs | InitialHealthState | PeerChanges | NoNetMap | InitialStatus
  @watch_mask 28_806
  @prefix "/localapi/v0/"

  def request(opts, method, endpoint, body \\ nil, headers \\ []) do
    deadline = now() + Keyword.get(opts, :timeout, 5_000)

    with {:ok, conn} <- connect(opts) do
      try do
        payload = if is_nil(body), do: nil, else: JSON.encode!(body)

        headers = [
          {"host", "local-tailscaled.sock"},
          {"content-type", "application/json"} | headers
        ]

        case Mint.HTTP.request(conn, method, @prefix <> endpoint, headers, payload) do
          {:ok, conn, ref} -> receive_response(conn, ref, deadline, opts, {nil, [], [], 0})
          {:error, _conn, _reason} -> {:error, :transport}
        end
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # Run in a linked worker. Synchronous delivery gives the stream consumer backpressure.
  def watch(opts, consumer) do
    with {:ok, conn} <- connect(opts) do
      try do
        case Mint.HTTP.request(
               conn,
               "GET",
               @prefix <> "watch-ipn-bus?mask=#{@watch_mask}",
               [{"host", "local-tailscaled.sock"}],
               nil
             ) do
          {:ok, conn, ref} ->
            parser = %Frames{limit: Keyword.get(opts, :max_frame, 4_194_304)}
            watch_loop(conn, ref, consumer, parser, false)

          {:error, _conn, _reason} ->
            {:error, :transport}
        end
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp connect(opts) do
    socket = Keyword.fetch!(opts, :socket)

    case Mint.HTTP.connect(:http, {:local, String.to_charlist(socket)}, 0,
           hostname: "local-tailscaled.sock",
           protocols: [:http1],
           mode: :passive,
           max_header_list_size: 16_384,
           transport_opts: [timeout: Keyword.get(opts, :timeout, 5_000)]
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp receive_response(conn, ref, deadline, opts, acc) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive_result(Mint.HTTP.recv(conn, 0, remaining), ref, deadline, opts, acc)
    end
  end

  defp receive_result({:ok, conn, responses}, ref, deadline, opts, acc) do
    case collect(responses, ref, acc, Keyword.get(opts, :max_body, 4_194_304)) do
      {:more, acc} -> receive_response(conn, ref, deadline, opts, acc)
      result -> result
    end
  end

  defp receive_result({:error, _conn, reason, responses}, ref, _deadline, opts, acc) do
    # Mint can finish a response before encountering a connection/protocol error.
    case collect(responses, ref, acc, Keyword.get(opts, :max_body, 4_194_304)) do
      {:more, _acc} -> request_error(reason)
      result -> result
    end
  end

  defp request_error(%Mint.TransportError{reason: :timeout}), do: {:error, :timeout}
  defp request_error(_reason), do: {:error, :transport}

  defp collect([], _ref, acc, _limit), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, {_, headers, body, size}, limit),
    do: collect(rest, ref, {status, headers, body, size}, limit)

  defp collect([{:headers, ref, headers} | rest], ref, {status, old, body, size}, limit),
    do: collect(rest, ref, {status, old ++ headers, body, size}, limit)

  defp collect([{:data, ref, data} | rest], ref, {status, headers, body, size}, limit) do
    if size + byte_size(data) > limit do
      {:error, :response_too_large}
    else
      collect(rest, ref, {status, headers, [data | body], size + byte_size(data)}, limit)
    end
  end

  defp collect([{:done, ref} | _], ref, {status, headers, body, _}, _limit) do
    if status in 200..299 do
      decode_response(body, headers)
    else
      # Never return daemon error bodies: they can reflect credentials.
      {:error, {:http, status}}
    end
  end

  defp collect([{:error, ref, reason} | _], ref, _acc, _limit), do: request_error(reason)

  defp collect([_ | rest], ref, acc, limit), do: collect(rest, ref, acc, limit)

  defp decode_response(body, headers) do
    case body |> Enum.reverse() |> IO.iodata_to_binary() do
      "" ->
        {:ok, nil, headers}

      data ->
        case JSON.decode(data) do
          {:ok, value} -> {:ok, value, headers}
          _ -> {:error, :invalid_response}
        end
    end
  end

  # Established streams have no idle deadline; Monitor bounds initial readiness
  # and owns cancellation. Silence alone is not a reason to reconnect.
  defp watch_loop(conn, ref, consumer, parser, accepted) do
    case Mint.HTTP.recv(conn, 0, :infinity) do
      {:ok, conn, responses} ->
        case notifications(responses, ref, consumer, parser, accepted) do
          {:ok, parser, accepted} -> watch_loop(conn, ref, consumer, parser, accepted)
          error -> error
        end

      {:error, _conn, _reason, responses} ->
        # Deliver anything Mint parsed before the failure, then disconnect.
        case notifications(responses, ref, consumer, parser, accepted) do
          {:ok, _parser, _accepted} -> {:error, :disconnected}
          error -> error
        end
    end
  end

  defp notifications([], _ref, _consumer, parser, accepted), do: {:ok, parser, accepted}

  defp notifications([{:status, ref, 200} | rest], ref, consumer, parser, _accepted),
    do: notifications(rest, ref, consumer, parser, true)

  defp notifications([{:status, ref, status} | _], ref, _consumer, _parser, _accepted),
    do: {:error, {:http, status}}

  defp notifications([{:data, ref, data} | rest], ref, consumer, parser, true) do
    with {:ok, parser, frames} <- Frames.feed(parser, data),
         :ok <- deliver(frames, consumer) do
      notifications(rest, ref, consumer, parser, true)
    end
  end

  defp notifications([{:done, ref} | _], ref, _consumer, _parser, _accepted),
    do: {:error, :disconnected}

  defp notifications([{:error, ref, _reason} | _], ref, _consumer, _parser, _accepted),
    do: {:error, :disconnected}

  defp notifications([_ | rest], ref, consumer, parser, accepted),
    do: notifications(rest, ref, consumer, parser, accepted)

  defp deliver(frames, consumer) do
    Enum.reduce_while(frames, :ok, fn frame, :ok ->
      case :gen_statem.call(consumer, {:notification, self(), frame}, :infinity) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
