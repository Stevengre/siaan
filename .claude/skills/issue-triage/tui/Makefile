.PHONY: all check print-env scan fmt lint test coverage deny fuzz build install clean

SCRIPTS_DIR := ../scripts
BIN_NAME := issue-tui

# Default: full CI check
all: check

# Run all checks (env + escape-hatch scan + format + lint + test + coverage + dependency audit + release build)
check: print-env scan fmt lint test coverage deny build

print-env:
	@echo "RUSTFLAGS=$${RUSTFLAGS-}"
	@echo "CARGO_ENCODED_RUSTFLAGS=$${CARGO_ENCODED_RUSTFLAGS-}"
	@echo "RUSTDOCFLAGS=$${RUSTDOCFLAGS-}"
	@echo "CARGO_ENCODED_RUSTDOCFLAGS=$${CARGO_ENCODED_RUSTDOCFLAGS-}"

scan:
	@set -eu; \
	if command -v rg >/dev/null 2>&1; then \
		! rg -n '#!\[allow\(' . --glob '!target/**' --glob '!.git/**' --glob '!Cargo.lock' --glob '!Makefile'; \
		! rg -n '#\[allow\(' . --glob '!target/**' --glob '!.git/**' --glob '!Cargo.lock' --glob '!Makefile'; \
		! rg -n 'cfg_attr\s*\(' . --glob '!target/**' --glob '!.git/**' --glob '!Cargo.lock' --glob '!Makefile'; \
		! rg -n 'include!\s*\(' . --glob '!target/**' --glob '!.git/**' --glob '!Cargo.lock' --glob '!Makefile'; \
		! rg -n '\bunsafe\b' . --glob '!target/**' --glob '!.git/**' --glob '!Cargo.lock' --glob '!Makefile'; \
	else \
		! grep -RInE '#!\[allow\(' . --exclude-dir=target --exclude-dir=.git --exclude=Cargo.lock --exclude=Makefile; \
		! grep -RInE '#\[allow\(' . --exclude-dir=target --exclude-dir=.git --exclude=Cargo.lock --exclude=Makefile; \
		! grep -RInE 'cfg_attr[[:space:]]*\(' . --exclude-dir=target --exclude-dir=.git --exclude=Cargo.lock --exclude=Makefile; \
		! grep -RInE 'include![[:space:]]*\(' . --exclude-dir=target --exclude-dir=.git --exclude=Cargo.lock --exclude=Makefile; \
		! grep -RInE '(^|[^[:alnum:]_])unsafe([^[:alnum:]_]|$$)' . --exclude-dir=target --exclude-dir=.git --exclude=Cargo.lock --exclude=Makefile; \
	fi

# Format check (fails if not formatted)
fmt:
	cargo fmt --all --check

# Lint: workspace + all targets + all features, deny warnings and deny silent allow attributes
lint:
	cargo clippy --workspace --all-targets --all-features -- -D warnings -D clippy::allow_attributes -D clippy::allow_attributes_without_reason

# Run tests (unit/integration/doc) for all targets/features
test:
	cargo test --workspace --all-targets --all-features
	cargo test --workspace --doc

# Coverage gate: 100% line coverage on library code
coverage:
	cargo llvm-cov --workspace --all-features --lib --summary-only --fail-under-lines 100 --fail-under-regions 100 --fail-under-functions 100

# Dependency audit: advisories, licenses, bans, sources
deny:
	cargo deny check

# Fuzz the frontmatter parser (run manually, not in CI gate)
# Requires: cargo install cargo-fuzz, rustup default nightly
# Usage: make fuzz DURATION=60  (seconds, default 30)
DURATION ?= 30
fuzz:
	cd fuzz && cargo +nightly fuzz run parse_frontmatter -- -max_total_time=$(DURATION)

# Build release binary
build:
	cargo build --workspace --release --all-features

# Build + copy binary to scripts/
install: build
	cp target/release/$(BIN_NAME) $(SCRIPTS_DIR)/$(BIN_NAME)
	-xattr -dr com.apple.provenance $(SCRIPTS_DIR)/$(BIN_NAME)
	-xattr -dr com.apple.quarantine $(SCRIPTS_DIR)/$(BIN_NAME)
	-codesign --force --sign - $(SCRIPTS_DIR)/$(BIN_NAME)
	chmod +x $(SCRIPTS_DIR)/it
	@echo "Installed: $(SCRIPTS_DIR)/$(BIN_NAME)"

# Clean build artifacts
clean:
	cargo clean
