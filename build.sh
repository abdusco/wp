#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
swiftc -target arm64-apple-macos12.0 -o "$DIR/wp" "$DIR/main.swift"
echo "Built: $DIR/wp"
