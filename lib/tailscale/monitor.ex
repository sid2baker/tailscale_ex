defmodule Tailscale.Monitor do
  @moduledoc false
  use GenServer

  alias Tailscale.{LocalAPI, Snapshot}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :monitor))

  def ready(server, timeout \\ 5_000),
    do: GenServer.call(server, {:ready, timeout}, timeout + 1_000)

  def auth(server, event), do: GenServer.call(server, {:auth, event})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.fetch!(opts, :table)

    state = %{
      opts: opts,
      table: table,
      worker: nil,
      ready: false,
      waiters: %{},
      snapshot: %Snapshot{},
      published:
        table
        |> PropertyTable.match([])
        |> Enum.reject(fn {path, _} -> hd(path) in ["configuration", "daemon", "monitor"] end)
        |> Map.new(),
      delay: Keyword.get(opts, :retry_min, 200),
      timer: nil,
      initial_timer: nil,
      url_timer: nil,
      generation: 0
    }

    # PropertyTable can outlive a crashed monitor; never leave its old snapshot online.
    state = unavailable(state, :connecting)
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:ready, _timeout}, _from, %{ready: true} = state), do: {:reply, :ok, state}

  def handle_call({:ready, timeout}, from, state) do
    ref = make_ref()
    timer = Process.send_after(self(), {:ready_timeout, ref}, timeout)
    {:noreply, %{state | waiters: Map.put(state.waiters, ref, {from, timer})}}
  end

  def handle_call({:notification, worker, notification}, _from, %{worker: worker} = state) do
    if supported?(notification["Version"]) do
      snapshot = Snapshot.update(state.snapshot, notification)
      initial = is_map(notification["InitialStatus"])
      state = %{state | snapshot: snapshot}
      state = if initial, do: connected(state), else: state
      state = if state.ready, do: publish(state), else: state

      if notification["Prefs"] || initial || notification["SelfChange"] || notification["State"],
        do: notify_controller(state)

      {:reply, :ok, state}
    else
      {:reply, {:error, :unsupported_version}, state}
    end
  end

  def handle_call({:notification, _worker, _notification}, _from, state),
    do: {:reply, {:error, :stale_stream}, state}

  def handle_call({:auth, event}, _from, state) do
    snapshot =
      case event do
        :starting -> %{state.snapshot | url: nil, error: nil, auth_attempt: true}
        :logged_out -> %Snapshot{backend: :needs_login, version: state.snapshot.version}
        {:url, url} -> Snapshot.update(state.snapshot, %{"BrowseToURL" => url})
        {:error, reason} -> %{state.snapshot | url: nil, error: reason, auth_attempt: false}
      end

    state = %{state | snapshot: snapshot}
    state = if state.ready, do: publish(state), else: publish_auth_error(state, event)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:connect, %{worker: nil} = state) do
    parent = self()
    opts = state.opts

    worker =
      spawn_link(fn -> send(parent, {:watch_ended, self(), LocalAPI.watch(opts, parent)}) end)

    timer =
      Process.send_after(
        self(),
        {:initial_timeout, worker},
        Keyword.get(opts, :initial_timeout, 10_000)
      )

    {:noreply, %{state | worker: worker, timer: nil, initial_timer: timer}}
  end

  def handle_info({:watch_ended, worker, {:error, reason}}, %{worker: worker} = state),
    do: {:noreply, disconnected(state, reason)}

  def handle_info({:EXIT, worker, _reason}, %{worker: worker} = state),
    do: {:noreply, disconnected(state, :disconnected)}

  def handle_info({:initial_timeout, worker}, %{worker: worker, ready: false} = state),
    do: {:noreply, disconnected(state, :snapshot_timeout)}

  def handle_info({:ready_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :unavailable})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:expire_url, url}, %{snapshot: %{url: url}} = state) do
    snapshot = %{state.snapshot | url: nil, error: :url_expired, auth_attempt: false}
    {:noreply, publish(%{state | snapshot: snapshot, url_timer: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.worker, do: Process.exit(state.worker, :kill)
  end

  defp connected(state) do
    cancel(state.initial_timer)
    generation = state.generation + 1

    PropertyTable.put_many(state.table, [
      {["monitor", "connected"], true},
      {["monitor", "generation"], generation}
    ])

    PropertyTable.delete(state.table, ["monitor", "error"])

    state =
      publish(%{
        state
        | ready: true,
          initial_timer: nil,
          generation: generation,
          delay: Keyword.get(state.opts, :retry_min, 200)
      })

    Enum.each(state.waiters, fn {_ref, {from, timer}} ->
      cancel(timer)
      GenServer.reply(from, :ok)
    end)

    %{state | waiters: %{}}
  end

  defp disconnected(state, reason) do
    if state.worker, do: Process.exit(state.worker, :kill)
    cancel(state.initial_timer)
    timer = Process.send_after(self(), :connect, state.delay)
    delay = min(state.delay * 2, Keyword.get(state.opts, :retry_max, 30_000))
    state = unavailable(state, reason)
    %{state | worker: nil, timer: timer, initial_timer: nil, delay: delay}
  end

  defp unavailable(state, reason) do
    cancel(state.url_timer)
    retained = [["state"], ["backend_state"], ["auth", "state"]]
    Enum.each(Map.keys(state.published) -- retained, &PropertyTable.delete(state.table, &1))

    PropertyTable.put_many(state.table, [
      {["state"], :unavailable},
      {["backend_state"], :unknown},
      {["auth", "state"], :unknown},
      {["monitor", "connected"], false},
      {["monitor", "error"], reason}
    ])

    notify_controller(state)
    %{state | ready: false, snapshot: %Snapshot{}, published: %{}, url_timer: nil}
  end

  defp publish(state) do
    properties = Snapshot.properties(state.snapshot)
    old_url = state.published[["auth", "url"]]
    new_url = properties[["auth", "url"]]

    state =
      if old_url != new_url do
        cancel(state.url_timer)

        timer =
          if new_url,
            do:
              Process.send_after(
                self(),
                {:expire_url, new_url},
                Keyword.get(state.opts, :auth_url_ttl, 600_000)
              )

        %{state | url_timer: timer}
      else
        state
      end

    removed = Map.keys(state.published) -- Map.keys(properties)
    Enum.each(removed, &PropertyTable.delete(state.table, &1))
    PropertyTable.put_many(state.table, Map.to_list(properties))
    %{state | published: properties}
  end

  defp publish_auth_error(state, {:error, reason}) do
    PropertyTable.put_many(state.table, [{["auth", "state"], :error}, {["auth", "error"], reason}])

    %{state | published: Map.put(state.published, ["auth", "error"], reason)}
  end

  defp publish_auth_error(state, _event), do: state

  defp notify_controller(state) do
    case Process.whereis(Keyword.fetch!(state.opts, :controller)) do
      nil -> :ok
      pid -> send(pid, :observed_change)
    end
  end

  defp supported?(nil), do: true

  defp supported?(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, version} ->
        version.major == 1 and {version.major, version.minor, version.patch} >= {1, 102, 3}

      _ ->
        false
    end
  end

  defp supported?(_), do: false
  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
