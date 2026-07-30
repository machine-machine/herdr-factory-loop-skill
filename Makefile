HOST_GOOS  := $(shell go env GOOS 2>/dev/null)
HOST_GOARCH:= $(shell go env GOARCH 2>/dev/null)
LDFLAGS    := -s -w
# Reproducibility flags — without BOTH of these, a binary built here and a binary
# built in CI from the same commit differ, which made the release workflow's
# "prebuilt-rot guard" unable to actually cross-check anything:
#   -trimpath        strips absolute build paths (/home/you/... vs /home/runner/work/...)
#   -buildvcs=false  drops the embedded git revision/time/dirty stamp. A committed
#                    prebuilt is necessarily built BEFORE the commit containing it
#                    exists, so stamping can never agree with a CI build of that commit.
# Verified: identical sha256 from three different checkout paths.
REPRO      := -trimpath -buildvcs=false
TARGETS    := darwin-amd64 darwin-arm64 linux-amd64 linux-arm64

.PHONY: tui tui-release release-check prebuilt-check check-go lint test ci

check-go:
	@command -v go >/dev/null 2>&1 || { echo "error: go not found on PATH — install Go (https://go.dev/dl/) to build the TUI"; exit 1; }

# host build — quick iteration loop
tui: check-go
	mkdir -p prebuilt
	CGO_ENABLED=0 go build -C tui $(REPRO) -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH) .

# cross-compiled release set + a copy of the host build for immediate use
tui-release: check-go
	mkdir -p prebuilt
	set -e; for t in $(TARGETS); do \
		echo "building m2herd-tui-$$t"; \
		GOOS=$${t%-*} GOARCH=$${t#*-} CGO_ENABLED=0 \
			go build -C tui $(REPRO) -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$$t . ; \
	done
	CGO_ENABLED=0 go build -C tui $(REPRO) -ldflags "$(LDFLAGS)" -o ../prebuilt/m2herd-tui-$(HOST_GOOS)-$(HOST_GOARCH) .

# prebuilt-rot guard, for real this time: rebuild every target into a scratch dir
# and byte-compare against the committed set. This is what makes `prebuilt/` a
# verifiable artifact rather than a promise — it only works because $(REPRO)
# makes the build reproducible across machines and paths.
prebuilt-check: check-go
	@set -e; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	drift=""; \
	for t in $(TARGETS); do \
		GOOS=$${t%-*} GOARCH=$${t#*-} CGO_ENABLED=0 \
			go build -C tui $(REPRO) -ldflags "$(LDFLAGS)" -o "$$tmp/m2herd-tui-$$t" . ; \
		if [ ! -f "prebuilt/m2herd-tui-$$t" ]; then \
			echo "MISSING prebuilt/m2herd-tui-$$t"; drift="$$drift $$t"; continue; \
		fi; \
		a=$$(sha256sum < "$$tmp/m2herd-tui-$$t" | cut -d' ' -f1); \
		b=$$(sha256sum < "prebuilt/m2herd-tui-$$t" | cut -d' ' -f1); \
		if [ "$$a" = "$$b" ]; then echo "ok: m2herd-tui-$$t matches ($$a)"; \
		else echo "DRIFT: m2herd-tui-$$t committed=$$b rebuilt=$$a"; drift="$$drift $$t"; fi; \
	done; \
	if [ -n "$$drift" ]; then \
		echo "prebuilt-check: FAILED —$$drift differ from a fresh build. Run 'make tui-release' and commit prebuilt/."; \
		exit 1; \
	fi; \
	echo "prebuilt-check: OK — all $(words $(TARGETS)) targets reproduce byte-for-byte"

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
		echo "+ go build ./... && go vet ./... && go test ./... (tui/)"; \
		go build -C tui ./... && go vet -C tui ./... && go test -C tui ./...; \
		echo "+ make prebuilt-check (committed prebuilt/ must match a fresh build)"; \
		$(MAKE) --no-print-directory prebuilt-check; \
	else \
		echo "skip: go not on PATH — go build/vet/test/prebuilt-check skipped (CI runs them)"; \
	fi
