#!/bin/sh
# Publishes the loopback-only agent inside the tailnet with HTTPS (not on the public internet).
# The config persists in tailscaled. Undo with: tailscale serve --https=8443 off
set -eu
PORT=8443
tailscale serve --bg --https="$PORT" --set-path / http://127.0.0.1:47800
tailscale serve --bg --https="$PORT" --set-path /ws http://127.0.0.1:47801
tailscale serve status
