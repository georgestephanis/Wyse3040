#!/bin/bash
# Boot out/wyse3040.img in an emulated x86-64 UEFI machine and take a screenshot.
# Runs inside the qemu test container (see Makefile). The image itself is not
# modified: writes go to a throwaway qcow2 overlay, sized like an 8 GB eMMC so
# the first-boot root resize is exercised too.
set -euo pipefail

IMG=/out/wyse3040.img
T=/out/test
TIMEOUT=${TIMEOUT:-900}
mkdir -p "$T"
rm -f "$T"/serial.log "$T"/screen.png

qemu-img create -q -f qcow2 -F raw -b "$IMG" /tmp/disk.qcow2 8G

qemu-system-x86_64 \
  -machine q35 -m 2048 -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=/tmp/disk.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display none \
  -serial "file:$T/serial.log" \
  -monitor unix:/tmp/mon.sock,server,nowait &
QEMU_PID=$!

mon() { echo "$*" | socat - UNIX-CONNECT:/tmp/mon.sock >/dev/null; }

echo "Waiting for a login prompt on the serial console (timeout ${TIMEOUT}s)..."
start=$(date +%s)
until grep -q 'login:' "$T/serial.log" 2>/dev/null; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then echo "QEMU exited early"; exit 1; fi
  if [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ]; then
    echo "TIMEOUT waiting for login prompt"; mon screendump "$T/screen.png" -f png; mon quit; exit 1
  fi
  sleep 5
done
echo "Login prompt after $(( $(date +%s) - start ))s; giving X/Remmina time to start..."
sleep "${SETTLE:-90}"
mon screendump "$T/screen.png" -f png
sleep 2
mon quit
wait "$QEMU_PID" || true
echo "Serial log: out/test/serial.log   Screenshot: out/test/screen.png"
