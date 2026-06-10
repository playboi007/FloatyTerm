#!/usr/bin/env bash
# Builds FloatyTerm and assembles a signed, runnable .app bundle.
#
# Signing: uses the first valid code-signing identity in the keychain (e.g.
# "Apple Development: …"), overridable via FLOATY_SIGN_ID. A STABLE identity
# matters: TCC permissions (Screen Recording for Context Snap) are keyed to
# the app's code signature — ad-hoc signatures change every build and lose the
# grant, a real identity keeps it. Falls back to ad-hoc ("-") if none exists.
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

IDENTITY="${FLOATY_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' 'NR==1 {print $2}')}"
if [[ -n "${IDENTITY:-}" ]]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> No signing identity found — ad-hoc signing (TCC grants won't persist across builds)"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Done. Launch with: open $APP"
