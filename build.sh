#!/usr/bin/env bash
set -euo pipefail

# Usage: ARCH=arm64 VERSION=1.2.3 ./build.sh

ARCH="${ARCH:-arm64}"
VERSION="${VERSION:-dev}"
VERSION_CLEAN=${VERSION#v}

echo "Building for arch: $ARCH, version: $VERSION_CLEAN"

sed "s/var version = \".*\"/var version = \"$VERSION_CLEAN\"/" main.swift > main.build.swift

swiftc -target ${ARCH}-apple-macos12.0 -o wp-${ARCH} main.build.swift \
  -framework AppKit -framework Foundation -framework CoreImage -framework Metal -framework Network

rm main.build.swift

echo "Built wp-${ARCH} with version $VERSION_CLEAN"
