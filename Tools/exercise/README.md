# floaty exercise

Model-free checks: the calls an agent would make, sent against a throwaway
headless Chrome (temporary profile, debug port). Nothing on your desktop is
touched. Run before a commit that changes the agent host or the CLI.

| Script | What it runs | Needs |
|---|---|---|
| `python3 -I Tools/exercise/run.py` | the CLI → relay → running FloatyTerm → Chrome, end to end | FloatyTerm running the build under test |
| `Tools/exercise/harness/run.sh` | the real CDP/input sources compiled into test binaries (no app) | nothing running — use it before a relaunch |

Accessibility features (native refs, `changes`, background presses) act on real
apps, so they are manual cases: `docs/floaty-test-cases.md` (Tier B).
