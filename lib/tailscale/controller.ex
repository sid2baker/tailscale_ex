defmodule Tailscale.Controller do
  @moduledoc false
  use GenServer

  alias Tailscale.{Configuration, LocalAPI, Monitor, Serve}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :controller))

  def configure(server, config), do: GenServer.call(server, {:configure, config}, :infinity)
  def reset(server), do: GenServer.call(server, :reset, :infinity)
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

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call({:configure, config}, _from, state) do
    {result, state} = configure_now(state, config)
    {:reply, result, state}
  end

  def handle_call(:reset, _from, state) do
    {result, state} = configure_now(state, Keyword.get(state.opts, :config, %{}))
    {:reply, result, state}
  end

  def handle_call({:login, mode}, _from, state) do
    result =
      with :ok <- Monitor.ready(state.monitor) do
        login_attempt(state, mode)
      end

    if result != :ok do
      Monitor.auth(state.monitor, {:error, elem(result, 1)})
    end

    {:reply, result, schedule(state, 0)}
  end

  def handle_call(:logout, _from, state) do
    result =
      with :ok <- Monitor.ready(state.monitor),
           {:ok, _, _} <- LocalAPI.request(state.opts, "POST", "logout"),
           do: Monitor.auth(state.monitor, :logged_out)

    {:reply, result, schedule(state, 0)}
  end

  @impl true
  def handle_info({:refresh, token}, %{timer: {_timer, token}} = state) do
    {_result, state} = refresh(%{state | timer: nil})
    {:noreply, state}
  end

  def handle_info(:observed_change, state), do: {:noreply, schedule(state, 0)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.put(status, :message, :redacted)

  defp configure_now(state, input) do
    case Configuration.normalize(input) do
      {:ok, config} ->
        configuration_status(state, :applying, nil)
        result = apply_configuration(state, config)
        {readback, state} = refresh(state)

        case result do
          :ok ->
            {readback, state}

          {:error, reason} ->
            configuration_status(state, :error, reason)
            {result, state}
        end

      error ->
        {error, state}
    end
  end

  defp apply_configuration(state, config) do
    dns_name = PropertyTable.get(state.table, ["dns_name"])

    with :ok <- connected(state),
         {:ok, _} <- Serve.build(%{}, config.serve, dns_name),
         :ok <- preferences(state.opts, config) do
      Serve.reconcile(state.opts, config.serve, dns_name)
    end
  end

  # Only observations are retried. No desired configuration or failed mutation is retained.
  defp refresh(state) do
    result =
      with :ok <- connected(state),
           {:ok, prefs} <- read_preferences(state.opts),
           {:ok, raw, _} <- LocalAPI.request(state.opts, "GET", "serve-config"),
           {:ok, serve} <- Serve.decode(raw) do
        PropertyTable.put(
          state.table,
          ["configuration", "value"],
          Configuration.observed(prefs, serve)
        )

        :ok
      end

    state =
      case result do
        :ok ->
          configuration_status(state, :ready, nil)
          %{state | delay: Keyword.get(state.opts, :retry_min, 200)}

        {:error, reason} ->
          PropertyTable.delete(state.table, ["configuration", "value"])
          configuration_status(state, :error, reason)
          if retry?(reason), do: retry(state), else: state
      end

    {result, state}
  end

  defp connected(state) do
    if PropertyTable.get(state.table, ["monitor", "connected"], false),
      do: :ok,
      else: {:error, PropertyTable.get(state.table, ["monitor", "error"]) || :unavailable}
  end

  defp preferences(opts, config) do
    with {:ok, current} <- read_preferences(opts) do
      apply_preferences(opts, config, Configuration.patch(config, current))
    end
  end

  defp read_preferences(opts) do
    case LocalAPI.request(opts, "GET", "prefs") do
      {:ok, value, _} when is_map(value) -> {:ok, value}
      {:ok, _, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp apply_preferences(_opts, _config, patch) when map_size(patch) == 0, do: :ok

  defp apply_preferences(opts, config, patch) do
    with {:ok, _, _} <- LocalAPI.request(opts, "PATCH", "prefs", patch),
         {:ok, actual} <- read_preferences(opts) do
      if Configuration.patch(config, actual) == %{},
        do: :ok,
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
    next = min(state.delay * 2, Keyword.get(state.opts, :retry_max, 30_000))
    %{schedule(state, state.delay) | delay: next}
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    token = make_ref()
    timer = Process.send_after(self(), {:refresh, token}, delay)
    %{state | timer: {timer, token}}
  end

  defp configuration_status(state, value, error) do
    PropertyTable.put(state.table, ["configuration", "state"], value)

    if error,
      do: PropertyTable.put(state.table, ["configuration", "error"], error),
      else: PropertyTable.delete(state.table, ["configuration", "error"])
  end
end
