# FloatyTerm setup guide (first-time install)

This is a runbook for setting up FloatyTerm from a fresh clone. It's written so
you can hand it to your own coding agent and have it work through the steps —
each one says explicitly whether the **agent** can run it unattended or whether
it needs the **human** at the keyboard (macOS permission dialogs and System
Settings clicks can't be automated).

Do the sections in order — later steps assume FloatyTerm.app is already built
and running.

## 0. Prerequisites

- macOS 13 (Ventura) or later — 14+ if you want Context Snap's full quality path.
- Xcode / the Swift toolchain: `swift --version` should succeed.
- A code-signing identity in Keychain Access. **This is the one real gate.**
  FloatyTerm's Screen Recording and Accessibility grants are keyed to the
  app's code signature — an ad-hoc signature changes on every rebuild and
  silently drops the grant, so `build.sh` refuses to build without a real
  identity unless you explicitly opt out.

  **Human step:** if `security find-identity -v -p codesigning` prints
  nothing, open Keychain Access → **Certificate Assistant → Create a
  Certificate → Code Signing** (a free "Apple Development" certificate is
  fine). Alternatively, set `FLOATY_ALLOW_ADHOC=1` when building — but then
  expect to be re-prompted for permissions after every rebuild.

## 1. Build and launch FloatyTerm.app

**Agent step:**

```sh
./build.sh        # compiles (release) and assembles FloatyTerm.app, then codesigns
open FloatyTerm.app
```

`build.sh` signs with the first identity in your keychain (override with
`FLOATY_SIGN_ID`). If it exits with "no code-signing identity found," go back
to step 0.

**Human step (first launch only):** without a paid Developer ID, macOS may
show an "unverified developer" prompt. Right-click `FloatyTerm.app` → **Open**,
or allow it under **System Settings → Privacy & Security**.

FloatyTerm needs **no permissions at all** for its core terminal features
(the global hotkey uses the Carbon HotKey API). Permissions below are only
requested the first time you touch the specific feature that needs them —
there's no upfront onboarding wizard.

## 2. Install the `floaty` CLI

**Agent step:**

```sh
cp scripts/floaty ~/.local/bin/floaty && chmod +x ~/.local/bin/floaty
# or anywhere else on PATH, e.g. /usr/local/bin (needs sudo)
```

The script is a thin bash+curl client — it holds no permissions itself. It
POSTs to FloatyTerm's loopback relay at `127.0.0.1:7777`, which only the
long-running `FloatyTerm.app` can serve (permissions are keyed to *its*
signature, which is why the CLI doesn't need to be signed at all).

**Verify the relay is up (agent step):**

```sh
curl -s http://127.0.0.1:7777/ -o /dev/null -w '%{http_code}\n'
```

Any response (even a 404) means the relay is listening. If the connection is
refused, FloatyTerm.app isn't running, or something else already holds port
7777 (the relay binds `127.0.0.1:7777` only and does not fall back to another
port).

## 3. Grant Accessibility (needed for `floaty click/type/move/drag/scroll/key`)

**Agent step:** trigger the permission prompt by running any input command:

```sh
floaty key --key escape
```

**Human step:** FloatyTerm shows an alert — *"Accessibility permission
needed"* — with three buttons:

1. **Open System Settings** → grant FloatyTerm access under
   **Privacy & Security → Accessibility**.
2. **Relaunch FloatyTerm** — required; macOS only applies a fresh grant to a
   newly-started process. If you still see the prompt after granting, this is
   almost always the missing step.

**Agent step (verify):**

```sh
floaty type --text "hello from the agent" --target "Notes"
```

should now actually type into Notes instead of erroring.

## 4. Grant Screen Recording (only if you'll use Context Snap or window mirroring)

Optional — skip if you don't need screenshots/OCR of what's behind the
terminal. Same lazy pattern as step 3: use the camera button (Context Snap) or
a mirrored window tab once, and FloatyTerm shows *"Screen Recording permission
needed"* with the same **Open System Settings / Relaunch** choice, granted
under **Privacy & Security → Screen Recording**.

## 5. Chrome extension (CDP bridge) — optional, for driving live Chrome tabs

Only needed if you want `floaty ... --via-extension` to control your actual,
already-logged-in Chrome tabs (as opposed to a separate debug-port Chrome).

**Human step** (Chrome's extension UI has no CLI):

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top-right).
3. **Load unpacked** → select this repo's `extension/` folder.
4. With FloatyTerm running, open any normal `http(s)` tab.
5. Click the extension's icon — it should say **"relay reachable ✓"**.

**Agent step (verify):**

```sh
floaty tabs --via-extension
```

should list your real open tabs.

Notes:
- Port 7777 is hardcoded on both sides — no config needed for basic use.
- Optional hardening: create
  `~/Library/Application Support/FloatyTerm/cdp-bridge-token.txt` with a
  secret string and paste the same string into the extension's options popup.
  Skip this for a first-time local setup.
- Chrome-only — Electron apps (VS Code, Cursor, Slack) use
  `floaty enable-cdp --app …` instead, not this extension.
- A yellow "started debugging" banner appears on the active tab while
  attached; it clears itself ~8s after the last command.
- If Chrome DevTools is already open on a tab, attaching to that same tab
  will fail ("Another debugger is already attached").

## 6. TypingProfiler — optional, for human-like `--human` typing replay

Only affects the fidelity of `floaty type --human` (how closely simulated
typing matches real typing rhythm). Skip if you're fine with the flat ~60ms
default jitter.

**Agent step:**

```sh
cd Tools/TypingProfiler && swift run
```

This launches a separate small GUI window (a standalone SwiftPM tool, isolated
from the main FloatyTerm package on purpose).

**Human step:** in the window, pick a passage difficulty (Easy/Medium/Hard/
Drill), type the shown passage naturally, then click **Save Profile**. Repeat
across a session or two if you want a fuller profile — saves merge into the
same file rather than overwrite it.

No FloatyTerm restart is needed afterward — the profile is read from disk with
a modified-time check, so a freshly-saved profile is picked up automatically
the next time `--human` typing runs. Output lands at:

```
~/Library/Application Support/FloatyTerm/typing-profile.json
```

**Agent step (verify):**

```sh
floaty type --text "slow and human" --human --target "Notes"
```

A pausable HUD (play/pause/stop/speed) should appear over the terminal window
while it types.

## 7. Full smoke test

Once everything above is done, this sequence exercises every layer end to end
(agent-runnable, assuming Notes/Cursor exist — swap targets as needed):

```sh
floaty key --key escape                                          # relay + input reachable
floaty type --text "hello from the agent" --target "Notes"       # instant typing
floaty type --text "slow and human" --human --target "Notes"     # human-paced + HUD
floaty click --x 200 --y 200                                     # mouse
floaty capture --window "Notes"                                  # screen capture (needs step 4)
floaty tabs --via-extension                                      # Chrome bridge (needs step 5)
```

Legitimate failures (missing permission, element not found, port closed) come
back as a JSON `{"error": ...}` body with a non-zero exit — that's a real
answer, not a broken setup. Only "FloatyTerm not reachable" means the relay
itself isn't up (check step 1/2).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `build.sh` exits "no code-signing identity found" | No cert in Keychain | Create one (step 0), or set `FLOATY_ALLOW_ADHOC=1` |
| "unverified developer" on first launch | No paid Developer ID | Right-click → Open, or allow in System Settings |
| Accessibility/Screen Recording prompt reappears after granting | Grant applies to next launch only | Click **Relaunch FloatyTerm** in the alert |
| `curl` to `127.0.0.1:7777` refused | FloatyTerm.app not running, or port 7777 held by another process | Launch FloatyTerm.app; free the port if something else is bound to it |
| Permission grant lost after a rebuild | Ad-hoc signature changes every build | Use a real identity (step 0), not `FLOATY_ALLOW_ADHOC=1` |
| Extension never says "relay reachable" | FloatyTerm not running, or on a `chrome://` tab | Launch FloatyTerm; open a normal `http(s)` tab |
| `--via-extension` fails "another debugger is already attached" | Chrome DevTools open on that tab | Close DevTools on that tab |

## Reference docs

This guide is the onboarding path; these cover the same systems in depth:

- [`../README.md`](../README.md) — features, build/run, permissions philosophy.
- [`agent-host.md`](agent-host.md) — the `floaty` CLI, agent-control routes, permission model.
- [`../extension/README.md`](../extension/README.md) — CDP bridge architecture and limits.
