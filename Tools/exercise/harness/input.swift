import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let port = UInt16(CommandLine.arguments[1])!
func j(_ s: String) -> [[String: Any]] { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [[String: Any]] }
func log() async -> [[String: Any]] {
    let s = try! await AgentDOM.runJavaScript(expression: "JSON.stringify(window.__log.splice(0))", port: port, match: "fltest")!
    let inner = try! JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) as! String
    return try! JSONSerialization.jsonObject(with: Data(inner.utf8)) as! [[String: Any]]
}
var fails = 0
func check(_ c: Bool, _ m: String) { if !c { fails += 1; print("FAIL:", m) } else { print("ok:", m) } }
let sem = DispatchSemaphore(value: 0)
Task {
  _ = try? await AgentDOM.runJavaScript(expression: "location.reload()", port: port, match: "fltest")
  try? await Task.sleep(nanoseconds: 800_000_000)
  _ = await log()
  // A. functional
  let r = await AgentCDPInput.run(steps: j(##"""
  [{"move":".w[data-midi='62']"},
   {"click":".w[data-midi='60']"},
   {"click":".b[data-midi='61']"},
   {"click":".w[data-midi='64']","modifiers":["shift"]},
   {"click":".w[data-midi='62']","count":2},
   {"click":".w[data-midi='62']","button":"right"},
   {"click":"#ta"},
   {"key":"0","hold":100},
   {"wait":120},{"type":"Hi!"},{"text":" ok"},
   {"wheel":"#sc","dy":300},
   {"drag":{"from":"#drag","to":[200,400],"steps":8,"duration":160}},
   {"wait":50},{"click":{"screen":[9999,9999]}}]
  """##), port: port, match: "fltest", viaExtension: false)
  print("reply A:", r)
  check((r["error"] as? String)?.contains("outside the page") == true, "screen point outside viewport refused before sending anything")
  check(await log().isEmpty, "nothing sent when validation fails")
  let steps = j(##"""
  [{"move":".w[data-midi='62']"},
   {"click":".w[data-midi='60']"},
   {"click":".b[data-midi='61']"},
   {"click":".w[data-midi='64']","modifiers":["shift"]},
   {"click":".w[data-midi='62']","count":2},
   {"click":".w[data-midi='62']","button":"right"},
   {"click":"#ta"},
   {"key":"0","hold":100},
   {"wait":120},{"type":"Hi!"},{"text":" ok"},
   {"wheel":"#sc","dy":300},
   {"drag":{"from":"#drag","to":[200,400],"steps":8,"duration":160}}]
  """##)
  let r2 = await AgentCDPInput.run(steps: steps, port: port, match: "fltest", viaExtension: false)
  print("reply A2:", r2)
  try? await Task.sleep(nanoseconds: 300_000_000)
  let L = await log()
  func ev(_ t: String) -> [[String: Any]] { L.filter { $0["type"] as? String == t } }
  check(L.allSatisfy { $0["tr"] as? Bool == true }, "every event isTrusted (\(L.count) events)")
  check(ev("mouseover").contains { $0["midi"] as? String == "62" }, "hover reached key 62")
  let downs = ev("pointerdown").compactMap { $0["midi"] as? String }
  check(downs.prefix(3) == ["60", "61", "64"], "pointerdown order 60,61(black),64 (got \(downs))")
  check(ev("pointerdown").contains { $0["midi"] as? String == "64" && $0["sh"] as? Bool == true }, "shift-click")
  check(ev("dblclick").count == 1, "one dblclick")
  check(ev("contextmenu").count == 1, "right click → contextmenu")
  let kd = ev("keydown").filter { $0["key"] as? String == "0" }.first, ku = ev("keyup").filter { $0["key"] as? String == "0" }.first
  if let kd, let ku { let held = (ku["t"] as! Double) - (kd["t"] as! Double); check(abs(held - 100) < 15, "key 0 held ~100ms (\(Int(held)))") } else { check(false, "key 0 down/up") }
  check(ev("keydown").contains { $0["key"] as? String == "!" && $0["code"] as? String == "Digit1" }, "! = shift+Digit1")
  check((ev("input").last?["v"] as? String) == "0Hi! ok", "textarea value '0Hi! ok' (got \(ev("input").last?["v"] ?? "nil"))")
  check((ev("scroll").last?["top"] as? Double ?? 0) > 0, "wheel scrolled the div")
  check(ev("pointerup").last?["id"] as? String == "drag" && (ev("pointerup").last?["y"] as? String) == "385px", "pointer drag moved the box (\(ev("pointerup").last ?? [:]))")
  // B. timing: 24 notes, 100 ms apart, plus 3-key chords
  var s2: [[String: Any]] = []
  for i in 0..<24 { s2.append(["t": i * 100, "click": i % 2 == 0 ? ".w[data-midi='60']" : ".b[data-midi='63']", "hold": 60]) }
  for i in 0..<4 { for k in ["a","s","d"] { s2.append(["t": 2500 + i * 200, "key": k, "hold": 150]) } }
  let r3 = await AgentCDPInput.run(steps: s2, port: port, match: "fltest", viaExtension: false)
  print("reply B:", r3)
  let L2 = await log()
  let pd = L2.filter { $0["type"] as? String == "pointerdown" }.map { $0["t"] as! Double }
  let gaps = zip(pd.dropFirst(), pd).map { $0 - $1 }
  let err = gaps.map { abs($0 - 100) }.sorted()
  print(String(format: "page-side note gaps: n=%d median err %.2f ms, p95 %.2f, max %.2f", gaps.count, err[err.count/2], err[Int(Double(err.count)*0.95)], err.last!))
  check(pd.count == 24, "24 notes landed")
  check(err.last! < 15, "note spacing within 15 ms")
  let chords = L2.filter { $0["type"] as? String == "keydown" }.map { $0["t"] as! Double }
  var spread: [Double] = []
  for i in 0..<4 { let c = chords[(i*3)..<(i*3+3)]; spread.append(c.max()! - c.min()!) }
  print("chord spread ms:", spread.map { String(format: "%.2f", $0) })
  check(spread.max()! < 10, "3-key chord lands within 10 ms")
  let keyups = L2.filter { $0["type"] as? String == "keyup" }.count
  check(keyups == 12, "every chord key released (\(keyups))")
  print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
  sem.signal()
}
sem.wait()
