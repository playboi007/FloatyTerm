import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let port = UInt16(CommandLine.arguments[1])!
let pageURL = CommandLine.arguments[2]
var fails = 0
func check(_ c: Bool, _ m: String) { if !c { fails += 1; print("FAIL:", m) } else { print("ok:", m) } }
func js(_ e: String) async -> Any? {
  guard let s = try? await AgentDOM.runJavaScript(expression: e, port: port, match: "p3") else { return nil }
  return try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)
}
func run(_ steps: [[String: Any]]) async -> [String: Any] { await AgentCDPInput.run(steps: steps, port: port, match: "p3", viaExtension: false) }
let sem = DispatchSemaphore(value: 0)
Task {
  // A dialog left open (an earlier run): every verb must say so at once, not hang.
  let t0 = Date()
  let pre = await js("1")
  let st0 = try! await AgentDOM.dialog(accept: nil, promptText: nil, port: port, match: "p3", viaExtension: false)
  print("  pre-run dialog state:", st0, "eval:", pre ?? "nil", "after", Int(Date().timeIntervalSince(t0) * 1000), "ms")
  if st0["dialog"] is [String: Any] {
    let rl = try! await AgentDOM.dialog(accept: nil, promptText: nil, reload: true, port: port, match: "p3", viaExtension: false)
    check(rl["reloaded"] as? Bool == true, "dialog --reload recovers an orphaned dialog")
    try? await Task.sleep(nanoseconds: 500_000_000)
    check((await js("1+1") as? Int) == 2, "page answers after the reload")
  }
  // navigate: scheme refusal + wait for the new document
  if case .failure(let e) = AgentDOM.navigableURL("javascript:alert(1)") { check(e.localizedDescription.contains("refused"), "javascript: refused") } else { check(false, "javascript: refused") }
  if case .success(let u) = AgentDOM.navigableURL("localhost:3000/x") { check(u == "http://localhost:3000/x", "localhost:3000 → http (\(u))") }
  if case .success(let u) = AgentDOM.navigableURL("example.com") { check(u == "https://example.com", "schemeless → https") }
  let nav = try! await AgentDOM.navigate(url: "\(pageURL)?n=\(Int.random(in: 1...99999))", port: port, match: "p3")
  check(nav["ok"] as? Bool == true && (nav["title"] as? String) == "p3" && nav["committed"] == nil, "navigate waits for the new page (\(nav["waited_ms"] ?? "?") ms)")
  check((await js("document.readyState") as? String) != "loading", "page parsed when navigate returned")
  // refs from query-dom
  let m = try! await AgentDOM.screenRects(selector: "#add", port: port, match: "p3")
  let ref = m[0].ref
  check(ref.hasPrefix("ref_"), "query-dom gives a ref (\(ref))")
  let m2 = try! await AgentDOM.screenRects(selector: "#add", port: port, match: "p3")
  check(m2[0].ref == ref, "same element → same ref")
  // click by ref, hover-first
  let r1 = await run([["click": ref]])
  check(r1["ok"] as? Bool == true, "input click by ref (\(r1["error"] ?? ""))")
  check((await js("window.__added") as? Int) == 1, "the ref click landed")
  let log1 = await js("JSON.stringify(window.__log.splice(0))") as? String ?? ""
  let mm = log1.range(of: "mousemove"), pd = log1.range(of: "pointerdown")
  check(mm != nil && pd != nil && mm!.lowerBound < pd!.lowerBound, "a mousemove comes before the press")
  // hover target
  _ = await run([["move": "#menu"]]); check((await js("window.__hovered") as? Int) == 1, "hover reaches onmouseover")
  // scroll into view
  let r2 = await run([["click": "#far"]])
  let far = await js("window.__far") as? Int
  check(r2["scrolled"] as? Bool == true && far == 1, "off-screen target scrolled into view and clicked (\(r2["error"] ?? ""))")
  _ = await js("scrollTo(0,0)")
  // fill: text, select, clear
  let r3 = await run([["fill": "#email", "value": "new@shop.ch"], ["fill": "#size", "value": "Medium"]])
  check(r3["ok"] as? Bool == true, "fill ok (\(r3["error"] ?? ""))")
  check((await js("document.getElementById('email').value") as? String) == "new@shop.ch", "fill replaced the value")
  check((await js("document.getElementById('size').value") as? String) == "m", "fill set the <select> by option text")
  let log3 = await js("JSON.stringify(window.__log.splice(0).filter(e=>e.type==='input'))") as? String ?? ""
  check(log3.contains("\"tr\":true"), "fill's input event is trusted")
  _ = await run([["fill": "#email", "value": ""]]); check((await js("document.getElementById('email').value") as? String) == "", "fill with empty value clears")
  // key chord + sequence in input
  _ = await run([["click": "#email"], ["type": "abc"], ["key": "cmd+a"], ["key": "Backspace"]])
  check((await js("document.getElementById('email').value") as? String) == "", "cmd+a then Backspace cleared the field")
  // stale ref
  _ = await js("document.getElementById('add').remove()")
  let r4 = await run([["click": ref]])
  check((r4["error"] as? String)?.contains("stale") == true, "removed element → stale ref error")
  // find (DOM)
  let hits = try! await AgentFind.dom(query: "email field", port: port, match: "p3", viaExtension: false, under: nil)
  check(hits.first?.candidate.name.lowercased().contains("email") == true || hits.first?.candidate.role == "input", "find 'email field' → the email input (\(hits.prefix(3).map { "\($0.candidate.role):\($0.candidate.name)" }))")
  check(hits.first.map { !$0.candidate.ref.isEmpty } == true, "find hit has a ref")
  let refCount = await js("window.__floatyRefs.m.size") as? Int ?? -1
  check(refCount < 20, "find assigned refs only to its winners (table size \(refCount))")
  // som --under
  let sec = try! await AgentDOM.screenRects(selector: "#sec", port: port, match: "p3")[0].ref
  let som = try! await AgentDOM.setOfMarks(port: port, match: "p3", includeImage: false, under: sec)
  check(som.marks.map(\.name) == ["Inner one", "Inner two"], "som --under limits to the subtree (\(som.marks.map(\.name)))")
  check(som.marks.allSatisfy { $0.ref.hasPrefix("ref_") }, "som marks carry refs")
  // dialogs (direct port): default policy dismisses in-session and reports
  let r5 = await AgentDOM.withDialogPolicy([:]) { await run([["click": "#al"]]) }
  let dl = r5["dialogs"] as? [[String: Any]] ?? []
  check(r5["ok"] as? Bool == true && dl.first?["message"] as? String == "Saved!" && dl.first?["answered"] as? String == "dismissed",
        "alert during input is dismissed in-session and reported (\(r5["dialogs"] ?? r5["error"] ?? ""))")
  check((await js("2+2") as? Int) == 4, "page answers after the auto-dismiss")
  // stop policy: error with the dialog's text, then reload recovers
  let r6 = await AgentDOM.withDialogPolicy(["on_dialog": "stop"]) { await run([["click": "#al"]]) }
  check((r6["error"] as? String)?.contains("Saved!") == true, "--on-dialog stop → error with the dialog's text")
  let t1 = Date()
  let blocked = await AgentDOM.withDialogPolicy([:]) { () -> [String: Any] in
    do { _ = try await AgentDOM.runJavaScript(expression: "1", port: port, match: "p3"); return ["ok": true] }
    catch { return ["error": error.localizedDescription] }
  }
  check((blocked["error"] as? String)?.contains("--reload") == true && Date().timeIntervalSince(t1) < 6,
        "next call on the blocked page fails fast with the --reload hint (\(Int(Date().timeIntervalSince(t1) * 1000)) ms)")
  let rl2 = try! await AgentDOM.dialog(accept: nil, promptText: nil, reload: true, port: port, match: "p3", viaExtension: false)
  check(rl2["reloaded"] as? Bool == true, "dialog --reload clears it")
  try? await Task.sleep(nanoseconds: 500_000_000)
  check((await js("3+3") as? Int) == 6, "page answers after the reload")
  print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
  sem.signal()
}
sem.wait()
