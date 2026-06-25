#!/bin/sh
# Build, bundle, code-sign, and relaunch FloatyTerm for local development.
#
# Why a .app bundle (not the bare binary): macOS ties the Screen Recording
# (Context Snap) grant to a TCC *subject* = bundle identifier + code signature.
# A bare Mach-O and a .app register as DIFFERENT subjects, and `swift build`
# ad-hoc-signs the binary with a CODE HASH that changes every rebuild — so the
# grant evaporates each build. Producing the same artifact shape as build.sh
# (a .app with identifier vin.floatyterm, signed by a stable identity)
# means dev and release runs are the SAME TCC subject: grant once, never again.
#
# Built into a distinct path (.build/FloatyTerm-dev.app) so it never clobbers
# the release bundle from build.sh. A different *path* doesn't break TCC — the
# grant keys on identifier + signature, not location — so the grant still holds.
#
# Override the identity with FLOATY_SIGN_ID (a cert name or SHA-1 hash);
# defaults to the first available code-signing identity.
set -e
cd "$(dirname "$0")/.."

IDENTITY="${FLOATY_SIGN_ID:-$(security find-identity -v -p codesigning \
  | sed -n '1s/.*) \([0-9A-Fa-f]\{40\}\) .*/\1/p')}"
if [ -z "$IDENTITY" ]; then
  echo "No code-signing identity found. Create one in Keychain Access" >&2
  echo "(Certificate Assistant -> Create a Certificate -> Code Signing)" >&2
  exit 1
fi

APP=".build/FloatyTerm-dev.app"
EXEC="$APP/Contents/MacOS/FloatyTerm"

swift build

# Assemble the bundle. Identifier comes from Info.plist (vin.floatyterm)
# — the SAME identifier build.sh produces — so there is one TCC subject, not two.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/debug/FloatyTerm" "$EXEC"
cp "Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign "$IDENTITY" "$APP"

pkill -x FloatyTerm 2>/dev/null || true
sleep 1
# Launch the executable inside the bundle directly (not `open`) so stdout still
# lands in /tmp/floatyterm.log; TCC resolves it to the enclosing .app regardless.
nohup "$EXEC" >/tmp/floatyterm.log 2>&1 &
echo "FloatyTerm built, bundled, signed ($IDENTITY), relaunched (PID $!)"
echo "  bundle: $APP   log: /tmp/floatyterm.log"
