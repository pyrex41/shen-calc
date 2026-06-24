#!/usr/bin/env bash
# Build ShenCAS.xcframework (iOS device + simulator + macOS) from the cas-engine
# crate. Output: <cas-engine>/target/ShenCAS.xcframework — drag into the ShenCalc
# Xcode app and set shencas.h as the bridging header.
#
# The macOS slice (aarch64-apple-darwin) lets a native macOS target embed the
# same CAS.
set -euo pipefail

cd "$(dirname "$0")"                 # cas-engine/
HDRS="include"

for tgt in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  rustup target add "$tgt" >/dev/null 2>&1 || true
  echo "building cas-engine for $tgt ..."
  cargo build --release --target "$tgt"
done

echo "packaging ShenCAS.xcframework ..."
rm -rf target/ShenCAS.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libcas_engine.a       -headers "$HDRS" \
  -library target/aarch64-apple-ios-sim/release/libcas_engine.a   -headers "$HDRS" \
  -library target/aarch64-apple-darwin/release/libcas_engine.a    -headers "$HDRS" \
  -output target/ShenCAS.xcframework

echo "done -> target/ShenCAS.xcframework"
