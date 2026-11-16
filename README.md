# Wyse3040

A reproducible Linux image that turns a **Dell Wyse 3040** thin client into a dedicated remote-desktop
client.

It's a minimal Debian 13 system that boots straight into **Remmina**, for RDP, VNC, SPICE and SSH
connections to your servers. The image is trimmed to the 3040's own hardware. This repo also has a
3D-printable [USB-C power mod](hardware/usb-c-power/).

> **Status:** the image builds, and it boots to the Remmina kiosk session under QEMU (`make test`). It
> hasn't been verified on real 3040 hardware yet. See [Not done yet](#not-done-yet).

---

## The device

The Wyse 3040 is a small, fanless x86-64 thin client from around 2016. It shipped with Wyse ThinOS or
Wyse ThinLinux. They're cheap and plentiful on the used market, and they're popular as low-power
Home Assistant, Pi-hole, kiosk and print/scan servers.

### Specs

| Component  | Detail |
|------------|--------|
| Model      | Dell Wyse 3040 (regulatory model **N10D**) |
| CPU        | Intel Atom **x5-Z8350** (Cherry Trail / Airmont), 4 cores / 4 threads, 1.44 GHz base / 1.92 GHz burst, 14 nm, ~2 W SDP |
| ISA        | x86-64 (SSE4.2, AES-NI, VT-x). **No AVX.** |
| GPU        | Intel HD Graphics 400 (Gen8, 12 EU), driven by `i915`. VA-API hardware decoding through `i965-va-driver` |
| RAM        | **2 GB** DDR3L-1600, soldered, single channel. Not upgradeable |
| Storage    | **8 GB** or **16 GB** eMMC, soldered (`/dev/mmcblk0`). No SATA or M.2 storage slot |
| Ethernet   | 1× Gigabit, Realtek RTL8111/8168 (`r8169`) |
| Wi-Fi/BT   | Optional on some SKUs; many units have none |
| Video out  | 2× DisplayPort 1.2 (dual display, DP audio) |
| USB        | Front: 1× USB 3.0, 1× USB 2.0. Rear: 2× USB 2.0 |
| Audio      | Front 3.5 mm combo jack. Cherry Trail SST audio with an Everest ES8316 codec |
| Power      | DC barrel input, **5 V or 12 V depending on the variant**. Check the label on the case or the original adapter. Draws roughly 2–4 W idle and ~7 W under load |
| Cooling    | Passive (fanless). Throttles under sustained full load |
| Firmware   | Dell UEFI (64-bit), with Secure Boot |
| Size       | Roughly 102 × 98 × 28 mm, ~240 g. VESA mount bracket available |

Approximate figures and SKU-dependent items vary between units. See
[Checking your unit](#checking-your-unit).

### Firmware / BIOS

- **F2** opens BIOS setup and **F12** opens the one-time boot menu. Press either right after power-on;
  the window is short, so tap repeatedly.
- The BIOS admin password is often set. The widely reported Dell factory default is **`Fireport`**.
- To boot your own media:
  1. Under *Boot Sequence*, enable **USB Boot**.
  2. Disable **Secure Boot**. This image's bootloader isn't signed.
  3. Leave the boot mode as **UEFI**.
- Install the latest BIOS from Dell's support site before flashing.

### Known Linux quirks

- **Power-off:** some 3040s are reported to reboot or hang instead of powering off under Linux, so test
  `poweroff` on your unit before relying on it unattended.
- **eMMC:** it's small and slow. 8 GB fills up fast, and the chip can't be replaced, so keep heavy write
  churn off it. This image keeps the journal in RAM and has no swap partition.
- **Analog audio** uses the ES8316 codec. Debian's kernel drives it with the Atom SST driver
  (`snd_soc_sst_byt_cht_es8316`), which needs `fw_sst_22a8.bin` plus UCM profiles (`alsa-ucm-conf`).
  DisplayPort audio goes through `snd_hdmi_lpe_audio`.
- **2 GB of RAM** rules out heavy desktops and big containers. zram swap helps.
- **No AVX.** Some prebuilt binaries won't run, including some ML runtimes, newer MongoDB builds, and some
  optimized Python wheels.
- **eMMC boot partitions:** the eMMC also exposes hardware boot partitions (`mmcblk0boot0/1`). Always
  write images to `mmcblk0` itself.

### Checking your unit

Boot a live Linux USB stick and run:

```bash
sudo dmidecode -t system -t bios        # model, service tag, BIOS version
lscpu
free -h
lsblk -o NAME,SIZE,TYPE,MODEL           # 8 GB or 16 GB eMMC?
lspci -nn
lsusb
ip link                                 # Wi-Fi present?
```

---

## Hardware mod: USB-C power

[`hardware/usb-c-power/`](hardware/usb-c-power/) replaces the barrel jack with USB-C. It uses a USB-C PD
trigger board ("decoy" board) held in place by a printed bracket. The folder has the Fusion 360 source,
STEP files for filament and resin printing, and photos of the build.

**Before you wire it in, set the board to your unit's rated input, 5 V or 12 V depending on the
variant, and confirm it with a multimeter.** The wrong voltage can damage the 3040.

---

## Design

- **Base:** Debian 13 "trixie". It starts from the `minbase` variant, with an explicit package list
  (`build/packages.txt`) and Recommends switched off.
- **Client:** Remmina, plus `remmina-plugin-rdp` (FreeRDP 3), `remmina-plugin-vnc` and
  `remmina-plugin-spice`. SSH support is built into Remmina.
- **Session:** X11 with **JWM** as the only window manager. No desktop environment or file manager.
  - Autologin on tty1 runs `startx`, and JWM launches Remmina, relaunching it if it quits.
  - JWM's taskbar switches between connection windows, and its menu handles reboot and power-off.
  - JWM was chosen over Openbox, which pulls in Python and Ghostscript (about 85 MB). JWM only needs
    libraries GTK already brings.
- **Built only for the 3040:**
  - **Kernel modules:** stock Debian kernel, with drivers the board can't use left out. That covers other
    GPUs, NICs other than the Realtek, SATA/NVMe/SAS, InfiniBand, TV/capture hardware and AMD audio. See
    `build/dpkg-filter.cfg`. These rules stay in the image, so kernel upgrades are trimmed the same way.
  - **Firmware:** only the RTL8168 and SST audio firmware. The HD 400 GPU needs no firmware, and Debian
    doesn't use SOF on Cherry Trail.
  - **Initramfs:** only the drivers needed to find the root filesystem.
  - **Safety check:** the build fails if any driver the 3040 needs stops resolving.
- **Graphics:** `i915` with the modesetting X driver. VA-API uses `i965-va-driver`, the Intel VA-API
  driver that supports Cherry Trail; `intel-media` starts at Broadwell.
- **No `x11-xserver-utils`,** because it drags in a C preprocessor. Screen blanking is turned off and the
  two-monitor layout is set in `/etc/X11/xorg.conf.d/` instead.
- **Audio:** PipeWire, for RDP audio redirection to DisplayPort audio or the headphone jack.
- **Memory:** zram swap (half of RAM, zstd). The only resident services are SSH, NetworkManager and
  PipeWire.
- **eMMC care:** the journal lives in RAM, the filesystem is mounted `noatime`, there's no swap partition,
  and `/tmp` is on tmpfs, which is Debian 13's default.
- **Footprint:** about 840 MiB installed, and the compressed image is about 250 MB.

### The disk image

The image is a complete GPT disk image that you write straight onto the eMMC. Nothing gets installed on
the device itself.

- **p1:** a 256 MiB EFI system partition (`WYSE-ESP`). It holds a standalone GRUB at the
  removable-media path, `\EFI\BOOT\BOOTX64.EFI`, so it boots without any firmware boot entry.
- **p2:** the ext4 root partition (`wyse-root`). It's 3 GiB in the image, which keeps flashing quick.
  On first boot it grows to fill the eMMC.
- **First boot:** SSH host keys and the machine ID are generated then, so each unit flashed from the same
  image gets its own. The hostname is the same on every unit (`wyse3040` by default); change
  `WYSE_HOSTNAME` per build if you run several.
- **Users:**
  - `wyse` logs in automatically on tty1 and runs the kiosk session. It has no password and no sudo.
  - `admin` is for SSH and has sudo. Its SSH key comes from `local/authorized_keys`, and you can add an
    optional password hash in `local/build.env`. Without a password, `admin` gets passwordless sudo.

---

## Building the image

You need Docker. Everything runs in containers, so there's nothing else to install on the host. On Apple
Silicon, the builder runs as an emulated `linux/amd64` container, and a build takes a while.

1. Give the image an admin login. The build refuses to run without one. Put your SSH public key(s) in
   `local/authorized_keys`:

   ```bash
   mkdir -p local && cp ~/.ssh/id_ed25519.pub local/authorized_keys
   ```

   Optionally, also allow password logins for `admin`:

   ```bash
   echo "WYSE_ADMIN_PASSWORD_HASH='$(openssl passwd -6)'" >> local/build.env
   ```

2. Build the image:

   ```bash
   make image
   ```

   This writes `out/wyse3040.img` (raw), `out/wyse3040.img.xz`, `out/SHA256SUMS` and
   `out/size-report.txt` (the largest packages and directories). Settings such as hostname, timezone,
   locale, keyboard layout and partition sizes are in `config/build.env`. Override them in
   `local/build.env`, which is gitignored like the rest of `local/` and `out/`.

3. Optionally, boot-test the built image in QEMU:

   ```bash
   make test
   ```

   This boots `out/wyse3040.img` in an emulated x86-64 UEFI machine, through a throwaway overlay on an
   8 GB virtual disk. It waits for a login prompt, then saves a screenshot to `out/test/screen.png` and the
   serial console log to `out/test/serial.log`.

### What goes where

| Path                      | What |
|---------------------------|------|
| `Makefile`                | `make image`, `make test`, `make clean` |
| `build/packages.txt`      | Everything installed on top of Debian minbase. Recommends are off, so list it explicitly |
| `build/dpkg-filter.cfg`   | Paths dpkg never installs: docs, translations, and drivers and firmware the 3040 can't use |
| `build/build-image.sh`    | Bootstrap → ext4 + ESP → GPT image → xz |
| `build/customize.sh`      | Runs inside the new rootfs: users, locale, sshd, services, driver check, initramfs |
| `build/test-qemu.sh`      | The QEMU boot test |
| `build/Dockerfile*`       | Builder and test containers |
| `config/build.env`        | Default build settings |
| `config/rootfs/`          | Files copied verbatim onto the device |
| `config/rootfs/usr/local/share/wyse/home/` | The kiosk user's dotfiles (`.xinitrc`, `.jwmrc`) |

## Flashing the eMMC

The eMMC is soldered to the board, so you write to it from a Linux system booted on the 3040 itself:

1. In the BIOS, enable USB boot and disable Secure Boot. See [Firmware / BIOS](#firmware--bios).
2. Boot a live Linux USB stick on the 3040. A Debian live "standard" image works.
3. Get `wyse3040.img.xz` onto the unit, and write it to `/dev/mmcblk0`. Not `mmcblk0boot0`, and not the USB
   stick. Either:
   - from a second USB stick:
     ```bash
     xzcat /media/usb/wyse3040.img.xz | sudo dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress
     ```
   - or over the network, after running `python3 -m http.server -d out` on the build machine:
     ```bash
     wget -qO- http://<build-machine-ip>:8000/wyse3040.img.xz | xzcat | sudo dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress
     ```
4. Remove the USB stick and reboot. The first boot grows the root filesystem, then Remmina comes up.
5. Connect over SSH with `ssh admin@<ip-address>`. `ssh admin@wyse3040` also works if your router
   registers DHCP hostnames in DNS.

You can also `dd` the raw image onto a USB stick and boot the 3040 from that to try it first. Don't boot
that stick once the eMMC also holds the image, though: both carry the same `wyse-root` label, and GRUB may
pick either one.

### On the device

- **Menu:** right-click the desktop, or click **Menu** on the taskbar, for Remmina, Terminal, Reboot and
  Power off. Alt+Tab switches windows, and Alt+F4 closes one.
- **Debugging:** the second GRUB entry, *verbose, no X*, boots without the graphical session and leaves a
  shell on tty1.
- **Two monitors:** edit `/etc/X11/xorg.conf.d/20-wyse-displays.conf`, or its copy under
  `config/rootfs/` in the repo. It assumes the outputs are named `DP-1` and `DP-2`.
- **If X dies,** tty1 drops to a shell as `wyse`.
- **Installing packages:** package lists are removed from the image to save space, so run
  `sudo apt update` first.

## Not done yet

- **Real hardware:** none of this has run on a 3040 yet. Still to check: eMMC boot, first-boot resize,
  `DP-1`/`DP-2` output names, analog and DisplayPort audio, VA-API decoding, and `poweroff`.
- **Wi-Fi:** no Wi-Fi firmware is included yet, pending a unit that has Wi-Fi.
- **Peripherals:** USB smart card support (`pcscd`) and USB redirection.
- **Lockdown:** a read-only root filesystem, and no shell when X exits.
- **Install:** a self-flashing USB installer, so you don't need a separate live system.

## Layout

```
Wyse3040/
├── README.md
├── LICENSE            # GPL-3.0 (hardware/ is CERN-OHL-S-2.0)
├── Makefile           # make image | make test | make clean
├── build/             # builder/test containers and scripts
├── config/
│   ├── build.env      # default build settings
│   └── rootfs/        # overlay copied onto the device
├── hardware/
│   └── usb-c-power/   # USB-C power mod: Fusion 360 source, STEP files, photos
├── local/             # (gitignored) authorized_keys, build.env overrides
└── out/               # (gitignored) built images, test output
```

---

## Licence

Copyright © 2026 George Stephanis.

- **Software:** the build scripts, configuration and documentation are licensed under the
  [GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).
- **Hardware:** the printable designs in [`hardware/`](hardware/) are licensed under the
  [CERN Open Hardware Licence v2 – Strongly Reciprocal](hardware/usb-c-power/LICENSE)
  (CERN-OHL-S-2.0), which is the GPL-style licence for hardware designs.
