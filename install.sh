#!/usr/bin/env bash
# sets up ~/.config/omarchy-network, links the plugin into the omarchy shell and enables it.
# the router user + password are yours to create, see README.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ID=$(python3 -c "import json;print(json.load(open('$ROOT/manifest.json'))['id'])")
CONF="$HOME/.config/omarchy-network"
STATE="$HOME/.local/state/omarchy-network"

mkdir -p "$CONF" "$STATE"
chmod 700 "$CONF"

if [[ ! -f $CONF/config.json ]]; then
  cp "$ROOT/config.example.json" "$CONF/config.json"
  echo "wrote $CONF/config.json from the example, edit router/lanes before using it"
fi

if [[ ! -f $CONF/netrc ]]; then
  read -rp "router address (e.g. 192.168.88.1): " host
  read -rp "router user: " user
  read -rsp "router password: " pass; echo
  umask 077
  printf 'machine %s login %s password %s\n' "$host" "$user" "$pass" > "$CONF/netrc"
  unset pass
  echo "wrote $CONF/netrc (600)"
fi
chmod 600 "$CONF/netrc"

mkdir -p "$HOME/.config/omarchy/plugins"
ln -sfn "$ROOT" "$HOME/.config/omarchy/plugins/$ID"
omarchy plugin enable "$ID" 2>/dev/null || true
echo "linked $ID, if the bar doesn't show it run: omarchy restart shell"
