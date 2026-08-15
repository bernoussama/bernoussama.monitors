#!/usr/bin/env bash
# Install script for bernoussama.monitors Omarchy plugin
set -euo pipefail

TARGET_DIR="$HOME/.config/omarchy/plugins/bernoussama.monitors"
REPO_URL="https://github.com/bernoussama/bernoussama.monitors.git"

echo "Installing bernoussama.monitors plugin..."

mkdir -p "$HOME/.config/omarchy/plugins"

if [ -d "$TARGET_DIR" ]; then
  echo "Plugin directory already exists at $TARGET_DIR. Updating files..."
else
  echo "Cloning plugin into $TARGET_DIR..."
  git clone "$REPO_URL" "$TARGET_DIR"
fi

chmod +x "$TARGET_DIR/apply-monitors"

# Enable plugin in shell.json if not present
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
if [ -f "$SHELL_CONFIG" ]; then
  if ! jq -e '.plugins[]? | select(.id == "bernoussama.monitors")' "$SHELL_CONFIG" >/dev/null 2>&1; then
    echo "Registering bernoussama.monitors in $SHELL_CONFIG..."
    tmp="$(mktemp)"
    jq '.plugins = [((.plugins // [])[] | select(.id != "oussama.monitors"))] + [{"id": "bernoussama.monitors"}]' "$SHELL_CONFIG" > "$tmp"
    mv "$tmp" "$SHELL_CONFIG"
  fi
fi

# Reload shell plugins
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

echo "Installation complete!"
echo "Open the layout editor with: omarchy-shell shell toggle bernoussama.monitors"
