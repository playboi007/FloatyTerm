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
elif [[ "${FLOATY_ALLOW_ADHOC:-}" == "1" ]]; then
    echo "==> No identity; FLOATY_ALLOW_ADHOC=1 — ad-hoc signing (TCC grants WON'T persist across builds)"
    codesign --force --deep --sign - "$APP"
else
    # Silent ad-hoc signing is exactly what produces a "stale build" that loses
    # the Screen Recording grant every rebuild. Refuse it by default so it can't
    # happen by accident; opt in with FLOATY_ALLOW_ADHOC=1 if you truly want it.
    echo "==> ERROR: no code-signing identity found." >&2
    echo "    Create one in Keychain Access (Certificate Assistant ->" >&2
    echo "    Create a Certificate -> Code Signing), or set FLOATY_ALLOW_ADHOC=1" >&2
    echo "    to ad-hoc sign (Screen Recording grant won't persist across builds)." >&2
    exit 1
fi

echo "==> Done. Launch with: open $APP"
