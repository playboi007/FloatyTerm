#!/usr/bin/env bash
# Build a versioned, drag-to-Applications installer. Never installs or publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

usage() {
    cat <<'EOF'
Usage: ./scripts/package-dmg.sh --local [--version X.Y.Z] [--build N] [--RichRenderer-claude | --all]
       FLOATY_SIGN_ID='Developer ID Application: …' ./scripts/package-dmg.sh \
         --notarize KEYCHAIN_PROFILE [--version X.Y.Z] [--build N]

Defaults come from Info.plist. Outputs go to dist/. Each version/build pair
must be unique. Builds for this Mac's architecture (arm64 or x86_64).
--local explicitly permits ad-hoc signing when no identity is available.
--notarize submits to Apple using previously stored Keychain credentials.
Default: core app, without ClaudeSidecar or its npm dependencies.
--RichRenderer-claude includes the full Claude rich renderer sidecar.
--all includes every optional component (currently the Claude sidecar).
EOF
}
MODE=""
PROFILE=""
CLAUDE_FLAG=""
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local) [[ -z "$MODE" ]] || { usage; exit 1; }; MODE=local; shift ;;
        --notarize) [[ -z "$MODE" && $# -ge 2 && -n "$2" ]] || { usage; exit 1; }; MODE=notarize; PROFILE="$2"; shift 2 ;;
        --version) [[ $# -ge 2 ]] || { usage; exit 1; }; VERSION="$2"; shift 2 ;;
        --build) [[ $# -ge 2 ]] || { usage; exit 1; }; BUILD="$2"; shift 2 ;;
        --RichRenderer-claude|--all) CLAUDE_FLAG="$1"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
[[ -n "$MODE" ]] || { usage >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z' >&2; exit 1; }
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be a positive integer' >&2; exit 1; }
ARCH="$(uname -m)"
NAME="FloatyTerm-${VERSION}-${BUILD}-${ARCH}"
FEATURES=core
if [[ -n "$CLAUDE_FLAG" ]]; then
    NAME="${NAME}-claude"
    FEATURES=core,RichRenderer-claude
fi
OUT="$ROOT/dist/$NAME"
[[ ! -e "$OUT" ]] || { echo "Release already exists: $OUT" >&2; exit 1; }

if [[ "$MODE" == notarize ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning)"
    IDENTITY="${FLOATY_SIGN_ID:-$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Developer ID Application:/ {print $2; exit}')}"
    [[ -n "$IDENTITY" ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
    MATCH="$(printf '%s\n' "$IDENTITIES" | awk -v id="$IDENTITY" 'index($0,id) && /Developer ID Application:/ {print}')"
    [[ -n "$MATCH" && "$IDENTITY" != '-' ]] || { echo 'FLOATY_SIGN_ID must identify a valid Developer ID Application certificate.' >&2; exit 1; }
    export FLOATY_SIGN_ID="$IDENTITY" FLOATY_DISTRIBUTION=1
else
    export FLOATY_ALLOW_ADHOC=1
    echo 'Local test package: not notarized; macOS may block first launch.'
fi
if [[ -n "$CLAUDE_FLAG" ]]; then
    command -v npm >/dev/null || { echo 'npm is required with --RichRenderer-claude or --all.' >&2; exit 1; }
fi
mkdir -p "$ROOT/.build" "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/.build/dmg-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/installer/FloatyTerm.app"
FLOATY_APP_PATH="$APP" FLOATY_VERSION="$VERSION" FLOATY_BUILD_NUMBER="$BUILD" \
    ./build.sh ${CLAUDE_FLAG:+"$CLAUDE_FLAG"}

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait \
        --output-format plist > "$WORK/notary-result.plist"
    cat "$WORK/notary-result.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK/notary-result.plist")" == Accepted ]] || {
        echo 'Notarization was not accepted. Use notarytool log with the submission ID above.' >&2
        exit 1
    }
}
if [[ "$MODE" == notarize ]]; then
    ditto -c -k --keepParent "$APP" "$WORK/FloatyTerm.zip"
    notarize "$WORK/FloatyTerm.zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
ln -s /Applications "$WORK/installer/Applications"
cat > "$WORK/installer/Install and Update.txt" <<EOF
FloatyTerm $VERSION (build $BUILD) — $ARCH — macOS 14 or later
Included components: $FEATURES

Install: drag FloatyTerm.app onto Applications, then eject this disk image.
Launch FloatyTerm from Applications; its controls appear in the menu bar.

Update: quit FloatyTerm from its menu bar (save sessions if prompted), then
drag the new app onto Applications and choose Replace. Reopen it afterwards.
Preferences and saved data are stored outside the app bundle.

Codex requires Node.js and an installed, authenticated codex CLI.
Claude rich rendering is included only in the Claude-enabled variant;
it requires Node.js and an installed, authenticated claude CLI.
Node.js, CLI tools, and credentials are not included in the installer.
Updates are manual; this package does not install an automatic updater.
EOF
hdiutil create -volname "FloatyTerm $VERSION" -srcfolder "$WORK/installer" \
    -format UDZO -ov "$WORK/$NAME.dmg"
if [[ "$MODE" == notarize ]]; then
    codesign --sign "$IDENTITY" --timestamp "$WORK/$NAME.dmg"
    notarize "$WORK/$NAME.dmg"
    xcrun stapler staple "$WORK/$NAME.dmg"
    xcrun stapler validate "$WORK/$NAME.dmg"
fi
hdiutil verify "$WORK/$NAME.dmg"
mkdir "$OUT"
mv "$WORK/$NAME.dmg" "$OUT/"
(
    cd "$OUT"
    shasum -a 256 "$NAME.dmg" > SHA256SUMS
)
{
    printf 'Version: %s\nBuild: %s\nArchitecture: %s\nMode: %s\n' "$VERSION" "$BUILD" "$ARCH" "$MODE"
    printf 'Included components: %s\n' "$FEATURES"
    printf 'Commit: %s\n' "$(git rev-parse HEAD)"
    printf 'Built at (UTC): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '\nApp signature:\n'
    codesign -dv "$APP" 2>&1
    printf '\nWorktree status at build time:\n'
    git status --short
} > "$OUT/BUILD.txt"
echo "DMG ready: $OUT/$NAME.dmg"
