import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var hotKey: HotKey!
    private let statusItem = StatusItemController()
    private let settingsWC = SettingsWindowController()
    private let switcher = SessionSwitcherController()
    private let ruler = RulerController()

    /// Drives the menu-bar fleet summary (working / waiting counts across
    /// every terminal tab in every window). Strong reference — a scheduled
    /// Timer is only retained by its run loop while valid.
    private var fleetSummaryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Loopback relay for remote devtools awareness: external pages that
        // include http://127.0.0.1:7777/floaty.js stream console/network
        // events into agent-tailable logs under App Support/FloatyTerm/Devtools.
        DevtoolsRelay.shared.start()
        // Shell shim (`ftdiff a b`) POSTs to the relay's /diff route; open the
        // resulting side-by-side diff in the current (or a fresh) window.
        DevtoolsRelay.shared.onOpenDiff = { [weak self] left, right in
            self?.compareFilesInCurrentWindow(left: left, right: right)
        }

        // Agent-host control routes: the `floaty` CLI POSTs to /agent/* on the
        // relay and FloatyTerm (holding the Accessibility + Screen Recording
        // grants) drives the OS — input injection (Layer B / AgentInput),
        // window capture (Layer C / AgentCapture), and CDP element targeting
        // (Layer A / AgentDOM). All closures run on the main actor.
        DevtoolsRelay.shared.onAgentClick = { [weak self] b in
            guard let self, let p = self.point(b) else { return ["error": "expected {x,y}"] }
            let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
            let ok = AgentInput.click(at: p, button: self.button(b), modifiers: self.mods(b),
                                      clicks: clicks, pacing: self.pacing(b),
                                      target: self.target(b), targetPID: self.targetPID(b))
            return ok ? ["ok": true] : self.inputFailure("click", b)
        }
        DevtoolsRelay.shared.onAgentMove = { [weak self] b in
            guard let self, let p = self.point(b) else { return ["error": "expected {x,y}"] }
            let ok = AgentInput.move(to: p, pacing: self.pacing(b),
                                     target: self.target(b), targetPID: self.targetPID(b))
            return ok ? ["ok": true] : self.inputFailure("move", b)
        }
        DevtoolsRelay.shared.onAgentDrag = { [weak self] b in
            guard let self,
                  let fx = (b["from_x"] as? NSNumber)?.doubleValue,
                  let fy = (b["from_y"] as? NSNumber)?.doubleValue,
                  let tx = (b["to_x"] as? NSNumber)?.doubleValue,
                  let ty = (b["to_y"] as? NSNumber)?.doubleValue
            else { return ["error": "expected {from_x,from_y,to_x,to_y}"] }
            let ok = AgentInput.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty),
                                     button: self.button(b), modifiers: self.mods(b),
                                     pacing: self.pacing(b), target: self.target(b),
                                     targetPID: self.targetPID(b))
            return ok ? ["ok": true] : self.inputFailure("drag", b)
        }
        DevtoolsRelay.shared.onAgentScroll = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            let dx = (b["dx"] as? NSNumber)?.intValue ?? 0
            let dy = (b["dy"] as? NSNumber)?.intValue ?? 0
            let ok = AgentInput.scroll(dx: dx, dy: dy, at: self.point(b),
                                       pacing: self.pacing(b), target: self.target(b),
                                       targetPID: self.targetPID(b))
            return ok ? ["ok": true] : self.inputFailure("scroll", b)
        }
        DevtoolsRelay.shared.onAgentType = { [weak self] b in
            guard let self, let text = b["text"] as? String else { return ["error": "expected {text}"] }
            let ok = AgentInput.type(text, pacing: self.pacing(b),
                                     target: self.target(b), targetPID: self.targetPID(b))
            return ok ? ["ok": true, "typed": text.count] : self.inputFailure("type", b)
        }
        DevtoolsRelay.shared.onAgentKey = { [weak self] b in
            guard let self, let key = b["key"] as? String else { return ["error": "expected {key}"] }
            // Check the key name first so an unknown key reports its own precise
            // cause instead of being lumped under the activation failure path.
            guard AgentInput.isKnownKey(key) else {
                return ["error": "key failed: \"\(key)\" is not a known key name. Use a single "
                    + "character (a–z, 0–9, punctuation like / or -), a function key (f1–f12), or a "
                    + "named key (return, tab, space, delete, escape, left/right/up/down, home, end, "
                    + "pgup, pgdown). For arbitrary text use `type`, not `key`."]
            }
            let ok = AgentInput.pressKey(key, modifiers: self.mods(b),
                                         target: self.target(b), targetPID: self.targetPID(b))
            return ok ? ["ok": true, "key": key] : self.inputFailure("key", b)
        }
        DevtoolsRelay.shared.onAgentCapture = { b in
            let window = b["window"] as? String
            let windowID = (b["window_id"] as? NSNumber)?.uint32Value
            guard window != nil || windowID != nil else {
                return ["error": "expected {window} or {window_id} (see `floaty list-windows`)"]
            }
            let ocr = (b["ocr"] as? NSNumber)?.boolValue ?? false
            do {
                let r = try await AgentCapture.captureWindow(named: window, windowID: windowID, ocr: ocr)
                let f = r.frame
                // The capture frame: everything click-in-frame needs to map an
                // image-pixel coordinate back to a global screen point.
                var out: [String: Any] = [
                    "ok": true, "path": r.imagePath, "frame_id": f.id,
                    "origin_x": f.origin.x, "origin_y": f.origin.y,
                    "width": f.size.width, "height": f.size.height, "scale": f.scale,
                    "image_width": f.imageWidth, "image_height": f.imageHeight,
                ]
                if let t = r.textPath { out["text_path"] = t }          // OCR found text
                else if ocr { out["note"] = "no text recognized in the capture" }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentMark = { [weak self] b in
            guard let self, let p = self.point(b) else { return ["error": "expected {x,y}"] }
            let duration = (b["duration"] as? NSNumber)?.doubleValue ?? 1.2
            let label = b["label"] as? String
            _ = AgentMarker.show(at: p, duration: duration, label: label)
            return ["ok": true, "x": p.x, "y": p.y]
        }
        // click-in-frame / move-in-frame: the agent passes a coordinate its
        // vision model read off a captured PNG (image pixels) plus the frame_id;
        // FloatyTerm inverts to a screen point and acts. Breaks the capture →
        // guess → nudge → re-capture loop on native/canvas apps.
        DevtoolsRelay.shared.onAgentClickInFrame = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            do {
                let (p, owner) = try self.resolveFrame(b)
                let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
                let ok = AgentInput.click(at: p, button: self.button(b), modifiers: self.mods(b),
                                          clicks: clicks, pacing: self.pacing(b), target: owner)
                return ok ? ["ok": true, "screen_x": p.x, "screen_y": p.y]
                          : self.inputFailure("click-in-frame", b)
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentMoveInFrame = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            do {
                let (p, owner) = try self.resolveFrame(b)
                let ok = AgentInput.move(to: p, pacing: self.pacing(b), target: owner)
                return ok ? ["ok": true, "screen_x": p.x, "screen_y": p.y]
                          : self.inputFailure("move-in-frame", b)
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentListWindows = { b in
            // Optional `filter` narrows to windows whose owner/title contains it.
            let filter = (b["filter"] as? String)?.lowercased()
            let windows = AgentCapture.listWindows()
                .filter { filter == nil
                    || $0.owner.lowercased().contains(filter!)
                    || $0.title.lowercased().contains(filter!) }
                .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
                .map { w -> [String: Any] in
                    ["id": Int(w.id), "pid": Int(w.pid), "owner": w.owner, "title": w.title,
                     "x": w.bounds.origin.x, "y": w.bounds.origin.y,
                     "width": w.bounds.width, "height": w.bounds.height]
                }
            return ["ok": true, "windows": windows]
        }
        DevtoolsRelay.shared.onAgentQueryDOM = { b in
            guard let selector = b["selector"] as? String else { return ["error": "expected {selector}"] }
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            do {
                let matches = try await AgentDOM.screenRects(selector: selector, port: port, match: match)
                let arr: [[String: Any]] = matches.map { m in
                    ["x": m.rect.origin.x, "y": m.rect.origin.y,
                     "width": m.rect.size.width, "height": m.rect.size.height,
                     "center_x": m.center.x, "center_y": m.center.y, "text": m.text]
                }
                // Top-level fields mirror the FIRST match (back-compat with the
                // single-result shape); `matches`/`count` expose them all.
                let f = matches[0]
                return ["ok": true, "count": matches.count, "matches": arr,
                        "x": f.rect.origin.x, "y": f.rect.origin.y,
                        "width": f.rect.size.width, "height": f.rect.size.height,
                        "center_x": f.center.x, "center_y": f.center.y]
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentEval = { b in
            guard let expr = (b["expression"] as? String) ?? (b["js"] as? String) else {
                return ["error": "expected {expression}"]
            }
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            do {
                let json = try await AgentDOM.runJavaScript(expression: expr, port: port, match: match)
                // Re-parse so the value embeds natively in the response (an
                // array stays an array), not as an escaped string.
                if let json, let val = try? JSONSerialization.jsonObject(
                    with: Data(json.utf8), options: [.fragmentsAllowed]) {
                    return ["ok": true, "result": val]
                }
                return ["ok": true, "result": NSNull()]
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentNavigate = { b in
            guard let url = b["url"] as? String else { return ["error": "expected {url}"] }
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            do { try await AgentDOM.navigate(url: url, port: port, match: match); return ["ok": true, "url": url] }
            catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentTabs = { b in
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            do { return ["ok": true, "tabs": try await AgentDOM.tabs(port: port)] }
            catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentFocus = { b in
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            do {
                try await AgentDOM.bringToFront(port: port, match: match)
                return ["ok": true]
            } catch { return ["error": error.localizedDescription] }
        }
        // Set-of-Mark: annotate the page's interactable elements with numbered
        // boxes (drawn in-page, screenshotted, then stripped) and return the PNG
        // + a mark table in SCREEN coords. The model reads a NUMBER off the image
        // instead of regressing a pixel; `click-mark --id N` resolves N → a click.
        DevtoolsRelay.shared.onAgentSom = { b in
            let maxMarks = (b["max"] as? NSNumber)?.intValue ?? 100
            let app = b["app"] as? String
            let axPID = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }

            // AX-backed Set-of-Mark: read the target app's tree (by PID — works on
            // native apps AND the live default-profile Chrome), screenshot its
            // window, and draw the numbered boxes ourselves (native elements can't
            // inject their own overlay like the DOM path does).
            if app != nil || axPID != nil {
                do {
                    let pid = try AgentAX.resolvePID(app: app, pid: axPID)
                    guard let win = AgentCapture.listWindows()
                            .filter({ $0.pid == pid })
                            .max(by: { $0.area < $1.area }) else {
                        return ["error": "no on-screen window for that app/pid (is it visible, not minimized?)"]
                    }
                    let shot = try await AgentCapture.rawCapture(windowID: win.id, fallbackName: app)
                    // Query generously, then keep only this window's elements.
                    let (matches, _) = try await AgentAX.query(app: nil, pid: pid, role: nil,
                                                               title: nil, max: 500, press: false)
                    let winRect = CGRect(origin: shot.origin, size: shot.size)
                    let pppX = Double(shot.image.width) / Double(max(shot.size.width, 1))
                    let pppY = Double(shot.image.height) / Double(max(shot.size.height, 1))
                    var stored: [AgentCapture.Mark] = []
                    var boxes: [(label: Int, rect: CGRect)] = []
                    var marksOut: [[String: Any]] = []
                    for m in matches {
                        guard winRect.contains(m.center) else { continue }   // this window's elements only
                        let id = stored.count + 1
                        let ir = CGRect(x: (m.rect.origin.x - shot.origin.x) * pppX,
                                        y: (m.rect.origin.y - shot.origin.y) * pppY,
                                        width: m.rect.size.width * pppX, height: m.rect.size.height * pppY)
                        boxes.append((label: id, rect: ir))
                        stored.append(AgentCapture.Mark(id: id, role: m.role, name: m.name,
                                                        rect: m.rect, center: m.center))
                        marksOut.append(["id": id, "role": m.role, "name": m.name,
                                         "x": m.rect.origin.x, "y": m.rect.origin.y,
                                         "width": m.rect.size.width, "height": m.rect.size.height,
                                         "center_x": m.center.x, "center_y": m.center.y])
                        if stored.count >= maxMarks { break }
                    }
                    let annotated = AgentCapture.annotate(image: shot.image, boxes: boxes) ?? shot.image
                    guard let url = ContextSnap.saveImage(annotated) else {
                        return ["error": "som: could not save the annotated screenshot"]
                    }
                    let fid = AgentCapture.nextMarkFrameID()
                    AgentCapture.rememberMarks(AgentCapture.MarkFrame(
                        id: fid, source: "ax", marks: stored, capturedAt: Date(),
                        pid: pid, owner: shot.owner, windowID: win.id, windowBounds: winRect))
                    var out: [String: Any] = [
                        "ok": true, "source": "ax", "path": url.path, "frame_id": fid,
                        "count": marksOut.count, "image_width": annotated.width,
                        "image_height": annotated.height, "marks": marksOut,
                    ]
                    if marksOut.count >= maxMarks {
                        out["truncated"] = true
                        out["note"] = "capped at \(maxMarks) marks; pass --max to raise"
                    }
                    return out
                } catch { return ["error": error.localizedDescription] }
            }

            // CDP-backed Set-of-Mark (DOM apps): the page draws its own overlay.
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            do {
                let r = try await AgentDOM.setOfMarks(port: port, match: match, max: maxMarks)
                // Decode + save the annotated PNG through ContextSnap so it joins
                // snap history and pruning, like a normal capture.
                guard let data = Data(base64Encoded: r.pngBase64),
                      let rep = NSBitmapImageRep(data: data),
                      let img = rep.cgImage,
                      let url = ContextSnap.saveImage(img)
                else { return ["error": "som: could not save the annotated screenshot"] }

                // Assign 1-based ids (matching the drawn labels), store the frame,
                // and emit the table the model reads beside the image.
                var stored: [AgentCapture.Mark] = []
                var marksOut: [[String: Any]] = []
                for (i, m) in r.marks.enumerated() {
                    let id = i + 1
                    stored.append(AgentCapture.Mark(id: id, role: m.role, name: m.name,
                                                    rect: m.rect, center: m.center))
                    marksOut.append(["id": id, "role": m.role, "name": m.name,
                                     "x": m.rect.origin.x, "y": m.rect.origin.y,
                                     "width": m.rect.size.width, "height": m.rect.size.height,
                                     "center_x": m.center.x, "center_y": m.center.y])
                }
                let fid = AgentCapture.nextMarkFrameID()
                AgentCapture.rememberMarks(AgentCapture.MarkFrame(
                    id: fid, source: "cdp", marks: stored, capturedAt: Date(),
                    port: port, match: match, url: r.url,
                    screenX: r.screenX, screenY: r.screenY,
                    scrollX: r.scrollX, scrollY: r.scrollY))

                var out: [String: Any] = [
                    "ok": true, "source": "cdp", "path": url.path, "frame_id": fid, "count": marksOut.count,
                    "image_width": img.width, "image_height": img.height, "marks": marksOut,
                ]
                if marksOut.count >= maxMarks {
                    out["truncated"] = true
                    out["note"] = "capped at \(maxMarks) marks; pass --max to raise"
                }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        // query-ax: read a target app's Accessibility tree (the native analog of
        // query-dom) by PID — so it disambiguates two same-named Chromes and
        // drives the live default-profile Chrome that Chrome 136+ won't expose
        // over CDP. AXPosition/AXSize are already global screen points. With
        // --press it AXPress-es the first match: a targeted activation that
        // ignores which window is frontmost.
        DevtoolsRelay.shared.onAgentQueryAX = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids)"]
            }
            let role = b["role"] as? String
            let title = (b["title"] as? String) ?? (b["name"] as? String)
            let maxN = (b["max"] as? NSNumber)?.intValue ?? 100
            let press = (b["press"] as? NSNumber)?.boolValue ?? false
            do {
                let (matches, pressed) = try await AgentAX.query(
                    app: app, pid: pid, role: role, title: title, max: maxN, press: press)
                let arr: [[String: Any]] = matches.map { m in
                    ["role": m.role, "name": m.name,
                     "x": m.rect.origin.x, "y": m.rect.origin.y,
                     "width": m.rect.size.width, "height": m.rect.size.height,
                     "center_x": m.center.x, "center_y": m.center.y]
                }
                var out: [String: Any] = ["ok": true, "count": arr.count, "matches": arr]
                if let f = matches.first {   // mirror first match (parity with query-dom)
                    out["x"] = f.rect.origin.x; out["y"] = f.rect.origin.y
                    out["width"] = f.rect.size.width; out["height"] = f.rect.size.height
                    out["center_x"] = f.center.x; out["center_y"] = f.center.y
                }
                if let pressed {
                    out["pressed"] = ["role": pressed.role, "name": pressed.name,
                                      "center_x": pressed.center.x, "center_y": pressed.center.y]
                }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        // focused: report the target app's focused element (AXFocusedUIElement)
        // so the agent can confirm a text cursor exists before typing — the
        // click → focused check → type pattern, instead of click-and-pray.
        DevtoolsRelay.shared.onAgentFocused = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids)"]
            }
            do {
                let f = try AgentAX.focused(app: app, pid: pid)
                return ["ok": true, "has_focus": f.hasFocus, "role": f.role,
                        "name": f.name, "value": f.value, "editable": f.editable]
            } catch { return ["error": error.localizedDescription] }
        }
        // click-mark: the model picked a NUMBER off the som screenshot; resolve it
        // to the stored screen center and click. Refuses (no silent misclick) if
        // the page navigated/scrolled/moved since the marks were captured.
        DevtoolsRelay.shared.onAgentClickMark = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            guard let fid = (b["frame_id"] as? String) ?? (b["frame"] as? String),
                  let id = (b["id"] as? NSNumber)?.intValue
            else { return ["error": "expected {frame_id, id} (id is a mark number from `floaty som`)"] }
            guard let frame = AgentCapture.markFrame(id: fid) else {
                return ["error": "unknown or expired frame_id; re-run `floaty som`"]
            }
            guard let mark = frame.marks.first(where: { $0.id == id }) else {
                return ["error": "no mark #\(id) in this frame (it has \(frame.marks.count); ids 1–\(frame.marks.count))"]
            }

            // AX-backed frame: validate the window hasn't moved/resized/closed
            // (the native analog of the capture-frame guard), raise that exact
            // PROCESS (pid-precise → no two-Chrome ambiguity), then click.
            if frame.source == "ax" {
                guard let cur = AgentCapture.listWindows().first(where: { $0.id == frame.windowID }) else {
                    return ["error": "the window closed since `floaty som`; re-run `floaty som`"]
                }
                let tol: CGFloat = 4
                if abs(cur.bounds.origin.x - frame.windowBounds.origin.x) > tol
                    || abs(cur.bounds.origin.y - frame.windowBounds.origin.y) > tol
                    || abs(cur.bounds.size.width - frame.windowBounds.size.width) > tol
                    || abs(cur.bounds.size.height - frame.windowBounds.size.height) > tol {
                    return ["error": "the window moved or resized since `floaty som`; re-run `floaty som`"]
                }
                // Raise that EXACT process (pid-precise → no two-Chrome ambiguity)
                // via the full cooperative-activation path, then click its center.
                let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
                let ok = AgentInput.click(at: mark.center, button: self.button(b), modifiers: self.mods(b),
                                          clicks: clicks, pacing: self.pacing(b),
                                          target: nil, targetPID: frame.pid != 0 ? frame.pid : nil)
                return ok ? ["ok": true, "id": id, "screen_x": mark.center.x, "screen_y": mark.center.y,
                             "role": mark.role, "name": mark.name]
                          : self.inputFailure("click-mark", b)
            }

            // CDP-backed frame.
            // Staleness guard: one eval re-reading the page's window origin, scroll,
            // and url — any drift means the stored screen coords are wrong now.
            do {
                // Return a plain object — runJavaScript re-serializes the value,
                // so JSON.stringify here would double-encode to a String and the
                // [String:Any] cast below would silently fail (skipping the guard).
                let probe = "({sx:window.screenX,sy:window.screenY,scx:window.scrollX,scy:window.scrollY,url:location.href})"
                if let json = try await AgentDOM.runJavaScript(expression: probe, port: frame.port, match: frame.match),
                   let st = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                    func d(_ k: String) -> Double { (st[k] as? NSNumber)?.doubleValue ?? .nan }
                    let tol = 2.0
                    if (st["url"] as? String) != frame.url
                        || abs(d("sx") - frame.screenX) > tol || abs(d("sy") - frame.screenY) > tol
                        || abs(d("scx") - frame.scrollX) > tol || abs(d("scy") - frame.scrollY) > tol {
                        return ["error": "page changed since `floaty som` (navigated, scrolled, or window moved); re-run `floaty som`"]
                    }
                }
            } catch { return ["error": "click-mark: \(error.localizedDescription)"] }
            // Raise the tab's window so the screen-point click lands on it.
            try? await AgentDOM.bringToFront(port: frame.port, match: frame.match)
            let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
            let ok = AgentInput.click(at: mark.center, button: self.button(b), modifiers: self.mods(b),
                                      clicks: clicks, pacing: self.pacing(b), target: self.target(b))
            return ok ? ["ok": true, "id": id, "screen_x": mark.center.x, "screen_y": mark.center.y,
                         "role": mark.role, "name": mark.name]
                      : self.inputFailure("click-mark", b)
        }

        // Keep per-feature data (Devtools logs, Browser Context captures,
        // Context Snaps) within the user's retention/size budget: one sweep
        // now, then hourly.
        StorageJanitor.shared.start()

        // Restore every window from the per-window records (frame + avatar
        // style). No records (first run / legacy install) → one fresh window,
        // which falls back to the old shared-frame slot for migration.
        let records = WindowStateStore.load()

        // Sweep transcript logs no saved tab claims. Sessions discarded while
        // the app runs delete their own file; this catches what they can't —
        // "Quit Without Saving", crashed-away windows, pinned windows dropped
        // at quit. Runs before any restored tab re-opens its log.
        let liveSessionIDs = Set(records.flatMap { $0.tabs ?? [] }
                                        .compactMap { $0.sessionID })
        TranscriptDisk.purgeOrphans(keeping: liveSessionIDs)

        if records.isEmpty {
            makeWindow()
        } else {
            for record in records { makeWindow(restoring: record) }
        }

        hotKey = HotKey()
        registerHotKeys()

        statusItem.onToggle        = { [weak self] in self?.toggle() }
        statusItem.onNewWindow     = { [weak self] in self?.makeWindow() }
        statusItem.onRunBackgroundTask = { [weak self] in self?.runBackgroundTask() }
        statusItem.onNewTab        = { [weak self] in self?.newTerminalTabInCurrentWindow() }
        statusItem.onNewBrowserTab = { [weak self] in self?.newBrowserTabInCurrentWindow() }
        statusItem.onNewNote       = { [weak self] in self?.newNoteTabInCurrentWindow() }
        statusItem.onMirrorWindow  = { [weak self] in self?.newMirrorTabInCurrentWindow() }
        statusItem.onCompareFiles  = { [weak self] in self?.compareFilesInCurrentWindow() }
        statusItem.onShowRuler     = { [weak self] in self?.ruler.toggle() }
        statusItem.onPreferences   = { [weak self] in self?.settingsWC.show() }

        // The `ruler` terminal helper emits a private OSC that TerminalController
        // turns into this notification — summon (toggle) the ruler from any shell.
        NotificationCenter.default.addObserver(
            forName: .floatySummonRuler, object: nil, queue: .main
        ) { [weak self] _ in self?.ruler.toggle() }

        switcher.sessionsProvider = { [weak self] in self?.sessionEntries() ?? [] }
        switcher.onSummon = { [weak self] entry in self?.summon(entry) }
        switcher.onClose = { [weak self] entry in
            guard let self, let wc = entry.window,
                  self.windows.contains(where: { $0 === wc }) else { return }
            wc.closeSession(entry.tab)
        }

        // Feed the menu the list of individually-minimized windows so each can
        // be restored on its own, and provide the restore action.
        statusItem.hiddenWindowsProvider = { [weak self] in
            (self?.windows ?? [])
                .filter { $0.isMinimized }
                .map { (id: $0.id, title: $0.displayTitle) }
        }
        statusItem.onRestoreWindow = { [weak self] id in
            self?.windows.first { $0.id == id }?.show()
        }

        // Ghosted (click-through) windows can't be clicked; this menu section
        // is how they come back.
        statusItem.ghostedWindowsProvider = { [weak self] in
            (self?.windows ?? [])
                .filter { $0.isGhosted }
                .map { (id: $0.id, title: $0.displayTitle) }
        }
        statusItem.onUnghostWindow = { [weak self] id in
            self?.windows.first { $0.id == id }?.setGhosted(false)
        }

        // Fleet summary: periodically count terminal sessions that are
        // working vs. blocked waiting on the user, and surface the totals
        // beside the menu-bar icon.
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let terminals = self.windows.flatMap(\.tabs)
                .compactMap { $0 as? TerminalController }
            let waiting = terminals.filter(\.awaitingInput).count
            let working = terminals.filter { $0.hasRunningForegroundJob && !$0.awaitingInput }.count
            self.statusItem.updateSummary(working: working, waiting: waiting)
        }
        timer.tolerance = 1
        fleetSummaryTimer = timer

        // Re-register the global hotkey if it changes in Preferences.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ask whether to save the session — only when there's something worth
        // saving (any unpinned window; pinned windows are dropped regardless,
        // since their Space can't be re-targeted after relaunch).
        let savable = windows.filter { !$0.isPinned }
        if !savable.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Save windows for next launch?"
            alert.informativeText = """
                Saved windows reopen with their tabs: terminals restart in \
                their last directory (running processes end), browser tabs \
                reload their page. Windows pinned to a Space are dropped — \
                Spaces can't be re-targeted after a relaunch.
                """
            alert.addButton(withTitle: "Save & Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AppRuntime.isQuitting = true
                WindowStateStore.save(savable.map { $0.stateRecord })
                return .terminateNow
            case .alertSecondButtonReturn:
                AppRuntime.isQuitting = true
                // Keep only the front window's geometry (no tabs), so the next
                // launch opens one fresh window in a familiar spot.
                if let first = savable.first {
                    var record = first.stateRecord
                    record.tabs = nil
                    record.activeIndex = nil
                    WindowStateStore.save([record])
                } else {
                    WindowStateStore.save([])
                }
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        AppRuntime.isQuitting = true
        return .terminateNow
    }

    /// Writes the current per-window records (frame + avatar + tabs) to disk.
    /// Called whenever a window reports a state change, and on close — this
    /// continuous snapshot doubles as crash recovery; the quit prompt decides
    /// what the FINAL saved session looks like. Pinned windows are excluded
    /// (their Space identity can't survive a relaunch).
    private func persistWindowState() {
        WindowStateStore.save(windows.filter { !$0.isPinned }.map { $0.stateRecord })
    }

    /// The toggle combo currently registered with Carbon, so unrelated settings
    /// changes (font slider ticks, opacity drags…) don't unregister/re-register
    /// the hotkeys dozens of times per second.
    private var registeredToggleCombo: (code: UInt32, mods: UInt32)?

    @objc private func settingsChanged() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        guard registeredToggleCombo?.code != code
           || registeredToggleCombo?.mods != mods else { return }
        registerHotKeys()
    }

    /// Registers the global hotkeys:
    ///  - id 1: the toggle (⌥⌘7 by default, customizable) — localized hide/show.
    ///  - id 2: spawn-on-this-Space, fixed at ⌥⌘5.
    ///  - id 3: session switcher, fixed at ⌥⌘K.
    /// Re-called whenever Settings change so a rebind of the toggle updates it.
    private func registerHotKeys() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        hotKey.register(id: 1, keyCode: code, modifiers: mods, action: { [weak self] in
            self?.handleTogglePressed()
        }, onRelease: { [weak self] in
            self?.handleToggleReleased()
        })
        registeredToggleCombo = (code, mods)
        hotKey.register(id: 2, keyCode: UInt32(kVK_ANSI_5),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.spawnOnCurrentSpace()
        }
        hotKey.register(id: 3, keyCode: UInt32(kVK_ANSI_K),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleSwitcher()
        }
    }

    // MARK: - Windows

    /// Creates a new floating window.
    /// - Parameter initialDirectory: Starting directory for the new window's
    ///   first terminal tab. Pass nil to use $HOME (the default).
    /// - Parameter record: When restoring at launch, the persisted record whose
    ///   frame and avatar style this window adopts (skips normal placement).
    @discardableResult
    private func makeWindow(initialDirectory: String? = nil,
                            restoring record: WindowRecord? = nil) -> TerminalWindowController {
        let isLaunchWindow = windows.isEmpty
        // Cascade from the window the user is currently looking at (if any) so a
        // new window lands where they are — not from a stale shared frame that
        // might belong to a pinned window on another Space.
        let reference = (isLaunchWindow || record != nil) ? nil : frontWindowFrameOnCurrentSpace()
        // A record with saved tabs starts empty — restoreTabs() rebuilds them.
        let restoredTabs = record?.tabs ?? []
        let wc = TerminalWindowController(initialDirectory: initialDirectory,
                                          startEmpty: !restoredTabs.isEmpty)
        wireCallbacks(wc)
        windows.append(wc)
        if let record {
            wc.applyRestored(record)
            if !restoredTabs.isEmpty {
                wc.restoreTabs(restoredTabs, activeIndex: record.activeIndex ?? 0)
            }
        } else {
            wc.placeInitialFrame(reference: reference, isLaunchWindow: isLaunchWindow)
        }
        wc.show()
        persistWindowState()
        return wc
    }

    /// Frame of the window currently visible on the user's Space, preferring the
    /// key window. Returns nil when no FloatyTerm window is on the active Space
    /// (e.g. a fresh Space where all existing windows are pinned elsewhere).
    private func frontWindowFrameOnCurrentSpace() -> NSRect? {
        if let key = windows.first(where: { $0.isKey }) { return key.panel.frame }
        if let here = windows.first(where: isPresentOnCurrentSpace) { return here.panel.frame }
        return nil
    }

    /// Creates a new floating window that starts empty and immediately adopts
    /// `tab`.  The panel is positioned so `screenPoint` (the drop location) sits
    /// near the top-left of the new window.
    @discardableResult
    private func makeWindowAdopting(_ tab: any TabContent, at screenPoint: NSPoint) -> TerminalWindowController {
        let wc = TerminalWindowController(startEmpty: true)
        wireCallbacks(wc)
        windows.append(wc)
        // Position the new window near the drop point, kept fully on-screen
        // (a drop near a screen edge must not strand the window off-screen).
        let windowSize = wc.panel.frame.size
        let raw = NSRect(x: screenPoint.x - 20,
                         y: screenPoint.y - windowSize.height + 20,
                         width: windowSize.width, height: windowSize.height)
        wc.panel.setFrame(wc.panel.clampToVisibleScreen(raw), display: false)
        wc.adoptTab(tab)
        wc.show()
        persistWindowState()
        return wc
    }

    /// Wires the three standard callbacks that all windows share.
    /// `wc` must be captured weakly: these closures are stored ON wc itself,
    /// so a strong capture is a retain cycle that leaks every closed window.
    private func wireCallbacks(_ wc: TerminalWindowController) {
        wc.onNewWindow = { [weak self, weak wc] in
            self?.makeWindow(initialDirectory: wc?.activeTerminalWorkingDirectory)
        }
        wc.onClosed = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.persistWindowState()
        }
        wc.onOpenPreferences = { [weak self] in self?.settingsWC.show() }
        wc.onDetachTab = { [weak self] tab, screenPoint in
            self?.makeWindowAdopting(tab, at: screenPoint)
        }
        wc.onStateChanged = { [weak self] in self?.persistWindowState() }
        wc.onOpenSwitcher = { [weak self] in self?.toggleSwitcher() }
        wc.onSessionDone = { [weak self] tab in self?.summonForAttention(tab) }
    }

    /// An armed "notify when done" session finished: bring it to the user's
    /// current Space via the switcher's summon path (which handles every
    /// window state — hidden, collapsed, tickered, pinned-away via borrow),
    /// then pulse whichever window hosts the tab now so the arrival is seen.
    private func summonForAttention(_ tab: any TabContent) {
        guard let wc = windows.first(where: { w in w.tabs.contains { $0 === tab } }) else { return }
        summon(SessionEntry(window: wc, tab: tab, name: tab.displayName,
                            location: "", status: .idle,
                            isTerminal: tab is TerminalController,
                            isAgent: (tab as? TerminalController)?.isAgentSession == true,
                            windowSymbol: wc.avatarStyle.symbol,
                            windowColor: wc.avatarStyle.color))
        // Re-resolve the host: a pinned-away source lends the tab to a fresh
        // borrower window created by summon().
        windows.first(where: { w in w.tabs.contains { $0 === tab } })?.pulseAttention()
    }

    private func currentWindow() -> TerminalWindowController? {
        windows.first(where: { $0.isKey }) ?? windows.last
    }

    /// Fire-and-forget: ask for a command, run it in a fresh session that
    /// immediately collapses to a bubble, armed to summon the user when it
    /// finishes (the window's 2s tick → onSessionDone → summonForAttention
    /// handles the rest).
    private func runBackgroundTask() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Run Task in Background"
        alert.informativeText = "Runs in a new session collapsed to a bubble; "
            + "it will summon you when it finishes."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. npm test"
        alert.accessoryView = field
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        // Inherit the directory the user is currently working in.
        let wc = makeWindow(initialDirectory: currentWindow()?.activeTerminalWorkingDirectory)
        // Give the shell a beat to start (the pty buffers input regardless),
        // then type the command, arm notify-when-done, and get out of the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak wc] in
            guard let self, let wc, self.windows.contains(where: { $0 === wc }),
                  let session = wc.tabs.first as? TerminalController else { return }
            session.run(command: command)
            session.notifyWhenDone = true
            wc.collapseToAvatar()
        }
    }

    private func newTerminalTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewTab()
            wc.show()
        } else {
            makeWindow()
        }
    }

    private func newBrowserTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewBrowserTab()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add browser.
            let wc = makeWindow()
            wc.openNewBrowserTab()
        }
    }

    private func newNoteTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewNote()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add note.
            let wc = makeWindow()
            wc.openNewNote()
        }
    }

    private func newMirrorTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewMirror()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add mirror.
            let wc = makeWindow()
            wc.openNewMirror()
        }
    }

    /// Menu / ⇧⌘D entry: present the two-file picker in the current window
    /// (creating one if none exists), then open a diff tab.
    private func compareFilesInCurrentWindow() {
        let wc = currentWindow() ?? makeWindow()
        wc.show()
        wc.openCompareFilesPanel()
    }

    /// Relay entry (shell shim): paths are already resolved — open the diff tab
    /// directly in the current window, creating one if needed.
    private func compareFilesInCurrentWindow(left: URL, right: URL) {
        let wc = currentWindow() ?? makeWindow()
        wc.show()
        wc.addDiffTab(left: left, right: right)
    }

    /// A FloatyTerm window the user can actually see on the CURRENT Space:
    /// any visible roaming (unpinned, all-Spaces) window, or a pinned window
    /// that happens to live on the active Space.
    private func isPresentOnCurrentSpace(_ wc: TerminalWindowController) -> Bool {
        wc.isVisible && (!wc.isPinned || wc.isOnActiveSpace)
    }

    /// ⌥⌘7 — a localized toggle for the CURRENT Space. It only hides or shows
    /// terminals relevant to where the user is; it never spawns (that's ⌥⌘5)
    /// and never yanks pinned windows bound to other Spaces.
    /// Returns the windows it revealed (empty when it hid or spawned), so the
    /// hold-to-peek path knows what to put away again on key release.
    @discardableResult
    private func toggle() -> [TerminalWindowController] {
        // Bootstrap: no windows exist at all → create the first one.
        if windows.isEmpty {
            makeWindow()
            return []
        }

        // If something is already visible on this Space, dismiss only those.
        // Pinned windows bound to OTHER Spaces are left untouched.
        if windows.contains(where: isPresentOnCurrentSpace) {
            windows.filter(isPresentOnCurrentSpace).forEach { $0.hide() }
            return []
        }

        // Nothing here: reveal everything that was hidden — roaming windows
        // (which join all Spaces, so they reappear here) AND pinned windows
        // hidden by a previous ⌥⌘7 (each reappears on its own Space). We skip
        // windows tucked away via their own controls (minimize / collapse
        // bubble / ticker strip), which are restored differently. This keeps
        // ⌥⌘7 a symmetric toggle: whatever it hides, it brings back.
        let toShow = windows.filter {
            !$0.isVisible && !$0.isMinimized && !$0.isCollapsed && !$0.isTicker
        }
        toShow.forEach { $0.show() }
        return toShow
    }

    // MARK: - Hold-to-peek (toggle hotkey held = show while held)

    private var toggleKeyIsDown = false
    private var togglePressTime: Date?
    private var peekCandidates: [TerminalWindowController] = []

    private func handleTogglePressed() {
        guard !toggleKeyIsDown else { return }   // ignore key auto-repeat
        toggleKeyIsDown = true
        togglePressTime = Date()
        peekCandidates = toggle()
    }

    /// Released after holding ≥0.45s on a press that REVEALED windows → that
    /// was a peek: tuck them away again. A quick tap keeps them (normal toggle).
    private func handleToggleReleased() {
        toggleKeyIsDown = false
        guard let pressed = togglePressTime else { return }
        togglePressTime = nil
        if Date().timeIntervalSince(pressed) >= 0.45, !peekCandidates.isEmpty {
            peekCandidates.filter { $0.isVisible }.forEach { $0.hide() }
        }
        peekCandidates = []
    }

    /// ⌥⌘5 — explicitly spawn a fresh window on the current Space, regardless
    /// of what's pinned elsewhere. Placement cascades from a window already on
    /// this Space, or centers on the active screen when the Space is empty.
    private func spawnOnCurrentSpace() {
        makeWindow()
    }

    // MARK: - Session switcher (⌥⌘K)

    private func toggleSwitcher() {
        // Nothing to switch between → behave like the toggle bootstrap.
        if windows.isEmpty {
            makeWindow()
            return
        }
        switcher.toggle()
    }

    /// Snapshot of every session (tab) across every window for the switcher.
    /// With multiple windows the location carries a "win N" prefix, and every
    /// row gets its window's avatar identity — together they pin down exactly
    /// which window (and overlaid app) a session lives in.
    private func sessionEntries() -> [SessionEntry] {
        let many = windows.count > 1
        return windows.enumerated().flatMap { i, wc in
            let prefix = many ? "win \(i + 1) · " : ""
            return wc.tabs.map { tab in
                SessionEntry(window: wc,
                             tab: tab,
                             name: tab.displayName,
                             location: prefix + location(of: wc),
                             status: wc.status(of: tab),
                             isTerminal: tab is TerminalController,
                             isAgent: (tab as? TerminalController)?.isAgentSession == true,
                             windowSymbol: wc.avatarStyle.symbol,
                             windowColor: wc.avatarStyle.color)
            }
        }
    }

    private func location(of wc: TerminalWindowController) -> String {
        // The app this window was pinned over, e.g. "another Space (Chrome)".
        let app = wc.pinnedAppName.map { " (\($0))" } ?? ""
        if wc.isCollapsed { return wc.isPinned ? "in bubble\(app)" : "in bubble" }
        if wc.isTicker { return wc.isPinned ? "in ticker\(app)" : "in ticker" }
        if wc.isGhosted { return "ghosted" }
        if let linked = wc.linkedAppName {
            return wc.isVisible ? "over \(linked)" : "waiting for \(linked)"
        }
        if wc.isMinimized || !wc.isVisible { return wc.isPinned ? "hidden\(app)" : "hidden" }
        if wc.isPinned {
            // Judge by actual on-screen presence, not the hidden-panel guess.
            return (wc.presenceOnActiveSpace ?? false) ? "pinned here" : "another Space\(app)"
        }
        return "here"
    }

    /// Brings the chosen session to the user's current Space.
    ///
    /// macOS offers no public API to place a window on a non-active Space, so
    /// "send it back" works at the TAB level: when the session's window is
    /// pinned to another Space, we borrow the tab into a window here while the
    /// source window stays where it is — the header's return arrow re-merges
    /// the tab into it. A single-tab window LENDS its session instead: it
    /// stays behind empty (bubble / ticker / placeholder panel), keeping its
    /// pin, Space, and frame, so Return restores everything exactly as it was.
    private func summon(_ entry: SessionEntry) {
        guard let wc = entry.window,
              windows.contains(where: { $0 === wc }),
              let idx = wc.tabs.firstIndex(where: { $0 === entry.tab }) else { return }
        let tab = entry.tab

        // Is the window away on another Space? Judged by whatever is actually
        // on screen (panel, bubble, or ticker strip) — `panel.isOnActiveSpace`
        // lies for hidden panels, which is what broke pinned+collapsed and
        // pinned+tickered windows. Unknown presence (pinned + minimized) is
        // treated as away: the whole-window path is correct either way.
        let away = wc.isPinned && !(wc.presenceOnActiveSpace ?? false)

        if !away {
            // Roaming (joins all Spaces) or pinned right here: reveal + focus.
            wc.selectTab(at: idx)
            if wc.isGhosted { wc.setGhosted(false) }   // summon = interactive again
            if wc.isCollapsed {
                wc.expandFromAvatar()
            } else if wc.isTicker {
                wc.expandFromTicker()
            } else {
                wc.show()
            }
            return
        }

        // Borrow the tab into a window on this Space. The source window never
        // moves: with other tabs it keeps living normally; with only this one
        // it LENDS it, staying behind empty (still pinned, still collapsed /
        // tickered / minimized, however it was) as the permanent home the
        // Return arrow sends the tab back to. Either way the arrow shows.
        if wc.tabs.count >= 2 {
            wc.releaseTab(tab)
        } else if wc.lendOnlyTab() == nil {
            return
        }
        let borrower = makeWindowAdopting(tab, at: .zero)
        if let frame = summonTargetFrame(size: borrower.panel.frame.size) {
            borrower.panel.setFrame(frame, display: false)
        }
        if windows.contains(where: { $0 === wc }) {
            borrower.markBorrowed(tab, from: wc)
        }
    }

    /// The user's summon grid point on the active screen, sized to `size` —
    /// where borrowed and whole-summoned windows land, away from whatever
    /// terminal is already in view. The screen under the mouse is "where the
    /// user is" — NSScreen.main tracks the key window, which is wrong when
    /// summoning over another app (e.g. fullscreen on a second display).
    private func summonTargetFrame(size: NSSize) -> NSRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vis = screen?.visibleFrame else { return nil }
        return Settings.shared.summonPosition.frame(forSize: size, in: vis)
    }

    // MARK: - Agent route body parsing

    /// Optional pacing from the JSON body: `duration` (seconds) wins, else a
    /// truthy `human` flag uses a default duration; absent → instant.
    private func pacing(_ b: [String: Any]) -> AgentInput.Pacing {
        if let d = (b["duration"] as? NSNumber)?.doubleValue { return .human(duration: d) }
        if (b["human"] as? NSNumber)?.boolValue == true { return .human(duration: 0.4) }
        return .instant
    }
    private func point(_ b: [String: Any]) -> CGPoint? {
        guard let x = (b["x"] as? NSNumber)?.doubleValue,
              let y = (b["y"] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }
    private func button(_ b: [String: Any]) -> AgentInput.MouseButton {
        AgentInput.MouseButton(rawValue: (b["button"] as? String) ?? "left") ?? .left
    }
    private func mods(_ b: [String: Any]) -> [String] {
        (b["modifiers"] as? [Any])?.compactMap { $0 as? String } ?? []
    }
    private func target(_ b: [String: Any]) -> String? { b["target"] as? String }
    /// PID target (wins over `--target` name): pins input to one exact process,
    /// so keystrokes can't land in the wrong same-named app (two Chromes).
    private func targetPID(_ b: [String: Any]) -> pid_t? {
        (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
    }

    /// Parse a frame body ({frame_id|frame, x, y} in image pixels) and resolve
    /// it to a global screen point + the owning app (to raise before acting).
    /// Throws a descriptive error for missing fields or a stale/unknown frame.
    @MainActor
    private func resolveFrame(_ b: [String: Any]) throws -> (point: CGPoint, owner: String?) {
        guard let frameID = (b["frame_id"] as? String) ?? (b["frame"] as? String),
              let ix = (b["x"] as? NSNumber)?.doubleValue,
              let iy = (b["y"] as? NSNumber)?.doubleValue
        else { throw SimpleError("expected {frame_id, x, y} (x/y in image pixels)") }
        return try AgentCapture.resolveInFrame(frameID: frameID, imageX: ix, imageY: iy)
    }

    /// Minimal error so a missing-field message surfaces as the relay's JSON error.
    private struct SimpleError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// An input command returned false. CGEvent drops are silent, so re-derive
    /// the most likely cause at failure time and report it — otherwise the agent
    /// gets a bare "type failed" and can't tell a missing permission from a
    /// not-running target from a target that wouldn't come to the front (the
    /// last of which is how stray keystrokes used to land in the caller's own
    /// terminal). `extra` appends a command-specific cause (e.g. unknown key).
    private func inputFailure(_ verb: String, _ b: [String: Any], extra: String? = nil) -> [String: Any] {
        let tail = extra.map { " (\($0))" } ?? ""
        if !AXIsProcessTrusted() {
            return ["error": "\(verb) failed: FloatyTerm needs Accessibility access — grant it under "
                + "System Settings → Privacy & Security → Accessibility, then relaunch.\(tail)"]
        }
        if let pid = targetPID(b) {
            let running = NSRunningApplication(processIdentifier: pid) != nil
            return ["error": running
                ? "\(verb) failed: couldn't bring pid \(pid) to the front\(tail)."
                : "\(verb) failed: no running process with pid \(pid)\(tail)."]
        }
        if let t = target(b) {
            let running = NSWorkspace.shared.runningApplications.contains {
                $0.localizedName == t || $0.bundleIdentifier == t
            }
            return ["error": running
                ? "\(verb) failed: couldn't bring \"\(t)\" to the front\(tail)."
                : "\(verb) failed: target app \"\(t)\" isn't running\(tail)."]
        }
        return ["error": "\(verb) failed\(tail)."]
    }

}
