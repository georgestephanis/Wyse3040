#!/bin/bash
# Runs inside the target rootfs (chroot) at the end of mmdebstrap.
# The config/rootfs overlay has already been copied in.
# WYSE_* settings come from config/build.env (+ local/build.env).
set -euo pipefail

STAGE=/tmp/wyse-stage

# --- Identity / locale ------------------------------------------------------
echo "$WYSE_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	$WYSE_HOSTNAME
::1		localhost ip6-localhost ip6-loopback
EOF

ln -sf "/usr/share/zoneinfo/$WYSE_TIMEZONE" /etc/localtime
echo "$WYSE_TIMEZONE" > /etc/timezone

sed -i "s/^# *\($WYSE_LOCALE\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$WYSE_LOCALE" > /etc/default/locale

cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$WYSE_XKB_LAYOUT"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

mkdir -p /boot/efi

# --- Users -------------------------------------------------------------------
passwd -l root

# "wyse": the kiosk user that autologins on tty1. No password, no sudo.
groups=$(for g in audio video render input; do getent group "$g" >/dev/null && printf '%s,' "$g"; done)
useradd -m -s /bin/bash -G "${groups%,}" wyse
passwd -l wyse
cp -a /usr/local/share/wyse/home/. /home/wyse/
chown -R wyse:wyse /home/wyse
# Fail the build on a broken window-manager config rather than on the device.
su -s /bin/sh wyse -c 'jwm -p'

# "admin": remote administration over SSH, with sudo.
useradd -m -s /bin/bash -G sudo admin
if [ -n "${WYSE_ADMIN_PASSWORD_HASH:-}" ]; then
  usermod -p "$WYSE_ADMIN_PASSWORD_HASH" admin
else
  passwd -l admin
  echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin
  chmod 0440 /etc/sudoers.d/admin
fi

ssh_password=yes
if [ -s "$STAGE/authorized_keys" ]; then
  install -d -m 0700 -o admin -g admin /home/admin/.ssh
  install -m 0600 -o admin -g admin "$STAGE/authorized_keys" /home/admin/.ssh/authorized_keys
  ssh_password=no
fi
cat > /etc/ssh/sshd_config.d/10-wyse.conf <<EOF
PermitRootLogin no
AllowUsers admin
PasswordAuthentication $ssh_password
KbdInteractiveAuthentication no
EOF

# --- Services ----------------------------------------------------------------
systemctl enable wyse-firstboot.service NetworkManager.service systemd-timesyncd.service
systemctl set-default multi-user.target
# Don't let systemd-firstboot prompt on the console of a freshly flashed unit.
systemctl mask systemd-firstboot.service

# --- Check that trimming (dpkg-filter.cfg) kept everything the 3040 needs ------
kver=$(ls /usr/lib/modules | sort -V | tail -1)
needed="i915 r8169 sdhci_acpi mmc_block ext4 vfat
        xhci_pci usb_storage uas sd_mod usbhid hid_generic
        snd_intel_sst_acpi snd_soc_sst_byt_cht_es8316 snd_hdmi_lpe_audio
        virtio_pci virtio_blk"
missing=""
for m in $needed; do
  modprobe -S "$kver" --show-depends "$m" >/dev/null 2>&1 || missing="$missing $m"
done
if [ -n "$missing" ]; then
  echo "ERROR: kernel modules missing after trimming:$missing" >&2
  exit 1
fi
grep -E '^CONFIG_(PINCTRL_CHERRYVIEW|MMC_SDHCI_ACPI|MMC_BLOCK)=' "/boot/config-$kver"

# --- Initramfs -----------------------------------------------------------------
# Only the drivers needed to find the root filesystem, instead of "most":
# eMMC, USB sticks (for booting the image from USB), and virtio for `make test`.
echo 'RESUME=none' > /etc/initramfs-tools/conf.d/resume
echo 'MODULES=list' > /etc/initramfs-tools/conf.d/wyse.conf
cat >> /etc/initramfs-tools/modules <<'EOF'
sdhci_acpi
sdhci_pci
mmc_block
ext4
xhci_pci
ehci_pci
usb_storage
uas
sd_mod
usbhid
hid_generic
virtio_pci
virtio_blk
EOF
update-initramfs -u -k all

# --- Per-device state is generated on first boot -------------------------------
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin
