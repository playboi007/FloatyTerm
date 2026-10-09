#!/usr/bin/env bash
# Builds FloatyTerm and assembles a signed, runnable .app bundle.
#
# Signing: uses the first valid code-signing identity in the keychain (e.g.
# "Apple Development: …"), overridable via FLOATY_SIGN_ID. A STABLE identity
# matters: TCC permissions (Screen Recording for Context Snap) are keyed to
# the app's code signature — ad-hoc signatures change every build and lose the
# grant, a real identity keeps it. Ad-hoc signing requires explicit opt-in.
set -euo pipefail

cd "$(dirname "$0")"
BUILD_ROOT="$PWD"
WITH_CLAUDE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --RichRenderer-claude|--all) WITH_CLAUDE=1; shift ;;
        --help|-h)
            echo 'Usage: ./build.sh [--RichRenderer-claude | --all]'
            echo 'Default: core app without ClaudeSidecar. --all includes every optional component.'
            exit 0 ;;
        *) echo "Unknown build option: $1" >&2; exit 1 ;;
    esac
done
if [[ "$WITH_CLAUDE" == 1 ]]; then
    command -v npm >/dev/null || { echo 'npm is required with --RichRenderer-claude or --all.' >&2; exit 1; }
fi

APP="${FLOATY_APP_PATH:-FloatyTerm.app}"
VERSION="${FLOATY_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
BUILD="${FLOATY_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z' >&2; exit 1; }
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be a positive integer' >&2; exit 1; }
# Require an app bundle path before replacing the build output.
[[ "$APP" == *.app && ! -L "$APP" ]] || { echo 'App output must be a non-symlink .app path' >&2; exit 1; }

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-module-cache}"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/FloatyTerm" "$APP/Contents/MacOS/FloatyTerm"
cp "Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
CLAUDE_ENABLED=false
[[ "$WITH_CLAUDE" == 0 ]] || CLAUDE_ENABLED=true
/usr/libexec/PlistBuddy -c "Add :FloatyRichRendererClaudeEnabled bool $CLAUDE_ENABLED" "$APP/Contents/Info.plist"

# SkimRender (the Markdown renderer's JS, CSS and fonts), minus its dev fixtures.
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/ThirdPartyNotices/SwiftTerm-LICENSE.txt"
# Include dependency resources inside the signed app's Resources directory.
# FloatyTerm currently uses SwiftTerm's default CoreGraphics renderer.
for RESOURCE_BUNDLE in .build/release/*.bundle; do
    [[ -d "$RESOURCE_BUNDLE" ]] || continue
    ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
done
rsync -a --exclude 'dev/' "Resources/SkimRender/" "$APP/Contents/Resources/SkimRender/"
rsync -a --exclude '*.test.mjs' "Resources/CodexSidecar/" "$APP/Contents/Resources/CodexSidecar/"

# The Claude tab's sidecar (Node + the Claude Agent SDK). The SDK's own Claude
# Code binaries are optional dependencies and are left out: the sidecar drives
# the user's installed `claude`.
if [[ "$WITH_CLAUDE" == 1 ]]; then
    echo "==> Installing the Claude sidecar's dependencies…"
    rsync -a --exclude node_modules/ "Resources/ClaudeSidecar/" "$APP/Contents/Resources/ClaudeSidecar/"
    (cd "$APP/Contents/Resources/ClaudeSidecar" && npm ci --cache "$BUILD_ROOT/.build/npm-cache" --omit=optional --no-audit --no-fund --loglevel=error)
else
    echo '==> Core build: ClaudeSidecar excluded (include with --RichRenderer-claude or --all).'
fi

IDENTITY="${FLOATY_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' 'NR==1 {print $2}')}"
if [[ -n "${IDENTITY:-}" ]]; then
    echo "==> Signing with: $IDENTITY"
    if [[ "${FLOATY_DISTRIBUTION:-}" == "1" ]]; then
        codesign --force --deep --options runtime --timestamp \
            --entitlements Release.entitlements --sign "$IDENTITY" "$APP"
    else
        codesign --force --deep --sign "$IDENTITY" "$APP"
    fi
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
codesign --verify --deep --strict "$APP"

echo "==> Done. Launch with: open $APP"
