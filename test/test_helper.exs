ExUnit.start(exclude: [:integration])

# Load test support modules
Code.require_file("support/mock_tailscale.ex", __DIR__)
