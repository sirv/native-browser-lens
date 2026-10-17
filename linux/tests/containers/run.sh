#!/bin/sh
set -eu
LENS_BUNDLE=${LENS_QA_BUNDLE:-/release}
! command -v swift
! command -v node
python3 "$LENS_BUNDLE/install.py" --check
python3 linux/tests/release_smoke.py "$LENS_BUNDLE"
python3 linux/tests/service_smoke.py "$LENS_BUNDLE"
LENS_APP_DIR="$LENS_BUNDLE" LENS_SERVICE_PATH="$LENS_BUNDLE/lens-service" GDK_BACKEND=x11 GTK_THEME=Adwaita GTK_A11Y=none GIO_USE_VFS=local GSK_RENDERER=cairo xvfb-run -n 212 -s '-screen 0 1440x1100x24' dbus-run-session -- python3 linux/tests/smoke.py
python3 linux/tests/dictation_smoke.py "$LENS_BUNDLE"
