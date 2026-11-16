BUILDER := wyse3040-builder
QEMU    := wyse3040-qemu

.PHONY: image builder test clean

## Build out/wyse3040.img and out/wyse3040.img.xz
image: builder
	mkdir -p out
	docker run --rm --privileged --platform linux/amd64 \
	  -v "$(CURDIR)":/src:ro -v "$(CURDIR)/out":/out \
	  $(BUILDER) /src/build/build-image.sh

builder:
	docker build --platform linux/amd64 -t $(BUILDER) -f build/Dockerfile build

## Boot the built image in QEMU; writes out/test/serial.log and out/test/screen.png
test:
	docker build -t $(QEMU) -f build/Dockerfile.qemu build
	docker run --rm -v "$(CURDIR)":/src:ro -v "$(CURDIR)/out":/out \
	  $(QEMU) /src/build/test-qemu.sh

clean:
	rm -rf out
