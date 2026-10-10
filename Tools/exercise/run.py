#!/usr/bin/env python3 -I
"""floaty exercise — the calls an agent would make, with no model, against a page
this script serves to a throwaway headless Chrome. Prints each reply as the agent
would read it and exits non-zero when one comes back differently.

    python3 -I Tools/exercise/run.py            # FloatyTerm must be running (current build)

Only the headless Chrome (temporary profile, debug port 9359) is driven: no
window opens and nothing on your desktop is touched. Two calls go to the real
host but are refused before they act (an unknown key, a point on no display).
Accessibility features (refs on native apps, `changes`) are not covered here:
they act on real apps — test them by hand (docs/floaty-test-cases.md, B7).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

PORT = 9359
HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = "file://" + os.path.join(HERE, "page.html")
CHROME = os.environ.get("CHROME_PATH", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
FAILS = []


def floaty(*args):
    p = subprocess.run(["floaty", *args], capture_output=True, text=True, timeout=60)
    out = (p.stdout or p.stderr).strip()
    try:
        reply = json.loads(out.splitlines()[-1]) if out else {}
    except json.JSONDecodeError:
        reply = {"error": out}
    shown = json.dumps(reply)[:230]
    print(f"  $ floaty {' '.join(args)[:110]}\n    → {shown}")
    return reply


def cdp(*args):
    return floaty(*args, "--port", str(PORT), "--match", "floaty-exercise")


def js(expr):
    return cdp("eval", "--expression", expr).get("result")


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


def main():
    if shutil.which("floaty") is None:
        sys.exit("floaty is not on PATH (ln -s <repo>/scripts/floaty ~/.local/bin/floaty)")
    if "error" in floaty("host", "--probe"):
        sys.exit("FloatyTerm is not reachable — start it first")
    profile = tempfile.mkdtemp(prefix="floaty-exercise-")
    chrome = subprocess.Popen([CHROME, "--headless=new", f"--remote-debugging-port={PORT}",
                               f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
                               "--window-size=900,700", PAGE],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=1))
                if any(t.get("title") == "floaty-exercise" for t in tabs):
                    break
            except OSError:
                pass
            time.sleep(0.25)
        run_checks()
    finally:
        chrome.terminate()
        try:
            chrome.wait(5)
        except subprocess.TimeoutExpired:
            chrome.kill()
        shutil.rmtree(profile, ignore_errors=True)
    print(f"\n{'ALL PASS' if not FAILS else str(len(FAILS)) + ' FAILED: ' + '; '.join(FAILS)}")
    sys.exit(1 if FAILS else 0)


def run_checks():
    print("\n# refused before acting")
    check("error" in floaty("key", "--key", "hyper+a"), "unknown modifier → error, nothing pressed")
    check("no display" in floaty("click", "--x", "-99999", "--y", "-99999").get("error", ""),
          "point on no display → refused")
    check("refused" in cdp("navigate", "--url", "javascript:alert(1)").get("error", ""), "javascript: URL refused")

    print("\n# navigate waits for the page")
    r = cdp("navigate", "--url", PAGE + "?n=1")
    check(r.get("title") == "floaty-exercise" and "committed" not in r, "navigate returns the loaded page")

    print("\n# refs")
    r = cdp("query-dom", "--selector", "#add")
    ref = (r.get("elements") or "").split("\t")[0]
    check(ref.startswith("ref_"), f"query-dom rows carry refs ({ref})")
    check(cdp("input", "--click", ref).get("ok") is True and js("window.__added") == 1, "input --click REF lands")
    r = cdp("find", "email field")
    check("Email" in (r.get("elements") or "").split("\n")[0], "find 'email field' → the email field first")
    sec = (cdp("query-dom", "--selector", "#sec").get("elements") or "").split("\t")[0]
    r = cdp("som", "--under", sec)
    check(r.get("count") == 2, "som --under REF reads one subtree")

    print("\n# input actions")
    cdp("input", "--move", "#menu")
    check(js("window.__hovered") == 1, "hover reaches onmouseover")
    r = cdp("input", "--click", "#far")
    check(r.get("scrolled") is True and js("window.__far") == 1, "off-view target scrolled in and clicked")
    js("scrollTo(0,0)")
    cdp("input", "--steps", json.dumps([{"fill": "#email", "value": "new@shop.ch"}, {"fill": "#size", "value": "Medium"}]))
    check(js("document.getElementById('email').value") == "new@shop.ch", "fill replaces a text value")
    check(js("document.getElementById('size').value") == "m", "fill picks a <select> option by text")
    cdp("input", "--steps", json.dumps([{"click": "#email"}, {"key": "cmd+a"}, {"key": "Backspace"}]))
    check(js("document.getElementById('email').value") == "", "cmd+a then Backspace clears the field")

    print("\n# timing (12 notes, 100 ms apart)")
    js("window.__log.splice(0); 0")
    steps = [{"t": i * 100, "click": ".w[data-midi='60']" if i % 2 == 0 else ".b[data-midi='61']", "hold": 50}
             for i in range(12)]
    r = cdp("input", "--steps", json.dumps(steps))
    downs = js("JSON.stringify(window.__log.filter(e=>e.type==='pointerdown').map(e=>[e.t,e.midi,e.tr]))")
    downs = json.loads(downs) if isinstance(downs, str) else []
    gaps = [abs((b[0] - a[0]) - 100) for a, b in zip(downs, downs[1:])]
    check(len(downs) == 12 and all(d[2] for d in downs), "12 trusted pointerdowns")
    check(downs and [d[1] for d in downs] == ["60", "61"] * 6, "black key hit by selector, every time")
    check(gaps and max(gaps) < 12, f"note spacing within 12 ms (max {max(gaps) if gaps else '?'} ms)")

    print("\n# dialogs")
    r = cdp("input", "--click", "#al")
    d = (r.get("dialogs") or [{}])[0]
    check(d.get("message") == "Saved!" and d.get("answered") == "dismissed", "alert dismissed in-session and reported")
    r = cdp("input", "--click", "#al", "--on-dialog", "stop")
    check("Saved!" in r.get("error", ""), "--on-dialog stop → error with the dialog's text")
    r = cdp("dialog", "--reload")
    check(r.get("reloaded") is True, "dialog --reload recovers")
    time.sleep(0.5)
    check(js("1+1") == 2, "page answers after the reload")

    print("\n# host")
    check("policy" in floaty("host", "--policy"), "host --policy reports the approval policy")


if __name__ == "__main__":
    main()
