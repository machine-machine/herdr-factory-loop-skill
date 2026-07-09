HOST_GOOS  := $(shell go env GOOS 2>/dev/null)
HOST_GOARCH:= $(shell go env GOARCH 2>/dev/null)
LDFLAGS    := -s -w
TARGETS    := darwin-amd64 darwin-arm64 linux-amd64 linux-arm64

.PHONY: tui tui-release release-check check-go lint test ci

check-go:
	@command -v go >/dev/null 2>&1 || { echo "error: go not found on PATH — install Go (https://go.dev/dl/) to build the TUI"; exit 1; }

# host build — quick iteration loop
tui: check-go
	mkdir -p prebuilt
	go build -C tui -o ../prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH) .

# cross-compiled release set + a copy of the host build for immediate use
tui-release: check-go
	mkdir -p prebuilt
	set -e; for t in $(TARGETS); do \
		echo "building m2herd-tui-$$t"; \
		GOOS=$${t%-*} GOARCH=$${t#*-} CGO_ENABLED=0 \
			go build -C tui -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$$t . ; \
	done
	CGO_ENABLED=0 go build -C tui -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH) .

# release gate: rebuild every target, then prove the host binary actually
# renders (--once against a throwaway .m2herd fixture)
release-check: tui-release
	@set -e; \
	tmp=$$(mktemp -d); \
	( cd "$$tmp" && git init -q && \
	  bash "$(CURDIR)/scripts/m2herd.sh" init --goal "release-check fixture" >/dev/null ); \
	"$(CURDIR)/prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH)" --once --dir "$$tmp"; \
	rm -rf "$$tmp"; \
	echo "release-check: OK"

lint:
	bash scripts/lint.sh

test:
	bash scripts/m2herd.sh selftest

# ci — the documented pre-commit check: the same steps CI runs
# (.github/workflows/ci.yml). Go steps run only when go is on PATH.
ci:
	@set -e; \
	for f in scripts/*.sh hooks/*.sh; do bash -n "$$f" || exit 1; done; \
	echo "ok: bash -n scripts/*.sh hooks/*.sh"
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "+ shellcheck -S warning scripts/*.sh hooks/*.sh"; \
		shellcheck -S warning scripts/*.sh hooks/*.sh; \
	else \
		echo "skip: shellcheck not on PATH — shellcheck skipped (CI runs it)"; \
	fi
	bash scripts/lint.sh
	bash scripts/m2herd.sh selftest
	bash hooks/smoke.sh
	@if command -v go >/dev/null 2>&1; then \
		echo "+ go build ./... && go vet ./... (tui/)"; \
		go build -C tui ./... && go vet -C tui ./...; \
	else \
		echo "skip: go not on PATH — go build/vet skipped (CI runs them)"; \
	fi
