#!/usr/bin/env bash
# Source-level harness: compiles the REAL CDP/input sources (no app, no relay)
# against a throwaway headless Chrome. Use it before a relaunch; run.py (one
# level up) is the end-to-end check through the CLI and the running app.
#
#   Tools/exercise/harness/run.sh            # both suites
#
# input.swift — trusted events, hover, drag, wheel, timing, chords, holds
# refs.swift  — navigate, refs, scroll-in, fill, keys, find, som --under, dialogs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../../Sources/FloatyTerm"
OUT="$(mktemp -d -t floaty-harness)"
PORT=9361
CHROME="${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
CPID=""
trap '[ -n "$CPID" ] && kill "$CPID" 2>/dev/null; rm -rf "$OUT"' EXIT

# AgentFind's AX half needs the whole app; the harness takes its DOM half only.
sed '/@MainActor/,/^    }$/d' "$SRC/AgentFind.swift" > "$OUT/AgentFindDOM.swift"
COMMON=("$HERE/shim.swift" "$SRC/KeySpec.swift" "$SRC/ElementFind.swift" "$SRC/ElementRefs.swift"
        "$SRC/CDPInputScript.swift" "$SRC/AgentCDPInput.swift" "$SRC/AgentDOM.swift" "$SRC/CDPBridge.swift")
# Top-level code must live in a file named main.swift.
mkdir -p "$OUT/input-src" "$OUT/refs-src"
cp "$HERE/input.swift" "$OUT/input-src/main.swift"
cp "$HERE/refs.swift" "$OUT/refs-src/main.swift"
swiftc -swift-version 5 -O "${COMMON[@]}" "$OUT/input-src/main.swift" -o "$OUT/input"
swiftc -swift-version 5 -O "${COMMON[@]}" "$OUT/AgentFindDOM.swift" "$OUT/refs-src/main.swift" -o "$OUT/refs"

"$CHROME" --headless=new --remote-debugging-port=$PORT --user-data-dir="$OUT/profile" --no-first-run \
  --no-default-browser-check --window-size=900,700 "file://$HERE/input.html" >/dev/null 2>&1 &
CPID=$!
for _ in $(seq 1 60); do curl -s "http://127.0.0.1:$PORT/json" | grep -q fltest && break; sleep 0.25; done

# One visible tab per suite: a background tab gets no frames (hover, wheel and
# drag stall there), so the refs page opens only after the input suite.
status=0
echo "== input"; "$OUT/input" $PORT | tee "$OUT/input.log" | grep -E "^(ok|FAIL)|PASS|FAILED|gaps|spread" || true
grep -q "ALL PASS" "$OUT/input.log" || status=1
curl -s -X PUT "http://127.0.0.1:$PORT/json/new?file://$HERE/refs.html" >/dev/null
sleep 1
echo "== refs";  "$OUT/refs" $PORT "file://$HERE/refs.html" | tee "$OUT/refs.log" | grep -E "^(ok|FAIL)|PASS|FAILED" || true
grep -q "ALL PASS" "$OUT/refs.log" || status=1
exit $status
