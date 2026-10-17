#!/bin/sh
set -eu
LENS_INSTALL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
if ! command -v python3 >/dev/null 2>&1; then
  if [ "${1:-}" = '--cli' ] || [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
    printf '%s\n' 'Install Python 3 with your package manager, then run this installer again.' >&2
    exit 1
  fi
  printf '%s\n' 'Python 3 is required. Confirm its installation in your desktop authorization dialog.' >&2
  if command -v apt-get >/dev/null 2>&1; then
    pkexec apt-get install -y python3
  elif command -v dnf >/dev/null 2>&1; then
    pkexec dnf install -y python3
  elif command -v pacman >/dev/null 2>&1; then
    pkexec pacman -S --needed python
  else
    printf '%s\n' 'Install Python 3 with your package manager, then run this installer again.' >&2
    exit 1
  fi
fi
if [ "${1:-}" = '--cli' ]; then
  shift
  exec python3 "$LENS_INSTALL_DIR/install.py" "$@"
elif [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  exec python3 "$LENS_INSTALL_DIR/install.py" --bootstrap --gui "$@"
else
  exec python3 "$LENS_INSTALL_DIR/install.py" "$@"
fi
