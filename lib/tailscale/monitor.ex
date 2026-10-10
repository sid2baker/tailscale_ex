defmodule Tailscale.Monitor do
  @moduledoc false
  @behaviour :gen_statem

  alias Tailscale.{LocalAPI, Snapshot}

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: :gen_statem.start_link({:local, Keyword.fetch!(opts, :monitor)}, __MODULE__, opts, [])

  def ready(server, timeout \\ 5_000),
    do: :gen_statem.call(server, {:ready, timeout}, timeout + 1_000)

  def auth(server, event), do: :gen_statem.call(server, {:auth, event}, 5_000)

  def await_login(server, timeout),
    do: :gen_statem.call(server, {:await_login, timeout}, :infinity)

  # backoff -> connecting -> ready; failures return to backoff.
  # These are observer states, not tailscaled's backend/authentication states.
  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.fetch!(opts, :table)

    data = %{
      opts: opts,
      table: table,
      worker: nil,
      waiters: %{},
      login_waiters: %{},
      snapshot: %Snapshot{},
      published:
        table
        |> PropertyTable.match([])
        |> Enum.reject(fn {path, _} -> hd(path) in ["configuration", "daemon", "monitor"] end)
        |> Map.new(),
      delay: Keyword.get(opts, :retry_min, 200),
      generation: 0
    }

    # PropertyTable can outlive a crashed monitor; never leave its old snapshot online.
    {data, actions} = unavailable(data, :connecting)
    {:ok, :backoff, data, [{:next_event, :internal, :connect} | actions]}
  end

  @impl true
  def handle_event({:call, from}, {:ready, _timeout}, :ready, _data),
    do: {:keep_state_and_data, [{:reply, from, :ok}]}

  def handle_event({:call, from}, {:ready, timeout}, _phase, data) do
    ref = make_ref()
    data = %{data | waiters: Map.put(data.waiters, ref, from)}
    {:keep_state, data, [{{:timeout, {:ready, ref}}, timeout, :expired}]}
  end

  def handle_event({:call, from}, {:await_login, timeout}, phase, data) do
    case login_result(phase, data.snapshot) do
      :pending ->
        ref = make_ref()
        data = %{data | login_waiters: Map.put(data.login_waiters, ref, from)}
        {:keep_state, data, [{{:timeout, {:login, ref}}, timeout, :expired}]}

      result ->
        {:keep_state_and_data, [{:reply, from, result}]}
    end
  end

  def handle_event(
        {:call, from},
        {:notification, worker, notification},
        phase,
        %{worker: worker} = data
      ) do
    if supported?(notification["Version"]) do
      initial = is_map(notification["InitialStatus"])
      data = %{data | snapshot: Snapshot.update(data.snapshot, notification)}

      {data, actions} =
        cond do
          initial -> connected(data)
          phase == :ready -> publish(data)
          true -> {data, []}
        end

      if initial or Enum.any?(["Prefs", "SelfChange", "State"], &notification[&1]),
        do: notify_controller(data)

      {:next_state, if(initial, do: :ready, else: phase), data, [{:reply, from, :ok} | actions]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :unsupported_version}}]}
    end
  end

  def handle_event({:call, from}, {:notification, _worker, _notification}, _phase, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :stale_stream}}]}

  def handle_event({:call, from}, {:auth, event}, phase, data) do
    snapshot =
      case event do
        :starting -> %{data.snapshot | url: nil, error: nil, auth_attempt: true}
        :logged_out -> %Snapshot{backend: :needs_login, version: data.snapshot.version}
        {:url, url} -> Snapshot.update(data.snapshot, %{"BrowseToURL" => url})
        {:error, reason} -> %{data.snapshot | url: nil, error: reason, auth_attempt: false}
      end

    data = %{data | snapshot: snapshot}

    {data, actions} =
      if phase == :ready,
        do: publish(data),
        else: data |> publish_auth_error(event) |> resolve_login(login_result(phase, snapshot))

    {:keep_state, data, [{:reply, from, :ok} | actions]}
  end

  def handle_event(:internal, :connect, :backoff, data), do: connect(data)
  def handle_event(:state_timeout, :connect, :backoff, data), do: connect(data)

  def handle_event(:state_timeout, :initial_snapshot, :connecting, data),
    do: disconnected(data, :snapshot_timeout)

  def handle_event(
        :info,
        {:watch_ended, worker, {:error, reason}},
        _phase,
        %{worker: worker} = data
      ),
      do: disconnected(data, reason)

  def handle_event(:info, {:EXIT, worker, _reason}, _phase, %{worker: worker} = data),
    do: disconnected(data, :disconnected)

  def handle_event({:timeout, {:ready, ref}}, :expired, _phase, data) do
    case Map.pop(data.waiters, ref) do
      {nil, _} ->
        :keep_state_and_data

      {from, waiters} ->
        {:keep_state, %{data | waiters: waiters}, [{:reply, from, {:error, :unavailable}}]}
    end
  end

  def handle_event({:timeout, {:login, ref}}, :expired, _phase, data) do
    case Map.pop(data.login_waiters, ref) do
      {nil, _} ->
        :keep_state_and_data

      {from, waiters} ->
        {:keep_state, %{data | login_waiters: waiters}, [{:reply, from, {:error, :timeout}}]}
    end
  end

  def handle_event({:timeout, :auth_url}, :expired, :ready, data) do
    snapshot = %{data.snapshot | url: nil, error: :url_expired, auth_attempt: false}
    {data, actions} = publish(%{data | snapshot: snapshot})
    {:keep_state, data, actions}
  end

  def handle_event(:info, _message, _phase, _data), do: :keep_state_and_data

  # OTP diagnostics must not expose enrollment URLs or raw daemon notifications.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, phase} -> {:state, phase}
      {key, _value} when key in [:queue, :postponed, :timeouts, :log] -> {key, []}
      {key, _value} -> {key, :redacted}
    end)
  end

  @impl true
  def terminate(_reason, _phase, data) do
    if data.worker, do: Process.exit(data.worker, :kill)
  end

  defp connect(data) do
    parent = self()
    opts = data.opts

    worker =
      spawn_link(fn -> send(parent, {:watch_ended, self(), LocalAPI.watch(opts, parent)}) end)

    timeout = Keyword.get(opts, :initial_timeout, 10_000)

    {:next_state, :connecting, %{data | worker: worker},
     [{:state_timeout, timeout, :initial_snapshot}]}
  end

  defp connected(data) do
    generation = data.generation + 1

    PropertyTable.put_many(data.table, [
      {["monitor", "connected"], true},
      {["monitor", "generation"], generation}
    ])

    PropertyTable.delete(data.table, ["monitor", "error"])

    {data, actions} =
      publish(%{
        data
        | generation: generation,
          delay: Keyword.get(data.opts, :retry_min, 200)
      })

    replies = waiter_replies(data.waiters, :ready, :ok)
    {%{data | waiters: %{}}, actions ++ replies}
  end

  defp disconnected(data, reason) do
    if data.worker, do: Process.exit(data.worker, :kill)
    delay = data.delay
    {data, actions} = unavailable(data, reason)

    data = %{
      data
      | worker: nil,
        delay: min(delay * 2, Keyword.get(data.opts, :retry_max, 30_000))
    }

    {:next_state, :backoff, data, [{:state_timeout, delay, :connect} | actions]}
  end

  defp unavailable(data, reason) do
    retained = [["state"], ["backend_state"], ["auth", "state"]]
    Enum.each(Map.keys(data.published) -- retained, &PropertyTable.delete(data.table, &1))

    PropertyTable.put_many(data.table, [
      {["state"], :unavailable},
      {["backend_state"], :unknown},
      {["auth", "state"], :unknown},
      {["monitor", "connected"], false},
      {["monitor", "error"], reason}
    ])

    notify_controller(data)

    {data, actions} =
      resolve_login(%{data | snapshot: %Snapshot{}, published: %{}}, {:error, reason})

    {data, [{{:timeout, :auth_url}, :cancel} | actions]}
  end

  defp publish(data) do
    properties = Snapshot.properties(data.snapshot)
    old_url = data.published[["auth", "url"]]
    new_url = properties[["auth", "url"]]

    actions =
      cond do
        old_url == new_url ->
          []

        is_nil(new_url) ->
          [{{:timeout, :auth_url}, :cancel}]

        true ->
          [{{:timeout, :auth_url}, Keyword.get(data.opts, :auth_url_ttl, 600_000), :expired}]
      end

    removed = Map.keys(data.published) -- Map.keys(properties)
    Enum.each(removed, &PropertyTable.delete(data.table, &1))
    PropertyTable.put_many(data.table, Map.to_list(properties))

    {data, replies} =
      resolve_login(%{data | published: properties}, login_result(:ready, data.snapshot))

    {data, actions ++ replies}
  end

  defp login_result(phase, _snapshot) when phase != :ready, do: {:error, :disconnected}
  defp login_result(:ready, %{error: error}) when not is_nil(error), do: {:error, error}
  defp login_result(:ready, %{backend: :running}), do: :ok
  defp login_result(:ready, %{backend: :needs_machine_auth}), do: {:error, :needs_approval}
  defp login_result(:ready, %{url: url}) when is_binary(url), do: {:ok, url}
  defp login_result(:ready, %{backend: :stopped, auth_attempt: false}), do: {:error, :stopped}
  defp login_result(:ready, %{auth_attempt: false}), do: {:error, :logged_out}
  defp login_result(:ready, _snapshot), do: :pending

  defp resolve_login(data, :pending), do: {data, []}

  defp resolve_login(data, result),
    do: {%{data | login_waiters: %{}}, waiter_replies(data.login_waiters, :login, result)}

  defp waiter_replies(waiters, kind, result) do
    Enum.flat_map(waiters, fn {ref, from} ->
      [{{:timeout, {kind, ref}}, :cancel}, {:reply, from, result}]
    end)
  end

  defp publish_auth_error(data, {:error, reason}) do
    PropertyTable.put_many(data.table, [{["auth", "state"], :error}, {["auth", "error"], reason}])

    %{data | published: Map.put(data.published, ["auth", "error"], reason)}
  end

  defp publish_auth_error(data, _event), do: data

  defp notify_controller(data) do
    case Process.whereis(Keyword.fetch!(data.opts, :controller)) do
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
end
