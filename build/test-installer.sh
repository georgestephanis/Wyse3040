#!/bin/bash
# Test out/wyse3040-installer.iso in emulated x86-64 machines. Runs inside the
# qemu test container (see Makefile), in three stages:
#
#   1. Unattended install, Ventoy-style: the ISO is a *file* on a FAT32 "USB
#      drive", and the ISO's kernel + installer initrd are booted directly with
#      wyse.target=/dev/vda wyse.yes. The installer has to find and loop-mount
#      the ISO file, then write the image to a blank 8 GB disk. Pass = it
#      reports a verified write.
#   2. Boot the freshly installed disk (UEFI) to a login prompt.
#   3. Boot the ISO itself as a USB stick (UEFI -> GRUB menu -> installer).
#      The installer should find its image on the stick's ISO filesystem,
#      then stop at "No internal eMMC found" (QEMU has none) without writing
#      anything. Screenshots show each step.
set -euo pipefail

ISO=/out/wyse3040-installer.iso
T=/out/test-installer
OVMF=/usr/share/ovmf/OVMF.fd
rm -rf "$T"; mkdir -p "$T"

mon() { echo "$*" | socat - UNIX-CONNECT:/tmp/mon.sock >/dev/null; }
shot() { mon screendump "$T/$1" -f png; echo "  screenshot: out/test-installer/$1"; }

echo "== Extracting kernel, installer initrd and build ID from the ISO"
for f in vmlinuz installer.img build-id; do
  xorriso -osirrox on -indev "$ISO" -extract "/live/$f" "/tmp/$f" >/dev/null 2>&1
done
BUILD_ID=$(cat /tmp/build-id)
echo "  build ID: $BUILD_ID"

echo "== Stage 1: unattended install from an ISO file on a FAT32 drive"
iso_mb=$(( $(stat -c %s "$ISO") / 1048576 ))
mkfs.vfat -C -F 32 -n USBDRIVE /tmp/usbdrive.img $(( (iso_mb + 128) * 1024 )) >/dev/null
mcopy -i /tmp/usbdrive.img "$ISO" ::/wyse3040-installer.iso
qemu-img create -q -f qcow2 /tmp/target.qcow2 8G
start=$(date +%s)
qemu-system-x86_64 \
  -machine q35 -m 2048 -smp 2 -no-reboot \
  -kernel /tmp/vmlinuz -initrd /tmp/installer.img \
  -append "boot=wyseinstall wyse.build=$BUILD_ID wyse.target=/dev/vda wyse.yes console=ttyS0,115200" \
  -drive file=/tmp/target.qcow2,if=virtio,format=qcow2 \
  -drive file=/tmp/usbdrive.img,if=virtio,format=raw,readonly=on \
  -display none -serial "file:$T/install.log" &
pid=$!
# The installer powers off when it's done, or drops to a shell on an error.
while kill -0 "$pid" 2>/dev/null; do
  if grep -q 'ERROR:' "$T/install.log" 2>/dev/null || [ $(( $(date +%s) - start )) -ge 3600 ]; then
    kill "$pid"; break
  fi
  sleep 5
done
wait "$pid" || true
if grep -q 'wyse-installer: verified /dev/vda' "$T/install.log"; then
  echo "  PASS: written and verified in $(( $(date +%s) - start ))s"
else
  echo "  FAIL: see out/test-installer/install.log"; tail -20 "$T/install.log"; exit 1
fi

echo "== Stage 2: boot the installed disk"
qemu-system-x86_64 \
  -machine q35 -m 2048 -smp 2 -bios "$OVMF" \
  -drive file=/tmp/target.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display none -serial "file:$T/installed-boot.log" \
  -monitor unix:/tmp/mon.sock,server,nowait &
pid=$!
start=$(date +%s)
until grep -q 'login:' "$T/installed-boot.log" 2>/dev/null; do
  kill -0 "$pid" 2>/dev/null || { echo "  FAIL: QEMU exited"; exit 1; }
  [ $(( $(date +%s) - start )) -lt 900 ] || { echo "  FAIL: no login prompt"; shot installed-timeout.png; mon quit; exit 1; }
  sleep 5
done
echo "  PASS: login prompt after $(( $(date +%s) - start ))s"
sleep 60
shot installed-desktop.png
mon quit; wait "$pid" || true

echo "== Stage 3: boot the ISO as a USB stick"
qemu-img create -q -f qcow2 /tmp/blank.qcow2 8G
qemu-system-x86_64 \
  -machine q35 -m 2048 -smp 2 -bios "$OVMF" \
  -device qemu-xhci \
  -drive if=none,id=stick,file="$ISO",format=raw,readonly=on \
  -device usb-storage,drive=stick,bootindex=0 \
  -drive file=/tmp/blank.qcow2,if=virtio,format=qcow2 \
  -vga std -display none -serial "file:$T/iso-boot.log" \
  -monitor unix:/tmp/mon.sock,server,nowait &
pid=$!
sleep "${MENU_WAIT:-60}"
shot iso-1-menu.png
mon sendkey ret
for i in 2 3 4; do
  sleep "${STEP_WAIT:-120}"
  shot "iso-$i-installer.png"
done
mon quit; wait "$pid" || true
echo "Done. Logs and screenshots are in out/test-installer/"
