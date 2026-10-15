defmodule Tailscaled.ApplicationTest do
  use ExUnit.Case, async: false
  alias Tailscaled.Test.{Fixture, UnixHTTP}

  test "default identity storage uses the package name" do
    {:ok, daemon} = Fixture.daemon()
    start_supervised!({Fixture, manage_daemon: false, socket: UnixHTTP.socket(daemon)})
    opts = :sys.get_state(Tailscaled.Daemon).opts
    data_dir = Path.join(System.user_home!(), ".local/share/tailscaled_ex")
    assert opts[:data_dir] == data_dir
    assert opts[:state_dir] == Path.join(data_dir, "identity")
  end

  test "the OTP application starts one root containing the runtime children directly" do
    {:ok, daemon} = Fixture.daemon()
    directory = Path.join(System.tmp_dir!(), "tsx-app-#{System.unique_integer([:positive])}")
    opts = [manage_daemon: false, socket: UnixHTTP.socket(daemon), data_dir: directory]
    previous = Application.get_all_env(:tailscaled_ex)

    on_exit(fn ->
      Application.stop(:tailscaled_ex)

      for {key, _value} <- opts do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:tailscaled_ex, key, value)
          :error -> Application.delete_env(:tailscaled_ex, key)
        end
      end

      File.rm_rf(directory)
    end)

    for {key, value} <- opts, do: Application.put_env(:tailscaled_ex, key, value)
    assert :ok = Application.start(:tailscaled_ex)
    root = Process.whereis(Tailscaled.Supervisor)
    assert is_pid(root)

    daemon_opts = :sys.get_state(Tailscaled.Daemon).opts
    assert daemon_opts[:data_dir] == directory
    assert daemon_opts[:state_dir] == Path.join(directory, "identity")
    assert daemon_opts[:socket] == UnixHTTP.socket(daemon)

    modules =
      root
      |> Supervisor.which_children()
      |> Enum.flat_map(fn {_id, _pid, _type, modules} -> modules end)
      |> Enum.sort()

    assert modules ==
             Enum.sort([
               PropertyTable,
               Tailscaled.Daemon,
               Tailscaled.Monitor,
               Tailscaled.Controller
             ])

    assert :ok = Tailscaled.Monitor.ready(Tailscaled.Monitor)
    assert Tailscaled.get(["state"]) == :offline
    assert Tailscaled.get(["daemon", "state"]) == :external
  end
end
