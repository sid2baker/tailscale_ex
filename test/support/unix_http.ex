defmodule Tailscale.Test.UnixHTTP do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def socket(server), do: GenServer.call(server, :socket)
  def state(server), do: GenServer.call(server, :state)
  def notify(server, frame), do: GenServer.call(server, {:notify, frame})
  def disconnect(server), do: GenServer.call(server, :disconnect)
  def update(server, fun), do: GenServer.call(server, {:update, fun})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    path =
      Keyword.get(
        opts,
        :socket,
        Path.join(System.tmp_dir!(), "tsx-#{System.unique_integer([:positive])}.sock")
      )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
    parent = self()
    acceptor = spawn_link(fn -> accept(listener, parent) end)

    {:ok,
     %{
       socket: path,
       listener: listener,
       acceptor: acceptor,
       handler: Keyword.fetch!(opts, :handler),
       data: Keyword.get(opts, :state, %{}),
       watchers: [],
       connections: []
     }}
  end

  @impl true
  def handle_call(:socket, _from, state), do: {:reply, state.socket, state}
  def handle_call(:state, _from, state), do: {:reply, state.data, state}

  def handle_call({:update, fun}, _from, state),
    do: {:reply, :ok, %{state | data: fun.(state.data)}}

  def handle_call({:notify, frame}, _from, state) do
    Enum.each(state.watchers, &send(&1, {:frame, frame}))
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    Enum.each(state.watchers, &send(&1, :close))
    {:reply, :ok, %{state | watchers: []}}
  end

  def handle_call({:request, worker, request}, _from, state) do
    {response, data} = state.handler.(request, state.data)

    watchers =
      if match?({:watch, _}, response), do: [worker | state.watchers], else: state.watchers

    {:reply, response, %{state | data: data, watchers: watchers}}
  end

  @impl true
  def handle_info({:connection, pid}, state),
    do: {:noreply, %{state | connections: [pid | state.connections]}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    Enum.each(state.connections, &Process.exit(&1, :kill))
    Process.exit(state.acceptor, :kill)
    File.rm(state.socket)
  end

  defp accept(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker =
          spawn(fn ->
            receive do
              {:socket, socket} -> serve(socket, parent)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        send(parent, {:connection, worker})
        accept(listener, parent)

      _ ->
        :ok
    end
  end

  defp serve(socket, parent) do
    with {:ok, request} <- read_request(socket, "") do
      response = GenServer.call(parent, {:request, self(), request})
      respond(socket, response)
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_request(socket, data) do
    case :binary.split(data, "\r\n\r\n") do
      [head, rest] ->
        [line | headers] = String.split(head, "\r\n")
        [method, path, _] = String.split(line, " ")

        headers =
          Map.new(headers, fn header ->
            [name, value] = String.split(header, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        length = String.to_integer(headers["content-length"] || "0")

        with {:ok, body} <- read_body(socket, rest, length),
             do: {:ok, %{method: method, path: path, headers: headers, body: body}}

      [_] ->
        with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 5_000),
             do: read_request(socket, data <> chunk)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length,
    do: {:ok, binary_part(body, 0, length)}

  defp read_body(socket, body, length) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 5_000),
         do: read_body(socket, body <> chunk, length)
  end

  defp respond(socket, {:json, status, body, headers}) do
    data = if body == :empty, do: "", else: JSON.encode!(body)
    headers = Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} OK\r\ncontent-length: #{byte_size(data)}\r\n",
      headers,
      "\r\n",
      data
    ])
  end

  defp respond(socket, {:raw, chunks}) do
    Enum.each(chunks, fn
      delay when is_integer(delay) -> Process.sleep(delay)
      chunk -> :gen_tcp.send(socket, chunk)
    end)
  end

  defp respond(socket, {:watch, initial}) do
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
    if initial, do: send_frame(socket, initial)
    watch(socket)
  end

  defp watch(socket) do
    receive do
      {:frame, frame} ->
        case send_frame(socket, frame) do
          :ok -> watch(socket)
          _ -> :ok
        end

      :close ->
        :ok
    after
      30_000 -> :ok
    end
  end

  defp send_frame(socket, frame) do
    body = JSON.encode!(frame) <> "\n"
    :gen_tcp.send(socket, [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n"])
  end
end
