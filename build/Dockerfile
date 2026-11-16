# Builder image: runs as linux/amd64 (emulated on Apple Silicon) so the target
# rootfs's maintainer scripts run natively-for-them.
FROM debian:trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mmdebstrap ca-certificates \
      dosfstools mtools e2fsprogs fdisk \
      grub-efi-amd64-bin grub-common \
      xz-utils gpg \
 && rm -rf /var/lib/apt/lists/*

# apt hands mmdebstrap a two-digit file descriptor (`cat >&13`), which dash
# rejects under emulation ("Bad fd number"). bash handles it.
RUN ln -sf bash /bin/sh
