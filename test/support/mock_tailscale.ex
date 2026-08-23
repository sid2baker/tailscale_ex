defmodule MockTailscale do
  @moduledoc false

  @spec create_mocks() :: %{cli_path: Path.t(), daemon_path: Path.t(), test_dir: Path.t()}
  def create_mocks do
    test_dir =
      Path.join(System.tmp_dir!(), "mock_tailscale_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    cli_path = Path.join(test_dir, "tailscale")
    daemon_path = Path.join(test_dir, "tailscaled")
    File.write!(cli_path, mock_cli_script())
    File.write!(daemon_path, mock_daemon_script())
    File.chmod!(cli_path, 0o755)
    File.chmod!(daemon_path, 0o755)

    %{cli_path: cli_path, daemon_path: daemon_path, test_dir: test_dir}
  end

  @spec cleanup_mocks(Path.t()) :: :ok
  def cleanup_mocks(test_dir) do
    File.rm_rf!(test_dir)
    :ok
  end

  @spec configure_route_status(Path.t(), keyword()) :: :ok
  def configure_route_status(test_dir, opts) do
    write_csv(test_dir, "approved-routes", Keyword.get(opts, :approved, []))
    write_csv(test_dir, "primary-routes", Keyword.get(opts, :primary, []))
  end

  @spec configure_status(Path.t(), keyword()) :: :ok
  def configure_status(test_dir, opts) do
    Enum.each(opts, fn {key, value} ->
      filename = key |> Atom.to_string() |> String.replace("_", "-")
      File.write!(Path.join(test_dir, filename), to_string(value))
    end)

    :ok
  end

  @spec configure_status_failures(Path.t(), non_neg_integer()) :: :ok
  def configure_status_failures(test_dir, count) do
    File.write!(Path.join(test_dir, "status-failures"), Integer.to_string(count))
  end

  @spec configure_delay(Path.t(), String.t(), number()) :: :ok
  def configure_delay(test_dir, command, seconds) do
    File.write!(Path.join(test_dir, "delay-#{command}"), to_string(seconds))
  end

  @spec configure_daemon_exits(Path.t(), non_neg_integer()) :: :ok
  def configure_daemon_exits(test_dir, count) do
    File.write!(Path.join(test_dir, "daemon-exit-count"), Integer.to_string(count))
  end

  @spec command_log(Path.t()) :: [String.t()]
  def command_log(test_dir), do: read_lines(Path.join(test_dir, "command-log"))

  @spec mutation_log(Path.t()) :: [String.t()]
  def mutation_log(test_dir), do: read_lines(Path.join(test_dir, "mutation-log"))

  defp write_csv(test_dir, filename, values) do
    File.write!(Path.join(test_dir, filename), Enum.join(values, ","))
    :ok
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp mock_cli_script do
    ~S"""
    #!/bin/bash
    trap 'sleep 0.005' EXIT

    MOCK_DIR="$(dirname "$0")"
    SOCKET=""
    args=()
    for arg in "$@"; do
      case "$arg" in
        --socket=*) SOCKET="${arg#*=}" ;;
        *) args+=("$arg") ;;
      esac
    done
    set -- "${args[@]}"
    command="$1"

    printf '%s\n' "$@" > "$MOCK_DIR/cli-args"
    printf 'start %s %s\n' "$command" "$(date +%s%N)" >> "$MOCK_DIR/command-log"

    finish() {
      printf 'finish %s %s\n' "$command" "$(date +%s%N)" >> "$MOCK_DIR/command-log"
    }
    trap 'finish; sleep 0.005' EXIT

    contents() {
      [ -f "$1" ] && cat "$1"
    }

    json_array() {
      printf '%s\n' "$1" | awk -F, '{
        printf "["
        for (i = 1; i <= NF && $i != ""; i++) {
          if (i > 1) printf ","
          printf "\"%s\"", $i
        }
        printf "]"
      }'
    }

    delay="$(contents "$MOCK_DIR/delay-$command")"
    [ -n "$delay" ] && sleep "$delay"

    case "$command" in
      version|--version) ;;
      *)
        if [ -z "$SOCKET" ] || [ ! -e "$SOCKET" ]; then
          echo "failed to connect to local tailscaled"
          exit 1
        fi
        ;;
    esac

    case "$command" in
      --version)
        echo "1.88.3"
        ;;

      version)
        if [[ "$*" == *"--json"* ]]; then
          echo '{"majorMinorPatch":"1.88.3"}'
        else
          echo "1.88.3"
        fi
        ;;

      status)
        failures="$(contents "$MOCK_DIR/status-failures")"
        if [ -n "$failures" ] && [ "$failures" -gt 0 ]; then
          printf '%s' "$((failures - 1))" > "$MOCK_DIR/status-failures"
          echo "failed to connect to local tailscaled"
          exit 1
        fi

        backend="$(contents "$MOCK_DIR/backend-state")"
        online="$(contents "$MOCK_DIR/online")"
        have_key="$(contents "$MOCK_DIR/have-node-key")"
        hostname="$(contents "$MOCK_DIR/hostname")"
        approved="$(contents "$MOCK_DIR/approved-routes")"
        primary="$(contents "$MOCK_DIR/primary-routes")"
        [ -z "$backend" ] && backend="Running"
        [ -z "$online" ] && online="true"
        [ -z "$have_key" ] && have_key="true"
        [ -z "$hostname" ] && hostname="mock-host"
        allowed="100.64.0.1/32"
        [ -n "$approved" ] && allowed="$allowed,$approved"

        printf '{"BackendState":"%s","HaveNodeKey":%s,"TailscaleIPs":["100.64.0.1"],"Self":{"Online":%s,"HostName":"%s","TailscaleIPs":["100.64.0.1"],"AllowedIPs":' "$backend" "$have_key" "$online" "$hostname"
        json_array "$allowed"
        printf ',"PrimaryRoutes":'
        json_array "$primary"
        echo '},"Peer":{}}'
        ;;

      login)
        printf 'login\n' >> "$MOCK_DIR/mutation-log"
        auth_arg=""
        for arg in "$@"; do
          case "$arg" in --auth-key=*) auth_arg="${arg#*=}" ;; esac
        done
        case "$auth_arg" in
          file:*)
            auth_file="${auth_arg#file:}"
            [ -r "$auth_file" ] || { echo "auth key file unavailable"; exit 1; }
            printf '%s' "$auth_arg" > "$MOCK_DIR/login-auth-argument"
            if [ -f "$MOCK_DIR/echo-auth-error" ]; then
              cat "$auth_file"
              exit 1
            fi
            ;;
          *) echo "auth key must use file reference"; exit 1 ;;
        esac
        ;;

      set)
        printf 'set\n' >> "$MOCK_DIR/mutation-log"
        [ -f "$MOCK_DIR/set-error" ] && { echo "failed to update preferences"; exit 1; }
        for arg in "$@"; do
          case "$arg" in
            --advertise-routes=*) printf '%s' "${arg#*=}" > "$MOCK_DIR/advertised-routes" ;;
            --hostname=*) printf '%s' "${arg#*=}" > "$MOCK_DIR/preference-hostname" ;;
            --accept-dns) printf 'true' > "$MOCK_DIR/accept-dns" ;;
            --accept-dns=false) printf 'false' > "$MOCK_DIR/accept-dns" ;;
            --ssh) printf 'true' > "$MOCK_DIR/ssh" ;;
            --ssh=false) printf 'false' > "$MOCK_DIR/ssh" ;;
          esac
        done
        ;;

      debug)
        if [ "$2" != "prefs" ]; then echo "unknown debug command"; exit 1; fi
        routes="$(contents "$MOCK_DIR/advertised-routes")"
        hostname="$(contents "$MOCK_DIR/preference-hostname")"
        dns="$(contents "$MOCK_DIR/accept-dns")"
        ssh="$(contents "$MOCK_DIR/ssh")"
        [ -z "$dns" ] && dns="true"
        [ -z "$ssh" ] && ssh="false"
        printf '{"Hostname":"%s","CorpDNS":%s,"RunSSH":%s,"AdvertiseRoutes":' "$hostname" "$dns" "$ssh"
        if [ -n "$routes" ]; then json_array "$routes"; else printf 'null'; fi
        echo '}'
        ;;

      switch)
        if [ "$2" = "--list" ]; then
          profiles="$(contents "$MOCK_DIR/profiles-json")"
          if [ -n "$profiles" ]; then
            printf '%s\n' "$profiles"
          else
            echo '[{"id":"profile-1","nickname":"main","tailnet":"example.ts.net","account":"user@example.com","selected":true}]'
          fi
        elif [ "$2" = "remove" ]; then
          printf 'switch remove %s\n' "$3" >> "$MOCK_DIR/mutation-log"
        else
          printf 'switch %s\n' "$2" >> "$MOCK_DIR/mutation-log"
        fi
        ;;

      ip)
        echo "100.64.0.1"
        echo "fd7a:115c:a1e0::1"
        ;;

      up|down|logout|configure)
        printf '%s\n' "$command" >> "$MOCK_DIR/mutation-log"
        echo "Success."
        ;;

      whois)
        echo '{"Node":{"Name":"mock-node","ID":"12345"}}'
        ;;

      *)
        echo "unknown command: $command"
        exit 1
        ;;
    esac
    """
  end

  defp mock_daemon_script do
    ~S"""
    #!/bin/bash
    MOCK_DIR="$(dirname "$0")"
    STATEDIR=""
    SOCKET=""

    for arg in "$@"; do
      case "$arg" in
        --statedir=*) STATEDIR="${arg#*=}" ;;
        --socket=*) SOCKET="${arg#*=}" ;;
      esac
    done

    starts="$(cat "$MOCK_DIR/daemon-start-count" 2>/dev/null)"
    [ -z "$starts" ] && starts=0
    printf '%s' "$((starts + 1))" > "$MOCK_DIR/daemon-start-count"

    exits="$(cat "$MOCK_DIR/daemon-exit-count" 2>/dev/null)"
    if [ -n "$exits" ] && [ "$exits" -gt 0 ]; then
      printf '%s' "$((exits - 1))" > "$MOCK_DIR/daemon-exit-count"
      exit 42
    fi

    mkdir -p "$STATEDIR" "$(dirname "$SOCKET")"
    printf '%s\n' "$@" > "$STATEDIR/daemon-args"
    touch "$SOCKET"
    trap 'rm -f "$SOCKET"; exit 0' TERM INT EXIT
    sleep infinity
    """
  end
end
