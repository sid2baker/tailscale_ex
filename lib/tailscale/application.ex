defmodule Tailscale.Application do
  @moduledoc false
  use Application

  alias Tailscale.{Controller, Daemon, Monitor}

  @impl true
  def start(_type, args) do
    opts = Application.get_all_env(:tailscale) |> Keyword.merge(args) |> options()

    children = [
      {PropertyTable, name: Keyword.fetch!(opts, :table), event_transformer: &event/1},
      {Daemon, opts},
      {Monitor, opts},
      {Controller, opts}
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: Keyword.get(opts, :supervisor, Tailscale.Supervisor)
    )
  end

  defp options(opts) do
    data_dir =
      Keyword.get_lazy(opts, :data_dir, fn ->
        if Code.ensure_loaded?(Nerves.Runtime) do
          "/data/tailscale_ex"
        else
          Path.join(System.user_home!(), ".local/share/tailscale_ex")
        end
      end)

    socket =
      if Keyword.get(opts, :manage_daemon, true) do
        Path.join(data_dir, "run/tailscaled.sock")
      else
        "/var/run/tailscale/tailscaled.sock"
      end

    Keyword.merge(
      [
        manage_daemon: true,
        table: Tailscale.Properties,
        monitor: Monitor,
        controller: Controller,
        daemon: Daemon,
        data_dir: data_dir,
        state_dir: Path.join(data_dir, "identity"),
        socket: socket
      ],
      opts
    )
  end

  defp event(event) do
    {Tailscale, event.property, event.previous_value, event.value,
     %{old_timestamp: event.previous_timestamp, new_timestamp: event.timestamp}}
  end
end
