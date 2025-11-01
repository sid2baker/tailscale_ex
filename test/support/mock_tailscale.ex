defmodule MockTailscale do
  @moduledoc """
  Mock implementation of tailscale and tailscaled binaries for testing.

  This module creates simple shell scripts that mimic the behavior of
  the real tailscale CLI without requiring actual installation.
  """

  @doc """
  Creates mock binaries in a temporary directory.

  Returns a map with:
  - `:cli_path` - Path to mock tailscale CLI
  - `:daemon_path` - Path to mock tailscaled daemon
  - `:test_dir` - Temporary directory containing the mocks
  """
  @spec create_mocks() :: %{
          cli_path: Path.t(),
          daemon_path: Path.t(),
          test_dir: Path.t()
        }
  def create_mocks do
    test_dir =
      Path.join(System.tmp_dir!(), "mock_tailscale_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    cli_path = Path.join(test_dir, "tailscale")
    daemon_path = Path.join(test_dir, "tailscaled")

    # Create mock tailscale CLI
    File.write!(cli_path, mock_cli_script())
    File.chmod!(cli_path, 0o755)

    # Create mock tailscaled daemon
    File.write!(daemon_path, mock_daemon_script())
    File.chmod!(daemon_path, 0o755)

    %{
      cli_path: cli_path,
      daemon_path: daemon_path,
      test_dir: test_dir
    }
  end

  @doc """
  Cleans up mock binaries and temporary directory.
  """
  @spec cleanup_mocks(Path.t()) :: :ok
  def cleanup_mocks(test_dir) do
    File.rm_rf!(test_dir)
    :ok
  end

  # Private functions

  defp mock_cli_script do
    """
    #!/bin/bash
    # Mock tailscale CLI for testing

    # Strip out --socket flag if present
    args=()
    for arg in "$@"; do
      if [[ "$arg" != --socket=* ]]; then
        args+=("$arg")
      fi
    done
    set -- "${args[@]}"

    case "$1" in
      --version)
        echo "1.88.3"
        echo "  tailscale commit: 9961c097b1781891e3c6b96e5e1194355ff06a6d-dirty"
        echo "  long version: 1.88.3-t9961c097b"
        echo "  go version: go1.25.1"
        exit 0
        ;;

      version)
        echo "1.88.3"
        exit 0
        ;;

      status)
        if [[ "$*" == *"--json"* ]]; then
          echo '{"Self":{"Online":true,"HostName":"mock-host","TailscaleIPs":["100.64.0.1"]},"Peer":{}}'
        else
          echo "# Health check:"
          echo "#     - logged in, available"
          echo ""
          echo "mock-host  100.64.0.1"
        fi
        exit 0
        ;;

      ip)
        echo "100.64.0.1"
        echo "fd7a:115c:a1e0::1"
        exit 0
        ;;

      up)
        echo "Success."
        exit 0
        ;;

      down)
        echo "Success."
        exit 0
        ;;

      login)
        echo "To authenticate, visit:"
        echo "https://login.tailscale.com/a/mock-auth-url"
        exit 0
        ;;

      logout)
        echo "Success."
        exit 0
        ;;

      set)
        echo "Success."
        exit 0
        ;;

      switch)
        echo "Switched to account mock@example.com"
        exit 0
        ;;

      netcheck)
        echo "Report:"
        echo "  * UDP: true"
        echo "  * IPv4: yes, 203.0.113.1:12345"
        echo "  * IPv6: no"
        exit 0
        ;;

      metrics)
        echo "# HELP tailscale_up 1 if the Tailscale interface is up, 0 if down"
        echo "# TYPE tailscale_up gauge"
        echo "tailscale_up 0"
        exit 0
        ;;

      ping)
        echo "pong from mock-node (100.64.0.2) via DERP(mock) in 25ms"
        exit 0
        ;;

      bugreport)
        echo "BUG-12345-MOCK"
        exit 0
        ;;

      licenses)
        echo "Tailscale uses the following open source software:"
        echo "- Go standard library (BSD-3-Clause)"
        exit 0
        ;;

      dns)
        echo "DNS configuration:"
        echo "  Resolver: direct"
        exit 0
        ;;

      exit-node)
        if [[ "$*" == *"--json"* ]]; then
          echo '[]'
        else
          echo "# Available exit nodes:"
          echo "# (none)"
        fi
        exit 0
        ;;

      whois)
        if [[ "$*" == *"--json"* ]]; then
          echo '{"Node":{"Name":"mock-node","ID":"12345"},"UserProfile":{"LoginName":"user@example.com"}}'
        else
          echo "mock-node"
          echo "  User: user@example.com"
        fi
        exit 0
        ;;

      file)
        echo "Success."
        exit 0
        ;;

      cert)
        echo "Success. Certificate written."
        exit 0
        ;;

      serve)
        echo "Available services: (none)"
        exit 0
        ;;

      funnel)
        echo "Funnel status"
        exit 0
        ;;

      ssh)
        echo "SSH connection would be initiated here"
        exit 1
        ;;

      nc)
        echo "nc: connection refused"
        exit 1
        ;;

      lock)
        echo "Tailnet lock status: disabled"
        exit 0
        ;;

      update)
        echo "Already up to date."
        exit 0
        ;;

      configure)
        echo "Configuration applied."
        exit 0
        ;;

      syspolicy)
        echo "No system policies active."
        exit 0
        ;;

      drive)
        echo "No drives shared."
        exit 0
        ;;

      web)
        echo "Starting web interface on localhost:8088"
        # Don't actually start a server in tests
        exit 1
        ;;

      *)
        echo "unknown command: $1"
        echo "Run 'tailscale --help' for usage."
        exit 1
        ;;
    esac
    """
  end

  defp mock_daemon_script do
    """
    #!/bin/bash
    # Mock tailscaled daemon for testing

    # Parse arguments
    STATEDIR=""
    for arg in "$@"; do
      case "$arg" in
        --statedir=*)
          STATEDIR="${arg#*=}"
          ;;
      esac
    done

    # Create state directory if specified
    if [ -n "$STATEDIR" ]; then
      mkdir -p "$STATEDIR"
    fi

    # Mock daemon just sleeps
    # In real tests, this will be supervised by MuonTrap
    sleep infinity
    """
  end
end
