#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUI_DIR="$(dirname "$SCRIPT_DIR")/tui"
BIN_DIR="$SCRIPT_DIR"
ISSUES_DIR="${HOME}/.config/skills/issue-config"

# --- Prerequisites ---
check_rust() {
    if ! command -v cargo &>/dev/null; then
        echo "error: cargo not found. Install Rust: https://rustup.rs"
        exit 1
    fi
}

install_tools() {
    local tools=("cargo-llvm-cov" "cargo-deny")
    for tool in "${tools[@]}"; do
        if ! cargo install --list | grep -q "^${tool} "; then
            echo "Installing ${tool}..."
            cargo install "$tool"
        else
            echo "${tool} already installed"
        fi
    done
}

# --- Build ---
build_tui() {
    echo "Building issue-tui..."
    cd "$TUI_DIR"
    cargo build --release
    cp target/release/issue-tui "$BIN_DIR/issue-tui"
    xattr -dr com.apple.provenance "$BIN_DIR/issue-tui" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$BIN_DIR/issue-tui" 2>/dev/null || true
    codesign --force --sign - "$BIN_DIR/issue-tui" >/dev/null 2>&1 || true
    chmod +x "$BIN_DIR/it"
    echo "Binary installed at: $BIN_DIR/issue-tui"
}

# --- Issue directories ---
ensure_dirs() {
    for status in triage ready in-progress review done; do
        mkdir -p "$ISSUES_DIR/$status"
    done
    echo "Issue directories ready at: $ISSUES_DIR/"
}

# --- Main ---
main() {
    echo "=== issue-tui install ==="
    check_rust
    ensure_dirs
    install_tools
    build_tui
    echo ""
    echo "Done. Run with:"
    echo "  $BIN_DIR/it"
    echo ""
    echo "Verify with:"
    echo "  cd $TUI_DIR && make check"
}

main "$@"
