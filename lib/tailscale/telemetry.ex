defmodule Tailscale.Telemetry do
  @moduledoc false

  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    :telemetry.execute([:tailscale | event], measurements, metadata)
  end
end
