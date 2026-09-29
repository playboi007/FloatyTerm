import Foundation

/// The chat tab's line-oriented runner boundary. Each implementation owns its
/// process and speaks the same page ingress protocol.
protocol AgentSidecar: AnyObject {
    var onLines: (([String]) -> Void)? { get set }
    var onExit: ((Int32, String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start(cwd: String, resume: String?, fork: Bool, permissionMode: String?,
               model: String?, effort: String?, thinking: Bool?) throws
    func send(_ message: [String: Any])
    func stop()
}

extension ClaudeSidecar: AgentSidecar {}

enum ChatAgent: String {
    case claude, codex

    func runner() -> any AgentSidecar {
        switch self {
        case .claude: ClaudeSidecar()
        case .codex: CodexSidecar()
        }
    }
}
