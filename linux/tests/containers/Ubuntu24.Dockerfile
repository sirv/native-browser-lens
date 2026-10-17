FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-gi python3-cairo python3-gi-cairo gir1.2-gtk-4.0 gir1.2-gst-plugins-base-1.0 gir1.2-soup-3.0 gir1.2-xdp-1.0 gir1.2-ayatanaappindicator3-0.1 gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav gstreamer1.0-pipewire libgtk-4-media-gstreamer libgles2 ffmpeg libsecret-tools xdg-desktop-portal dbus-x11 xvfb xauth imagemagick espeak-ng fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /home/lens && chown 1000:1000 /home/lens
USER 1000:1000
ENV HOME=/home/lens
WORKDIR /work
