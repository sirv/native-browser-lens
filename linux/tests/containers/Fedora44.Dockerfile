FROM registry.fedoraproject.org/fedora:44
RUN dnf -y --setopt=install_weak_deps=False install python3-gobject python3-cairo gobject-introspection gtk4 libglvnd-gles gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugin-libav pipewire-gstreamer libportal libsoup3 libsecret libayatana-appindicator-gtk3 ffmpeg-free xdg-desktop-portal gstreamer1-plugin-openh264 openh264 dbus-x11 xorg-x11-server-Xvfb xorg-x11-xauth ImageMagick espeak-ng dejavu-sans-fonts && dnf clean all
RUN useradd -m -u 1000 lens
USER 1000:1000
ENV HOME=/home/lens
WORKDIR /work
