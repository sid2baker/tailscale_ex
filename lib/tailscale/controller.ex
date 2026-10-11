defmodule Tailscale.Controller do
  @moduledoc false
  use GenServer

  alias Tailscale.{Configuration, LocalAPI, Monitor, Serve}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :controller))

  def configure(server, config), do: GenServer.call(server, {:configure, config}, :infinity)

  def update_configuration(server, changes),
    do: GenServer.call(server, {:update_configuration, changes}, :infinity)

  def reset(server), do: GenServer.call(server, :reset, :infinity)

  def set_running(server, running) when is_boolean(running),
    do: GenServer.call(server, {:set_running, running}, :infinity)

  def login(server, mode), do: GenServer.call(server, {:login, mode}, :infinity)
  def logout(server), do: GenServer.call(server, :logout, :infinity)

  @impl true
  def init(opts) do
    state = %{
      opts: opts,
      table: Keyword.fetch!(opts, :table),
      monitor: Keyword.fetch!(opts, :monitor),
      timer: nil,
      delay: Keyword.get(opts, :retry_min, 200)
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state) do
    {_result, state} = refresh(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:configure, config}, _from, state) do
    {result, state} = configure_now(state, config)
    {:reply, result, state}
  end

  def handle_call({:update_configuration, changes}, _from, state) do
    {result, state} = update_now(state, changes)
    {:reply, result, state}
  end

  def handle_call(:reset, _from, state) do
    {result, state} = configure_now(state, Keyword.get(state.opts, :config, %{}))
    {:reply, result, state}
  end

  def handle_call({:set_running, running}, _from, state) do
    result =
      with :ok <- ready(state),
           {:ok, _, _} <-
             LocalAPI.request(state.opts, "PATCH", "prefs", %{
               "WantRunning" => running,
               "WantRunningSet" => true
             }),
           {:ok, prefs} <- read_preferences(state.opts) do
        if prefs["WantRunning"] == running,
          do: :ok,
          else: {:error, :preferences_readback_mismatch}
      end

    {:reply, result, state}
  end

  def handle_call({:login, mode}, _from, state) do
    result =
      with :ok <- ready(state) do
        login_attempt(state, mode)
      end

    if result != :ok do
      Monitor.auth(state.monitor, {:error, elem(result, 1)})
    end

    {:reply, result, state}
  end

  def handle_call(:logout, _from, state) do
    result =
      with :ok <- ready(state),
           {:ok, _, _} <- LocalAPI.request(state.opts, "POST", "logout"),
           do: Monitor.auth(state.monitor, :logged_out)

    {:reply, result, state}
  end

  @impl true
  def handle_info({:refresh, token}, %{timer: {_timer, token}} = state) do
    {_result, state} = refresh(%{state | timer: nil})
    {:noreply, state}
  end

  def handle_info(:observed_change, state) do
    {_result, state} = refresh(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.put(status, :message, :redacted)

  defp update_now(state, changes) do
    case Configuration.normalize(changes) do
      {:ok, normalized} -> apply_configuration(state, Map.take(normalized, Map.keys(changes)))
      error -> {error, state}
    end
  end

  defp configure_now(state, input) do
    case Configuration.normalize(input) do
      {:ok, config} -> apply_configuration(state, config)
      error -> {error, state}
    end
  end

  defp apply_configuration(state, changes) do
    state = cancel_retry(state)
    configuration_status(state, :applying, nil)

    with :ok <- ready(state),
         dns_name = PropertyTable.get(state.table, ["dns_name"]),
         {:ok, _} <- Serve.build(%{}, Map.get(changes, :serve, []), dns_name),
         {:ok, prefs} <- preferences(state.opts, changes) do
      configure_serve(state, prefs, changes, dns_name)
    else
      error -> failed_operation(state, error)
    end
  end

  defp configure_serve(state, prefs, %{serve: endpoints}, dns_name) do
    case Serve.reconcile(state.opts, endpoints, dns_name) do
      {:ok, serve} -> observe(state, prefs, {:ok, serve})
      error -> failed_operation(state, error)
    end
  end

  defp configure_serve(state, prefs, _changes, _dns_name) do
    {_observation, state} = observe(state, prefs, read_serve(state.opts))
    {:ok, state}
  end

  defp failed_operation(state, {:error, reason} = error) do
    {_readback, state} = refresh(state)
    configuration_status(state, :error, reason)
    {error, state}
  end

  defp ready(state) do
    Monitor.ready(state.monitor, Keyword.get(state.opts, :timeout, 5_000))
  end

  # Only observations are retried. No desired configuration or failed mutation is retained.
  defp refresh(state) do
    state = cancel_retry(state)

    with :ok <- connected(state),
         {:ok, prefs} <- read_preferences(state.opts) do
      observe(state, prefs, read_serve(state.opts))
    else
      {:error, _} = error ->
        PropertyTable.delete(state.table, ["configuration", "value"])
        observation_result(state, error)
    end
  end

  defp read_serve(opts) do
    with {:ok, raw, _} <- LocalAPI.request(opts, "GET", "serve-config") do
      Serve.decode(raw)
    end
  end

  defp observe(state, prefs, serve_result) do
    serve =
      case serve_result do
        {:ok, endpoints} -> endpoints
        {:error, _} -> nil
      end

    PropertyTable.put(
      state.table,
      ["configuration", "value"],
      Configuration.observed(prefs, serve)
    )

    result =
      case serve_result do
        {:ok, _} -> :ok
        error -> error
      end

    observation_result(state, result)
  end

  defp observation_result(state, :ok) do
    configuration_status(state, :ready, nil)
    {:ok, %{state | delay: Keyword.get(state.opts, :retry_min, 200)}}
  end

  defp observation_result(state, {:error, reason} = error) do
    configuration_status(state, :error, reason)

    {error, if(retry?(reason), do: retry(state), else: state)}
  end

  defp connected(state) do
    if PropertyTable.get(state.table, ["monitor", "connected"], false),
      do: :ok,
      else: {:error, PropertyTable.get(state.table, ["monitor", "error"]) || :unavailable}
  end

  defp preferences(opts, config) do
    with {:ok, current} <- read_preferences(opts) do
      patch = Configuration.patch(config, current)

      # A rename's DNS update is asynchronous; never bind Serve to the old name.
      cond do
        Map.has_key?(patch, "HostnameSet") and Map.get(config, :serve, []) != [] ->
          {:error, :hostname_change_requires_separate_serve}

        map_size(patch) == 0 ->
          {:ok, current}

        true ->
          apply_preferences(opts, config, patch)
      end
    end
  end

  defp read_preferences(opts) do
    case LocalAPI.request(opts, "GET", "prefs") do
      {:ok, value, _} when is_map(value) -> {:ok, value}
      {:ok, _, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp apply_preferences(opts, config, patch) do
    with {:ok, _, _} <- LocalAPI.request(opts, "PATCH", "prefs", patch),
         {:ok, actual} <- read_preferences(opts) do
      if Configuration.patch(config, actual) == %{},
        do: {:ok, actual},
        else: {:error, :preferences_readback_mismatch}
    end
  end

  defp login_attempt(state, :interactive) do
    if PropertyTable.get(state.table, ["backend_state"]) == :running do
      :ok
    else
      with :ok <- Monitor.auth(state.monitor, :starting),
           :ok <- prepare_login(state),
           {:ok, _, _} <- LocalAPI.request(state.opts, "POST", "start", %{}),
           {:ok, _, _} <- LocalAPI.request(state.opts, "POST", "login-interactive") do
        recover_url(state)
        :ok
      end
    end
  end

  defp login_attempt(state, {:auth_key, key}) do
    with :ok <- Monitor.auth(state.monitor, :starting),
         {:ok, status, _} <- LocalAPI.request(state.opts, "GET", "status?peers=false"),
         :ok <- prepare_login(state),
         {:ok, _, _} <- LocalAPI.request(state.opts, "POST", "start", %{"AuthKey" => key}) do
      activate_key_login(state.opts, status)
    end
  rescue
    _ -> {:error, :authentication_failed}
  end

  # Like the official CLI, a fresh profile needs LoginInteractive to trigger the
  # control client's first Login. Its AuthKey was installed by Start, so this is
  # unattended registration, not browser enrollment. Existing profiles auto-login.
  defp activate_key_login(_opts, %{"HaveNodeKey" => true}), do: :ok

  defp activate_key_login(opts, status) when is_map(status) do
    with {:ok, _, _} <- LocalAPI.request(opts, "POST", "login-interactive"), do: :ok
  end

  defp activate_key_login(_opts, _status), do: {:error, :invalid_response}

  defp prepare_login(state) do
    with {:ok, _, _} <-
           LocalAPI.request(state.opts, "PATCH", "prefs", %{
             "WantRunning" => true,
             "WantRunningSet" => true,
             "LoggedOut" => false,
             "LoggedOutSet" => true
           }),
         do: :ok
  end

  defp recover_url(state) do
    # A single fallback read, not a status poll. The stream remains authoritative.
    case LocalAPI.request(state.opts, "GET", "status?peers=false") do
      {:ok, %{"AuthURL" => url}, _} when is_binary(url) and url != "" ->
        Monitor.auth(state.monitor, {:url, url})

      _ ->
        :ok
    end
  end

  defp retry?({:http, status}), do: status >= 500 or status == 429
  defp retry?(reason), do: reason not in [:unsupported_serve_configuration, :unsupported_version]

  defp retry(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:refresh, token}, state.delay)
    next = min(state.delay * 2, Keyword.get(state.opts, :retry_max, 30_000))
    %{state | timer: {timer, token}, delay: next}
  end

  defp cancel_retry(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    %{state | timer: nil}
  end

  defp configuration_status(state, value, error) do
    PropertyTable.put(state.table, ["configuration", "state"], value)

    if error,
      do: PropertyTable.put(state.table, ["configuration", "error"], error),
      else: PropertyTable.delete(state.table, ["configuration", "error"])
  end
end
