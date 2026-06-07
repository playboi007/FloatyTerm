#!/usr/bin/env bash
# Builds FloatyTerm and assembles a runnable, ad-hoc signed .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP="FloatyTerm.app"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/FloatyTerm" "$APP/Contents/MacOS/FloatyTerm"
cp "Info.plist" "$APP/Contents/Info.plist"

echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "==> Done. Launch with: open $APP"
