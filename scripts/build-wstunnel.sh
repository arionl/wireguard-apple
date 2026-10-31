#!/bin/bash
# Build the wstunnel client from source for macOS (universal) with caching.
# Usage: build-wstunnel.sh <output-path>
#   <output-path>  where to install the lipo'd universal binary
#
# Cache layout (default $HOME/.cache/wireguard-enhanced/wstunnel):
#   src/wstunnel-<ver>/    pristine source checkout
#   bin/wstunnel-<ver>/    per-arch release binaries + universal
# A cache hit makes this script return in ~1-2 seconds.

set -euo pipefail

OUTPUT_PATH="${1:?usage: build-wstunnel.sh <output-path>}"

# Pin the version we build. Bump deliberately.
WSTUNNEL_VERSION="v11.1.0"          # https://github.com/erebe/wstunnel releases
WSTUNNEL_REPO="https://github.com/erebe/wstunnel.git"

CACHE_DIR="${WSTUNNEL_CACHE_DIR:-$HOME/.cache/wireguard-enhanced/wstunnel}"
SRC_DIR="$CACHE_DIR/src/wstunnel-$WSTUNNEL_VERSION"
BIN_CACHE="$CACHE_DIR/bin/wstunnel-$WSTUNNEL_VERSION"
UNIVERSAL="$BIN_CACHE/wstunnel-universal"

ARCHS=("aarch64-apple-darwin" "x86_64-apple-darwin")

log() { echo "[build-wstunnel] $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing tool: $1"; exit 1; }; }
need cargo
need lipo
need codesign
need git

# --- fast path: cache hit ----------------------------------------------------
if [[ -x "$UNIVERSAL" ]]; then
    log "cache hit: $UNIVERSAL"
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    cp "$UNIVERSAL" "$OUTPUT_PATH"
    exit 0
fi

# --- source ------------------------------------------------------------------
if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "cloning $WSTUNNEL_REPO @ $WSTUNNEL_VERSION ..."
    mkdir -p "$CACHE_DIR/src"
    git clone --quiet "$WSTUNNEL_REPO" "$SRC_DIR"
    git -C "$SRC_DIR" checkout --quiet "$WSTUNNEL_VERSION"
fi

# --- build both arches -------------------------------------------------------
mkdir -p "$BIN_CACHE"
rustup target add aarch64-apple-darwin x86_64-apple-darwin 2>/dev/null || \
    log "note: rustup target add failed — relying on installed targets"
for arch in "${ARCHS[@]}"; do
    out="$BIN_CACHE/$arch/wstunnel"
    if [[ -x "$out" ]]; then
        log "arch $arch already built"
        continue
    fi
    log "cargo build --release --target $arch (first time: a few minutes) ..."
    (cd "$SRC_DIR" && cargo build --release --target "$arch" --bin wstunnel)
    mkdir -p "$(dirname "$out")"
    cp "$SRC_DIR/target/$arch/release/wstunnel" "$out"
done

# --- lipo + sign -------------------------------------------------------------
log "creating universal binary ..."
lipo -create \
    "$BIN_CACHE/aarch64-apple-darwin/wstunnel" \
    "$BIN_CACHE/x86_64-apple-darwin/wstunnel" \
    -output "$UNIVERSAL"
codesign --force --sign - "$UNIVERSAL"

mkdir -p "$(dirname "$OUTPUT_PATH")"
cp "$UNIVERSAL" "$OUTPUT_PATH"
log "installed: $OUTPUT_PATH"
file "$OUTPUT_PATH" || true
