import AppKit
import Foundation

/// Stable element refs — the element itself, not a point measured earlier.
///
/// A `som` mark or a `query-ax` row used to be a number plus a screen point
/// stored at read time: a click went to that point even if the element had
/// moved, and the same element got a new number on every read. A ref names
/// the element. It stays the same across reads, it is resolved when the
/// action runs, and a ref whose element is gone is an error ("run som again"),
/// never a click on whatever is there now. (Pattern from Anthropic's browser
/// toolset example driver.)
///
///   ax_12   an Accessibility element, held here by the host
///   ref_12  a DOM element, held in the page (`pageJS`), dropped by navigation
enum AXRefs {
    private static let lock = NSLock()
    private static var byID: [Int: (pid: pid_t, el: AXUIElement)] = [:]
    private static var byHash: [Int: [Int]] = [:]
    private static var next = 1
    /// Bounded: a long session reads many trees. The oldest quarter goes when
    /// the table is full; its refs then report "unknown", like stale ones.
    private static let cap = 4000

    /// The ref of this element — the same one every time it is seen.
    static func ref(for el: AXUIElement, pid: pid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        let h = Int(bitPattern: UInt(CFHash(el)))
        for id in byHash[h] ?? [] where byID[id].map({ CFEqual($0.el, el) }) == true { return "ax_\(id)" }
        let id = next
        next += 1
        byID[id] = (pid, el)
        byHash[h, default: []].append(id)
        if byID.count > cap {
            let cutoff = next - cap * 3 / 4
            byID = byID.filter { $0.key >= cutoff }
            byHash = byHash.compactMapValues { ids in
                let kept = ids.filter { $0 >= cutoff }
                return kept.isEmpty ? nil : kept
            }
        }
        return "ax_\(id)"
    }

    static func isRef(_ s: String) -> Bool {
        s.hasPrefix("ax_") && s.count > 3 && s.dropFirst(3).allSatisfy(\.isNumber)
    }

    enum Lookup {
        case found(pid: pid_t, el: AXUIElement)
        case unknown        // never issued, or evicted
        case stale          // the element is gone (closed, re-rendered)
    }

    static func lookup(_ ref: String) -> Lookup {
        guard isRef(ref), let id = Int(ref.dropFirst(3)) else { return .unknown }
        lock.lock()
        let entry = byID[id]
        lock.unlock()
        guard let entry else { return .unknown }
        guard NSRunningApplication(processIdentifier: entry.pid) != nil else { return .stale }
        var role: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(entry.el, kAXRoleAttribute as CFString, &role)
        if r == .invalidUIElement { return .stale }
        return .found(pid: entry.pid, el: entry.el)
    }

    static func staleMessage(_ ref: String, _ l: Lookup) -> String {
        switch l {
        case .stale:
            return "\(ref) is stale — that element is gone (the window closed or the view re-rendered). "
                + "Read the tree again (`query-ax`, `som --pid`, `find`) for fresh refs."
        default:
            return "\(ref) is not a known ref (refs come from `query-ax`, `som --pid` and `find`; very old ones "
                + "are dropped). Read the tree again for fresh refs."
        }
    }
}

/// The DOM half: a ref table that lives in the page.
enum DOMRefs {
    /// Evaluates to the page's ref table, creating it on first use. Elements
    /// are held through WeakRef, so the table never keeps a removed element
    /// alive; it prunes dead entries at 5,000 and then drops the oldest.
    /// `R.of(el)` → "ref_N" (stable per element), `R.get(ref)` → the element
    /// or null when it is gone.
    static let tableJS = """
    (function(){var R=window.__floatyRefs;if(R&&R.v===1)return R;\
    R=window.__floatyRefs={v:1,n:1,m:new Map(),w:new WeakMap()};\
    R.of=function(el){var r=R.w.get(el);if(r&&R.m.has(r))return r;r='ref_'+(R.n++);R.w.set(el,r);\
    R.m.set(r,new WeakRef(el));if(R.m.size>5000)R.prune();return r;};\
    R.get=function(r){var w=R.m.get(r),el=w&&w.deref();return el&&el.isConnected?el:null;};\
    R.prune=function(){R.m.forEach(function(w,k){var e=w.deref();if(!e||!e.isConnected)R.m.delete(k);});\
    var over=R.m.size-4000;if(over>0){var it=R.m.keys();while(over-->0)R.m.delete(it.next().value);}};\
    return R;})()
    """

    static func staleMessage(_ ref: String) -> String {
        "\(ref) is stale or not on this page (the page navigated or re-rendered that element). "
            + "Run `som`, `query-dom` or `find` again for fresh refs."
    }
}
