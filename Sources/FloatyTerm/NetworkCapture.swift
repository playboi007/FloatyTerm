import Foundation

extension Notification.Name {
    /// Posted on the main queue when a recording starts or stops. userInfo:
    /// "event" = "start" | "stop", "result" = the action's reply. NOT posted for
    /// a start that rolled back — that session never really existed, and a REC
    /// pill that flashes in and out for it would claim otherwise.
    static let networkRecordingChanged = Notification.Name("FloatyTerm.networkRecordingChanged")
}

/// Start and stop for a whole recording — the session file AND its collectors,
/// as one unit.
///
/// Shared by the relay (`floaty net`) and the on-screen controls, so a Stop
/// button and `floaty net stop` cannot drift apart. The rule both must keep:
/// collectors stop FIRST (the Chrome extension replies only after its final
/// batch has landed), and the file closes after.
enum NetworkCapture {

    /// `--chrome` alone = the active tab; `--chrome gmail` = the first tab whose
    /// url or title contains "gmail".
    struct ChromeTarget {
        let wanted: Bool
        let match: String?

        init(_ raw: Any?) {
            if let s = raw as? String, !s.isEmpty { wanted = true; match = s }
            else if let n = raw as? NSNumber, n.boolValue { wanted = true; match = nil }
            else { wanted = false; match = nil }
        }
    }

    /// Starts a session and attaches every requested collector — all of them,
    /// or none. A recording whose collector never attached is an empty file the
    /// user finds out about an hour later.
    static func start(label: String, maxBody: Int, vmURI: String?, poll: Double,
                      chrome: ChromeTarget) async -> [String: Any] {
        var result = NetworkRecorder.shared.start(label: label, maxBody: maxBody)
        guard result["error"] == nil else { return result }

        func rollback(_ failure: [String: Any]) async -> [String: Any] {
            if (DartVMNetwork.shared.status()["label"] as? String) == label {
                await DartVMNetwork.shared.detach()
            }
            _ = await ChromeNetwork.shared.stop(label: label)
            NetworkRecorder.shared.discard(label: label)
            var failed = failure
            failed["recording"] = false
            return failed
        }

        if let vmURI {
            let attach = await DartVMNetwork.shared.attach(uri: vmURI, label: label, poll: poll)
            if attach["error"] != nil { return await rollback(attach) }
            result["vm_service"] = attach
        }
        if chrome.wanted {
            let attach = await ChromeNetwork.shared.start(label: label, match: chrome.match, maxBody: maxBody)
            if attach["error"] != nil { return await rollback(attach) }
            result["chrome"] = attach
        }
        if vmURI == nil && !chrome.wanted {
            result["collectors"] = "relay ingress only — the Dart package or the injected JS must POST to 127.0.0.1:7777. Pass --vm <uri printed by flutter run> for a Dart app, or --chrome [tab match] for a tab in your live Chrome."
        }
        post("start", result)
        return result
    }

    /// Stops `given`, or the only live recording when nil.
    static func stop(label given: String?) async -> [String: Any] {
        let (target, failure) = liveTarget(given)
        guard let target else { return failure }

        let chromeResult = await ChromeNetwork.shared.stop(label: target)
        var vm: [String: Any]?
        if (DartVMNetwork.shared.status()["label"] as? String) == target {
            vm = await DartVMNetwork.shared.detach()
        }
        var result = NetworkRecorder.shared.stop(label: target)
        guard result["error"] == nil else { return result }

        if let vm { result["vm_service"] = vm }
        if let chromeResult {
            result["chrome"] = chromeResult
            if let early = chromeResult["ended_early"] {
                result["warning"] = "Chrome recording ended early: \(early)"
            }
        }
        if result["warning"] == nil, (result["events"] as? Int) == 0 {
            result["warning"] = "no events captured — did the app or page make any requests while recording? (Dart: debug/profile builds only)"
        }
        post("stop", result)
        return result
    }

    /// The session a command binds to: the given label, else the only live one.
    static func liveTarget(_ given: String?) -> (label: String?, error: [String: Any]) {
        if let given, !given.isEmpty { return (given, [:]) }
        let live = NetworkRecorder.shared.liveLabels()
        if live.count == 1 { return (live[0], [:]) }
        if live.isEmpty {
            return (nil, ["error": "nothing is recording",
                          "hint": "floaty net start --label <label> first"])
        }
        return (nil, ["error": "several recordings — pass --label", "recording": live])
    }

    private static func post(_ event: String, _ result: [String: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .networkRecordingChanged, object: nil,
                                            userInfo: ["event": event, "result": result])
        }
    }
}
