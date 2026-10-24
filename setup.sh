#!/usr/bin/env bash
# Check the environment the plugin runs in, and look up lyrics the way it does.
#
# The plugin itself is installed by tools/install-plugin.sh; this script only
# reports state, so a failure here explains a failure in the bar.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="noxke/media-lyrics"
COMMAND="status"
INSTALL_DEPS=0
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
SETTINGS_TOML="$STATE_HOME/noctalia/settings.toml"
PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/media-lyrics"
ARCH_PACKAGES="playerctl python3"
PLUGIN_DEPS="playerctl python3 cp chmod timeout"

usage() {
  cat <<'USAGE'
Usage: setup.sh [command] [options]

Commands:
  status      dependencies, plugin state, and the MPRIS players on the session bus (default)
  doctor      read the playing track from MPRIS and query the lyric APIs directly
  uninstall   disable the plugin and remove the installed copy

Options:
  --install-deps   install the missing Arch packages with pacman (runs sudo)
  -h, --help       this text
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    status|doctor|uninstall) COMMAND="$1" ;;
    --install-deps) INSTALL_DEPS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

missing_deps() {
  local c out=()
  for c in $PLUGIN_DEPS; do
    command -v "$c" >/dev/null 2>&1 || out+=("$c")
  done
  if [ ${#out[@]} -gt 0 ]; then printf '%s\n' "${out[@]}"; fi
}

have_noctalia() { command -v noctalia >/dev/null 2>&1; }

mpris_players() {
  busctl --user list 2>/dev/null | awk '{print $1}' | grep -o 'org\.mpris\.MediaPlayer2\.[^ ]*' || true
}

cmd_status() {
  local missing players
  echo "plugin:  $PLUGIN"
  echo "source:  $HERE/plugin/media-lyrics"
  if [ -f "$PLUGIN_DIR/plugin.toml" ]; then
    echo "install: $PLUGIN_DIR"
  else
    echo "install: missing — run tools/install-plugin.sh install"
  fi
  if have_noctalia; then
    # `noctalia | grep -q` reports failure under pipefail: grep exits at the first
    # match, the writer takes SIGPIPE, and pipefail marks the whole pipeline failed.
    local listed
    listed="$(noctalia msg plugins list 2>/dev/null || true)"
    if printf '%s\n' "$listed" | grep -Fq "$PLUGIN"; then
      echo "state:   known to Noctalia"
    else
      echo "state:   not known to Noctalia yet"
    fi
  else
    echo "state:   noctalia is not on PATH"
  fi
  if [ -f "$SETTINGS_TOML" ] && grep -Fq "\"$PLUGIN\"" "$SETTINGS_TOML"; then
    echo "enabled: yes ($SETTINGS_TOML)"
  else
    echo "enabled: no"
  fi
  missing="$(missing_deps)"
  if [ -n "$missing" ]; then
    echo "deps:    missing $(echo "$missing" | tr '\n' ' ')"
    if [ "$INSTALL_DEPS" = 1 ]; then
      echo "         installing with pacman: $ARCH_PACKAGES"
      sudo pacman -S --needed --noconfirm $ARCH_PACKAGES
    else
      echo "         install them (Arch): sudo pacman -S --needed $ARCH_PACKAGES"
      echo "         or re-run: $0 status --install-deps"
    fi
  else
    echo "deps:    ok ($PLUGIN_DEPS)"
  fi
  players="$(mpris_players)"
  if [ -n "$players" ]; then
    echo "players:"
    echo "$players" | sed 's/^/         /'
  else
    echo "players: none on the session bus (start playback first)"
  fi
}

cmd_uninstall() {
  if ! have_noctalia; then
    echo "noctalia is not on PATH; remove the widget in Noctalia Settings" >&2
    return 1
  fi
  echo "disabling $PLUGIN"
  noctalia msg plugins disable "$PLUGIN" || true
  echo "remove the bar widget in Settings -> Bar; packages stay installed"
}

cmd_doctor() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for doctor" >&2
    return 1
  fi
  python3 "$HERE/lib/doctor.py"
}

case "$COMMAND" in
  status)    cmd_status ;;
  doctor)    cmd_doctor ;;
  uninstall) cmd_uninstall ;;
esac
