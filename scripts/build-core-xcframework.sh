#!/usr/bin/env bash
set -euo pipefail

CRATE_NAME="vibe_core_ffi"
LIB_NAME="libvibe_core_ffi.a"
FRAMEWORK_NAME="VibeCoreFFI"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/core/$CRATE_NAME"
BUILD_DIR="$REPO_ROOT/core/target"
OUT_DIR="$REPO_ROOT/ios/Vendor/VibeCore"

preflight() {
    echo "Running preflight checks..."
    for tool in cargo rustup lipo xcodebuild; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "error: required tool '$tool' not found on PATH" >&2
            exit 1
        fi
    done

    if [[ ! -f "$CRATE_DIR/Cargo.toml" ]]; then
        echo "error: $CRATE_NAME not found at $CRATE_DIR — build it first" >&2
        exit 1
    fi
}

ensure_targets() {
    echo "Ensuring required Rust targets are installed..."
    local installed_targets
    installed_targets="$(rustup target list --installed)"
    for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
        if ! grep -q "^${target}$" <<< "$installed_targets"; then
            echo "Installing target $target..."
            rustup target add "$target"
        fi
    done
}

build_targets() {
    echo "Building release targets..."
    for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
        echo "Building $CRATE_NAME for $target..."
        CARGO_TARGET_DIR="$BUILD_DIR" cargo build --release --locked -p "$CRATE_NAME" --target "$target" --manifest-path "$CRATE_DIR/Cargo.toml"
    done
}

make_sim_fat() {
    echo "Creating fat simulator library..."
    local sim_fat_dir="$BUILD_DIR/sim-fat-tmp"
    mkdir -p "$sim_fat_dir"
    lipo -create \
        "$BUILD_DIR/aarch64-apple-ios-sim/release/$LIB_NAME" \
        "$BUILD_DIR/x86_64-apple-ios/release/$LIB_NAME" \
        -output "$sim_fat_dir/$LIB_NAME"
}

make_xcframework() {
    echo "Creating XCFramework at $OUT_DIR/$FRAMEWORK_NAME.xcframework..."
    mkdir -p "$OUT_DIR"
    rm -rf "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
    xcodebuild -create-xcframework \
        -library "$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME" \
        -library "$BUILD_DIR/sim-fat-tmp/$LIB_NAME" \
        -output "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
}

report_size() {
    local device_lib="$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME"
    local stripped_tmp="$BUILD_DIR/device_stripped_tmp.a"
    cp "$device_lib" "$stripped_tmp"
    strip -S "$stripped_tmp" 2>/dev/null || true
    local size
    size="$(du -h "$stripped_tmp" | cut -f1 | tr -d ' ')"
    rm -f "$stripped_tmp"
    echo "device slice: $size"
}

main() {
    preflight
    ensure_targets
    build_targets
    make_sim_fat
    make_xcframework
    report_size
}

main "$@"
