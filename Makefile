HOST_GOOS  := $(shell go env GOOS)
HOST_GOARCH:= $(shell go env GOARCH)
LDFLAGS    := -s -w
TARGETS    := darwin-arm64 linux-amd64 linux-arm64

.PHONY: tui tui-release

# host build — quick iteration loop
tui:
	mkdir -p prebuilt
	go -C tui build -o ../prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH) .

# cross-compiled release set + a copy of the host build for immediate use
tui-release:
	mkdir -p prebuilt
	$(foreach t,$(TARGETS), \
		GOOS=$(word 1,$(subst -, ,$(t))) GOARCH=$(word 2,$(subst -, ,$(t))) CGO_ENABLED=0 \
			go -C tui build -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$(t) . ;)
	CGO_ENABLED=0 go -C tui build -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH) .
