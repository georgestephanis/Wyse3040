BUILDER := wyse3040-builder
QEMU    := wyse3040-qemu

.PHONY: image builder qemu test test-installer clean

## Build out/wyse3040.img, out/wyse3040.img.xz and out/wyse3040-installer.iso
image: builder
	mkdir -p out
	docker run --rm --privileged --platform linux/amd64 \
	  -v "$(CURDIR)":/src:ro -v "$(CURDIR)/out":/out \
	  $(BUILDER) /src/build/build-image.sh

builder:
	docker build --platform linux/amd64 -t $(BUILDER) -f build/Dockerfile build

qemu:
	docker build -t $(QEMU) -f build/Dockerfile.qemu build

## Boot the built image in QEMU; writes out/test/serial.log and out/test/screen.png
test: qemu
	docker run --rm -v "$(CURDIR)":/src:ro -v "$(CURDIR)/out":/out \
	  $(QEMU) /src/build/test-qemu.sh

## Install with the installer ISO in QEMU, boot the result, and boot the ISO itself;
## writes logs and screenshots to out/test-installer/
test-installer: qemu
	docker run --rm -v "$(CURDIR)":/src:ro -v "$(CURDIR)/out":/out \
	  $(QEMU) /src/build/test-installer.sh

clean:
	rm -rf out
