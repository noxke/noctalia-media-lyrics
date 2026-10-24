#!/usr/bin/env bash
# Install / inspect / remove the local media-lyrics plugin.
#
# The plugin source lives in this workspace (plugin/media-lyrics); Noctalia only scans
# $XDG_DATA_HOME/noctalia/plugins for local plugins, so the source has to be copied there.
set -euo pipefail

PLUGIN_ID="noxke/media-lyrics"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/plugin/media-lyrics"
PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/media-lyrics"

usage() {
  echo "usage: $(basename "$0") {install|status|uninstall}" >&2
  exit 2
}

require_noctalia() {
  command -v noctalia >/dev/null 2>&1 || { echo "noctalia is not on PATH" >&2; exit 1; }
}

cmd_install() {
  require_noctalia
  [ -f "$SRC_DIR/plugin.toml" ] || { echo "missing $SRC_DIR/plugin.toml" >&2; exit 1; }
  mkdir -p "$PLUGIN_DIR"
  # .cache is the plugin's own runtime directory: never delete or overwrite it.
  tar -C "$SRC_DIR" --exclude=.cache -cf - . | tar -C "$PLUGIN_DIR" -xf -
  echo "copied $SRC_DIR -> $PLUGIN_DIR"
  noctalia plugins lint "$PLUGIN_DIR"
  if noctalia msg plugins enable "$PLUGIN_ID" >/dev/null 2>&1; then
    echo "enabled $PLUGIN_ID"
  else
    echo "enable it with: noctalia msg plugins enable $PLUGIN_ID"
  fi
  echo "Next: Settings -> Bar -> add the 'media' widget of $PLUGIN_ID (the instance"
  echo "      name is yours to choose, e.g. 'lyrics'); then disable the upstream"
  echo "      h465855hgg/lyrics so only one service polls MPRIS."
}

cmd_status() {
  require_noctalia
  echo "source:  $SRC_DIR"
  echo "target:  $PLUGIN_DIR"
  echo "installed: $([ -f "$PLUGIN_DIR/plugin.toml" ] && echo yes || echo no)"
  noctalia msg plugins list 2>/dev/null | grep -i 'lyrics' || true
}

cmd_uninstall() {
  require_noctalia
  noctalia msg plugins disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  if [ -d "$PLUGIN_DIR" ]; then
    rm -rf "${PLUGIN_DIR:?}"
    echo "removed $PLUGIN_DIR"
  else
    echo "nothing installed at $PLUGIN_DIR"
  fi
  echo "Re-enable the upstream plugin in Settings if you still want lyrics in the bar."
}

case "${1:-}" in
  install) cmd_install ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) usage ;;
esac
