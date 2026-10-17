#!/bin/bash
set -euo pipefail
LENS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LENS_REPO"
pkg-config --exists gtk4 sqlite3 openssl || { echo 'Install GTK 4, SQLite and OpenSSL development packages.' >&2; exit 1; }
python3 -c 'import gi, cairo; gi.require_version("Gtk", "4.0"); gi.require_version("Gst", "1.0"); gi.require_version("Soup", "3.0"); gi.require_version("Xdp", "1.0"); from gi.repository import Gtk, Gst, Soup, Xdp'
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("AyatanaAppIndicator3", "0.1"); from gi.repository import Gtk, AyatanaAppIndicator3'
for element in pipewiresrc pulsesrc videoconvert videoscale videorate jpegenc appsink; do
    gst-inspect-1.0 "$element" >/dev/null || { echo "Missing GStreamer element: $element" >&2; exit 1; }
done
python3 -c 'import sys; sys.path.insert(0,"linux"); import video_codecs; assert video_codecs.encoder() and video_codecs.decoder(), "Install an FFmpeg H.264 encoder and GStreamer H.264 decoder."'
swift build --configuration release
LENS_BIN="$(swift build --configuration release --show-bin-path)"
npm --prefix extension run build
LENS_LINUX="$LENS_REPO/dist/linux"
mkdir -p "$LENS_LINUX"
cp "$LENS_BIN/lens-host" "$LENS_BIN/lens-service" "$LENS_BIN/lens-evidence" "$LENS_LINUX/"
cp linux/*.py "$LENS_LINUX/"
cp linux/reproduce.mjs "$LENS_LINUX/"
cp scripts/install-linux.py "$LENS_LINUX/install.py"
rm -rf "$LENS_LINUX/extension"
cp -R extension/dist "$LENS_LINUX/extension"
rm -rf "$LENS_LINUX/extension-firefox"
cp -R extension/dist-firefox "$LENS_LINUX/extension-firefox"
echo "$LENS_LINUX"
