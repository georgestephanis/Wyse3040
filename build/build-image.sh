#!/bin/bash
# Build a flashable GPT disk image for the Dell Wyse 3040.
# Runs inside the builder container (see Makefile), as root, --privileged.
#
#   /src   this repo (read-only)
#   /out   output directory
#
# Layout:  p1 = EFI system partition (FAT32, label WYSE-ESP)
#          p2 = root (ext4, label wyse-root), grown to fill the eMMC on first boot
#
# No loop devices are used: the filesystems are built as files (mkfs.ext4 -d,
# mtools) and spliced into the disk image with dd.
set -euo pipefail

SRC=/src
OUT=/out
WORK=/work
LOCAL=$SRC/local

log() { printf '\n==> %s\n' "$*"; }

set -a
# shellcheck source=../config/build.env
. "$SRC/config/build.env"
[ -f "$LOCAL/build.env" ] && . "$LOCAL/build.env"
set +a

# --- Refuse to build an image nobody can administer -------------------------
if [ ! -s "$LOCAL/authorized_keys" ] && [ -z "${WYSE_ADMIN_PASSWORD_HASH:-}" ]; then
  echo "ERROR: no admin access configured." >&2
  echo "  Put SSH public key(s) in local/authorized_keys, and/or set" >&2
  echo "  WYSE_ADMIN_PASSWORD_HASH in local/build.env (openssl passwd -6)." >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/stage" "$OUT"

# --- Stage the rootfs overlay with root ownership ---------------------------
log "Staging config overlay"
cp -a "$SRC/config/rootfs" "$WORK/overlay"
chown -R 0:0 "$WORK/overlay"
cp "$SRC/build/customize.sh" "$WORK/stage/customize.sh"
if [ -s "$LOCAL/authorized_keys" ]; then
  cp "$LOCAL/authorized_keys" "$WORK/stage/authorized_keys"
fi

PACKAGES=$(grep -Ev '^\s*(#|$)' "$SRC/build/packages.txt" | xargs | tr ' ' ',')
COMPONENTS="main contrib non-free non-free-firmware"

# --- Bootstrap the root filesystem ------------------------------------------
log "Bootstrapping Debian $WYSE_SUITE (this takes a while under emulation)"
mmdebstrap \
  --mode=root \
  --variant=minbase \
  --architectures=amd64 \
  --aptopt='APT::Install-Recommends "false"' \
  --dpkgopt="$SRC/build/dpkg-filter.cfg" \
  --include="$PACKAGES" \
  --customize-hook="sync-in $WORK/overlay /" \
  --customize-hook='mkdir -p "$1/tmp/wyse-stage"' \
  --customize-hook="sync-in $WORK/stage /tmp/wyse-stage" \
  --customize-hook='chroot "$1" /bin/bash /tmp/wyse-stage/customize.sh' \
  --customize-hook='rm -rf "$1/tmp/wyse-stage"' \
  "$WYSE_SUITE" "$WORK/rootfs" \
  "deb $WYSE_MIRROR $WYSE_SUITE $COMPONENTS" \
  "deb $WYSE_MIRROR $WYSE_SUITE-updates $COMPONENTS" \
  "deb http://security.debian.org/debian-security $WYSE_SUITE-security $COMPONENTS"

# What's taking up space, for trimming further.
{
  echo "== Largest packages (installed KiB)"
  chroot "$WORK/rootfs" dpkg-query -Wf '${Installed-Size}\t${Package}\n' | sort -rn | head -40
  echo; echo "== Largest directories (MiB)"
  du -xm --max-depth=4 "$WORK/rootfs/usr" | sort -rn | head -40 | sed "s|$WORK/rootfs||"
  echo; echo "== /boot"; ls -l "$WORK/rootfs/boot"
} > "$OUT/size-report.txt"

# Sanity: GRUB's config boots the stable /vmlinuz and /initrd.img symlinks.
for f in vmlinuz initrd.img; do
  [ -e "$WORK/rootfs/$f" ] || { echo "ERROR: /$f missing in rootfs" >&2; exit 1; }
done

used_mb=$(du -sm "$WORK/rootfs" | cut -f1)
log "Root filesystem uses ${used_mb} MiB (partition: ${WYSE_ROOT_MB} MiB)"
if [ "$used_mb" -gt $((WYSE_ROOT_MB * 85 / 100)) ]; then
  echo "ERROR: rootfs too large for WYSE_ROOT_MB=$WYSE_ROOT_MB" >&2
  exit 1
fi

# --- Root partition image ----------------------------------------------------
log "Creating ext4 root filesystem"
mkfs.ext4 -q -F -L wyse-root -d "$WORK/rootfs" "$WORK/root.img" "${WYSE_ROOT_MB}M"

# --- EFI system partition ----------------------------------------------------
# A standalone GRUB at the removable-media path (\EFI\BOOT\BOOTX64.EFI), so
# no NVRAM boot entry is needed: the image boots wherever it's written.
log "Creating EFI system partition"
# The partition-table and filesystem drivers are preloaded: a standalone GRUB
# keeps its modules in a memdisk and won't autoload them for `search`. If the
# search fails, stop with a message instead of re-reading this same file forever.
cat > "$WORK/grub-embedded.cfg" <<'EOF'
if search --no-floppy --label wyse-root --set=root; then
  configfile ($root)/boot/grub/grub.cfg
else
  echo "Wyse 3040: no partition labelled wyse-root found."
fi
EOF
grub-mkstandalone -O x86_64-efi \
  --modules="part_gpt part_msdos ext2 fat search search_label configfile normal linux all_video" \
  --locales="" --themes="" --fonts="" \
  -o "$WORK/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$WORK/grub-embedded.cfg"

mkfs.vfat -C -F 32 -n WYSE-ESP "$WORK/esp.img" $((WYSE_ESP_MB * 1024)) >/dev/null
mmd   -i "$WORK/esp.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK/esp.img" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# --- Assemble the GPT disk image ---------------------------------------------
log "Assembling disk image"
IMG="$OUT/wyse3040.img"
total_mb=$((1 + WYSE_ESP_MB + WYSE_ROOT_MB + 1))
rm -f "$IMG" "$IMG.xz"
truncate -s "${total_mb}M" "$IMG"
sfdisk --quiet "$IMG" <<EOF
label: gpt
start=1MiB, size=${WYSE_ESP_MB}MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
start=$((1 + WYSE_ESP_MB))MiB, size=${WYSE_ROOT_MB}MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="wyse-root"
EOF
dd if="$WORK/esp.img"  of="$IMG" bs=1M seek=1                   conv=notrunc,sparse status=none
dd if="$WORK/root.img" of="$IMG" bs=1M seek=$((1 + WYSE_ESP_MB)) conv=notrunc,sparse status=none
sfdisk --list "$IMG"

log "Compressing"
xz -T0 -6 -k "$IMG"
( cd "$OUT" && sha256sum wyse3040.img wyse3040.img.xz > SHA256SUMS )
ls -lh "$OUT"
log "Done: out/wyse3040.img(.xz)"
