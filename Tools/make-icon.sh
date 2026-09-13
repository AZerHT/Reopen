#!/bin/bash
# Builds Resources/AppIcon.icns and the README image docs/icon.png from Tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" Resources docs

swift Tools/make-icon.swift "$ICONSET" docs/icon.png
iconutil --convert icns "$ICONSET" --output Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns, docs/icon.png"
