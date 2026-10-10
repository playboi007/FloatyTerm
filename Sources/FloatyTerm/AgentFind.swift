import AppKit

/// `floaty find --query "add to cart button"` — the top matches, each with a
/// ref to act on. AX path (`--pid` / `--app`) or DOM path (`--via-extension`
/// / `--port`); one scorer (ElementFind) for both.
enum AgentFind {

    static let limit = 20

    /// AX: every named element and every control in the app (or under one ref).
    @MainActor
    static func ax(query: String, app: String?, pid: pid_t?, under: AXUIElement?) async throws -> [ElementFind.Hit] {
        let r = try await AgentAX.queryAct(app: app, pid: pid, role: nil, title: nil, max: 3000,
                                           act: nil, root: under, all: true)
        let controls: Set<String> = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
                                     "AXPopUpButton", "AXComboBox", "AXMenuItem", "AXMenuButton", "AXTab",
                                     "AXSlider", "AXSearchField", "AXDisclosureTriangle", "AXSwitch"]
        let candidates = r.matches.map {
            ElementFind.Candidate(role: $0.role, name: $0.name, extra: "", rect: $0.rect, ref: $0.ref,
                                  interactive: controls.contains($0.role))
        }
        return ElementFind.rank(query, candidates, limit: limit)
    }

    /// DOM: candidates are collected in the page without refs (a find must
    /// not fill the ref table with thousands of entries); only the winners
    /// get refs, in a second call on the same tab.
    static func dom(query: String, port: UInt16, match: String?, viaExtension: Bool,
                    under: String?) async throws -> [ElementFind.Hit] {
        try await AgentDOM.withTimeout(15) {
            try await AgentDOM.withConn(port: port, match: match, viaExtension: viaExtension) { conn in
                let root = under.map { "R.get(\(AgentDOM.jsLiteral($0)))" } ?? "document"
                let collect = """
                (function(){var R=\(DOMRefs.tableJS);var root=\(root);if(!root)return JSON.stringify({missing:true});\
                var sel='a[href],button,input:not([type=hidden]),select,textarea,[role],[contenteditable=""],\
                [contenteditable=true],[onclick],summary,label,h1,h2,h3,h4,img[alt],[aria-label],[title],\
                [tabindex]:not([tabindex="-1"]),li,td,th,option';var nodes=root.querySelectorAll(sel),keep=[],out=[];\
                for(var i=0;i<nodes.length&&out.length<3000;i++){var e=nodes[i],r=e.getBoundingClientRect();\
                if(r.width<2||r.height<2)continue;var st=getComputedStyle(e);\
                if(st.visibility==='hidden'||st.display==='none')continue;var tag=e.tagName.toLowerCase();\
                var role=e.getAttribute('role')||tag,field=tag==='input'||tag==='textarea'||tag==='select';\
                var nm=(e.getAttribute('aria-label')||(field?'':e.innerText)||e.getAttribute('alt')||e.getAttribute('title')||'');\
                if(!nm&&e.labels&&e.labels[0])nm=e.labels[0].innerText;nm=nm.replace(/\\s+/g,' ').trim().slice(0,160);\
                var ex=[e.placeholder||'',e.getAttribute('name')||'',e.id||'',field&&tag!=='select'?'':''].join(' ').trim();\
                if(!nm&&!ex)continue;var inter=/^(a|button|input|select|textarea|summary|option)$/.test(tag)\
                ||e.hasAttribute('onclick')||/button|link|tab|menuitem|checkbox|radio|switch|textbox|combobox|option/.test(e.getAttribute('role')||'');\
                keep.push(e);out.push({role:role,name:nm,extra:ex,x:r.left,y:r.top,w:r.width,h:r.height,i:inter});}\
                window.__floatyFind=keep;return JSON.stringify({c:out,sx:screenX,sy:screenY,oh:outerHeight,ih:innerHeight});})()
                """
                guard let json = try await AgentDOM.rawEval(conn, expression: collect) as? String,
                      let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    throw AgentDOM.DOMError.cdpError("find: could not read the page")
                }
                if let u = under, m["missing"] != nil { throw AgentDOM.DOMError.cdpError(DOMRefs.staleMessage(u)) }
                func d(_ dict: [String: Any], _ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
                let sx = d(m, "sx"), sy = d(m, "sy") + d(m, "oh") - d(m, "ih")
                let rows = (m["c"] as? [[String: Any]]) ?? []
                // The candidate's index rides in `ref` until the winners get real refs.
                var candidates: [ElementFind.Candidate] = []
                candidates.reserveCapacity(rows.count)
                for (i, e) in rows.enumerated() {
                    let x: Double = sx + d(e, "x"), y: Double = sy + d(e, "y")
                    let rect = CGRect(x: x, y: y, width: d(e, "w"), height: d(e, "h"))
                    let role: String = (e["role"] as? String) ?? ""
                    let name: String = (e["name"] as? String) ?? ""
                    let extra: String = (e["extra"] as? String) ?? ""
                    let interactive: Bool = (e["i"] as? NSNumber)?.boolValue ?? false
                    candidates.append(ElementFind.Candidate(role: role, name: name, extra: extra, rect: rect,
                                                            ref: String(i), interactive: interactive))
                }
                let hits = ElementFind.rank(query, candidates, limit: limit)
                let indices = hits.compactMap { Int($0.candidate.ref) }
                let assign = """
                (function(ix){var R=\(DOMRefs.tableJS),k=window.__floatyFind||[];window.__floatyFind=null;\
                return JSON.stringify(ix.map(function(i){return k[i]?R.of(k[i]):'';}));})(\(indices))
                """
                let refs = (try? await AgentDOM.rawEval(conn, expression: assign) as? String)
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
                var out: [ElementFind.Hit] = []
                for (i, h) in hits.enumerated() {
                    let c = h.candidate
                    let ref: String = i < refs.count ? refs[i] : ""
                    out.append(ElementFind.Hit(candidate: ElementFind.Candidate(
                        role: c.role, name: c.name, extra: c.extra, rect: c.rect,
                        ref: ref, interactive: c.interactive), score: h.score))
                }
                return out
            }
        }
    }
}
