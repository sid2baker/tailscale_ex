defmodule Tailscale.ApplicationTest do
  use ExUnit.Case, async: false
  alias Tailscale.Test.{Fixture, UnixHTTP}

  test "the OTP application starts one root containing the runtime children directly" do
    {:ok, daemon} = Fixture.daemon()
    directory = Path.join(System.tmp_dir!(), "tsx-app-#{System.unique_integer([:positive])}")
    opts = [manage_daemon: false, socket: UnixHTTP.socket(daemon), data_dir: directory]
    previous = Application.get_all_env(:tailscale)

    on_exit(fn ->
      Application.stop(:tailscale)

      for {key, _value} <- opts do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:tailscale, key, value)
          :error -> Application.delete_env(:tailscale, key)
        end
      end

      File.rm_rf(directory)
    end)

    for {key, value} <- opts, do: Application.put_env(:tailscale, key, value)
    assert :ok = Application.start(:tailscale)
    root = Process.whereis(Tailscale.Supervisor)
    assert is_pid(root)
    assert Process.whereis(Tailscale.ApplicationSupervisor) == nil

    modules =
      root
      |> Supervisor.which_children()
      |> Enum.flat_map(fn {_id, _pid, _type, modules} -> modules end)
      |> Enum.sort()

    assert modules ==
             Enum.sort([
               PropertyTable,
               Tailscale.Daemon,
               Tailscale.Monitor,
               Tailscale.Controller
             ])

    assert :ok = Tailscale.Monitor.ready(Tailscale.Monitor)
    assert Tailscale.get(["state"]) == :offline
    assert Tailscale.get(["daemon", "state"]) == :external
  end
end
