defmodule Tailscale.Supervisor do
  @moduledoc false

  use Supervisor

  alias Tailscale.DaemonManager
  alias Tailscale.Naming
  alias Tailscale.Server

  @spec start_link(Tailscale.Config.t()) :: Supervisor.on_start()
  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: Naming.via(config.name, :supervisor))
  end

  @impl true
  def init(config) do
    task_supervisor_name = Naming.via(config.name, :task_supervisor)
    daemon_manager_name = Naming.via(config.name, :daemon_manager)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: task_supervisor_name}, id: :task_supervisor),
      Supervisor.child_spec(
        {DaemonManager, registered_name: daemon_manager_name, config: config},
        id: :daemon_manager
      ),
      Supervisor.child_spec(
        {Server,
         name: config.name,
         task_supervisor: task_supervisor_name,
         daemon_manager: daemon_manager_name,
         config: config},
        id: :server
      )
    ]

    # If the state owner fails, command tasks and daemon ownership must not
    # survive it. Ordinary tailscaled exits are handled inside DaemonManager.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
