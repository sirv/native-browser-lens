# Fresh-distribution runtime checks

These disposable images contain the installer's desktop dependency packages and a few test tools. They contain neither Swift nor Node.js. The runtime check installs the actual precompiled bundle for an unprivileged user, exercises update/rollback and notebook preservation, runs the GTK workflow including real video decoding, and recognizes synthetic English with the bundled offline engine.

From the repository root, after building a release:

```sh
docker build -f linux/tests/containers/Ubuntu24.Dockerfile -t native-browser-lens-qa:ubuntu24 linux/tests/containers
docker build -f linux/tests/containers/Fedora44.Dockerfile -t native-browser-lens-qa:fedora44 linux/tests/containers
mkdir -p .build/ubuntu24-output .build/fedora44-output
docker run --rm -v "$PWD:/work:ro" -v "$PWD/dist/releases/native-browser-lens-0.10.3-linux-x86_64:/release:ro" -v "$PWD/.build/ubuntu24-output:/work/.build:rw" native-browser-lens-qa:ubuntu24 sh linux/tests/containers/run.sh
docker run --rm -v "$PWD:/work:ro" -v "$PWD/dist/releases/native-browser-lens-0.10.3-linux-x86_64:/release:ro" -v "$PWD/.build/fedora44-output:/work/.build:rw" native-browser-lens-qa:fedora44 sh linux/tests/containers/run.sh
```

Adjust the release folder for a later version. The bind-mounted output directories must be writable by the container's UID 1000. There is no privileged mode, Docker socket mount, host session bus or home-directory mount. Only the named output directory is writable. The app's notebook, browser registrations and rollback copies live in temporary container directories.

Xvfb and a private D-Bus session stand in for a desktop. Portal, FUSE and device warnings are expected in this container boundary. These checks do not prove physical microphone quality, compositor shortcuts, window-picker permissions, a browser-store install or production VibeQ filing. They do catch missing GI typelibs, H.264 encoders/parsers/decoders and media graphics libraries that a development machine can hide.
