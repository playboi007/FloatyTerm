import AppKit

/// "What changed" on every actuator reply — so the agent learns that a dialog
/// opened, a window closed or a page title changed WITHOUT another look.
/// (Pattern: the browser toolset's `state_changes`, reported with every result.)
///
/// Per target app: its on-screen windows (id → title), compared with what the
/// previous report for that app saw. A change that lands a beat after the
/// action (a sheet sliding in) is reported on the NEXT call — the same "since
/// the last report" rule the toolsets use. One window-list read per call,
/// about a millisecond. Runs on the relay's connection threads, so it locks.
final class AgentChanges {
    static let shared = AgentChanges()

    /// Routes whose reply carries `changes`. Read-only verbs don't: they
    /// change nothing, and their baseline would hide the next actuator's delta.
    static let routes: Set<String> = ["click", "move", "drag", "scroll", "type", "key", "click-in-frame",
                                      "move-in-frame", "click-mark", "set-text", "run", "query-ax"]

    private struct Snapshot {
        var windows: [UInt32: String]
        var front: pid_t
    }

    private let lock = NSLock()
    private var last: [pid_t: Snapshot] = [:]

    struct Ticket {
        let pid: pid_t
        let background: Bool
    }

    /// Before the action. nil = nothing to track (no target app known).
    func begin(route: String, args: [String: Any]) -> Ticket? {
        guard Self.routes.contains(route) else { return nil }
        // query-ax reports changes only when it acts.
        if route == "query-ax", !["press", "focus", "set_value", "scroll_to", "action"].contains(where: { args[$0] != nil }) {
            return nil
        }
        let background = AgentBackground.isBackground(args)
        guard let pid = targetPID(args) else { return nil }
        lock.lock()
        let known = last[pid] != nil
        lock.unlock()
        if !known { store(pid, snapshot(pid)) }
        return Ticket(pid: pid, background: background)
    }

    /// After the action: the differences since the last report for the app.
    func finish(_ t: Ticket) -> [String] {
        let now = snapshot(t.pid)
        lock.lock()
        let before = last[t.pid]
        lock.unlock()
        store(t.pid, now)
        guard let before else { return [] }
        let app = NSRunningApplication(processIdentifier: t.pid)?.localizedName ?? "pid \(t.pid)"
        var out: [String] = []
        for (id, title) in now.windows where before.windows[id] == nil {
            out.append("\(app) opened a window\(label(title))")
        }
        for (id, title) in before.windows where now.windows[id] == nil {
            out.append("\(app) closed a window\(label(title)) (or it left the screen)")
        }
        for (id, title) in now.windows {
            if let old = before.windows[id], old != title, !old.isEmpty || !title.isEmpty {
                out.append("window \"\(old.prefix(60))\" is now \"\(title.prefix(60))\"")
            }
        }
        // In background mode the front app is the human's business (the focus
        // shield reports interference); in foreground mode it matters.
        if !t.background, now.front != before.front, now.front != 0 {
            let name = NSRunningApplication(processIdentifier: now.front)?.localizedName ?? "pid \(now.front)"
            out.append("\(name) is now the front app")
        }
        return Array(out.prefix(8))
    }

    private func label(_ title: String) -> String { title.isEmpty ? "" : " \"\(title.prefix(60))\"" }

    private func store(_ pid: pid_t, _ s: Snapshot) {
        lock.lock()
        if last.count > 32, last[pid] == nil { last.removeAll() }   // apps come and go; stay small
        last[pid] = s
        lock.unlock()
    }

    private func snapshot(_ pid: pid_t) -> Snapshot {
        var windows: [UInt32: String] = [:]
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            // Skip slivers (tab-drag ghosts, 1-pt helper windows).
            if ((b["Width"] as? NSNumber)?.doubleValue ?? 0) < 40 || ((b["Height"] as? NSNumber)?.doubleValue ?? 0) < 40 {
                continue
            }
            windows[id] = info[kCGWindowName as String] as? String ?? ""
        }
        return Snapshot(windows: windows, front: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    /// The app the call acts on: --pid, else --target/--app by name, else the
    /// owner of the window under the point, else the front app (foreground).
    private func targetPID(_ b: [String: Any]) -> pid_t? {
        if let p = (b["pid"] as? NSNumber) { return pid_t(p.intValue) }
        if let name = (b["target"] as? String) ?? (b["app"] as? String) {
            let hits = NSWorkspace.shared.runningApplications.filter {
                $0.localizedName == name || $0.bundleIdentifier == name
                    || ($0.localizedName?.localizedCaseInsensitiveContains(name) ?? false)
            }
            if hits.count == 1 { return hits[0].processIdentifier }
        }
        let x = (b["x"] as? NSNumber)?.doubleValue ?? (b["from_x"] as? NSNumber)?.doubleValue
        let y = (b["y"] as? NSNumber)?.doubleValue ?? (b["from_y"] as? NSNumber)?.doubleValue
        if let x, let y, b["frame"] == nil, b["frame_id"] == nil {
            let p = CGPoint(x: x, y: y)
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let me = ProcessInfo.processInfo.processIdentifier
            for info in list where (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
                let owner = (info[kCGWindowOwnerPID as String] as? Int32) ?? 0
                guard owner != me, let b = info[kCGWindowBounds as String] as? [String: Any] else { continue }
                func n(_ k: String) -> CGFloat { CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
                if CGRect(x: n("X"), y: n("Y"), width: n("Width"), height: n("Height")).contains(p) { return owner }
            }
        }
        if AgentBackground.isBackground(b) { return nil }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return front == ProcessInfo.processInfo.processIdentifier ? nil : front
    }
}
