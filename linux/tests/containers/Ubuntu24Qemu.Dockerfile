FROM native-browser-lens-qa:ubuntu24
USER root
RUN apt-get update && apt-get install -y --no-install-recommends qemu-user && rm -rf /var/lib/apt/lists/*
USER 1000:1000
