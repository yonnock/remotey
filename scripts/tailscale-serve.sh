#!/bin/sh
# Publishes the loopback-only agent inside the tailnet with HTTPS (not on the public internet).
# The config persists in tailscaled. Undo with: tailscale serve --https=8443 off
set -eu
PORT=8443
AGENT=${REMOTEY_PORT:-47800} # the agent's page; its socket is on the port after it
tailscale serve --bg --https="$PORT" --set-path / "http://127.0.0.1:$AGENT"
tailscale serve --bg --https="$PORT" --set-path /ws "http://127.0.0.1:$((AGENT + 1))"
tailscale serve status
