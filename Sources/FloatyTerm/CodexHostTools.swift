import AppKit

/// Executes only the native capabilities advertised by host-tools.mjs.
/// All UI operations run on the main thread through the chat controller.
enum CodexHostTools {
    static func execute(tool: String, arguments: [String: Any], cwd: String,
                        context: [String: Any], openViewer: (URL) -> Bool) throws -> [String: Any] {
        if tool == "floatyterm_get_context" {
            guard arguments.isEmpty else { throw ToolError.invalidArguments }
            return context
        }
        guard ["floatyterm_reveal_path", "floatyterm_open_file"].contains(tool),
              arguments.count == 1, let path = arguments["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.count <= 4096, !path.contains("\0") else { throw ToolError.invalidArguments }
        let workspace = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let url = ((path as NSString).isAbsolutePath ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        guard url.path == workspace.path || url.path.hasPrefix(prefix) else { throw ToolError.outsideWorkspace }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { throw ToolError.missingPath }
        if tool == "floatyterm_reveal_path" {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return ["path": url.path, "action": "reveal_requested"]
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard !directory.boolValue, values.isRegularFile == true,
              let size = values.fileSize, size <= 16 * 1024 * 1024 else { throw ToolError.unsupportedFile }
        guard openViewer(url) else { throw ToolError.unsupportedFile }
        return ["path": url.path, "action": "viewer_opened"]
    }

    enum ToolError: LocalizedError {
        case invalidArguments, outsideWorkspace, missingPath, unsupportedFile
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Invalid host tool or arguments."
            case .outsideWorkspace: "Path is outside this conversation's workspace."
            case .missingPath: "The requested workspace path does not exist."
            case .unsupportedFile: "Only readable Markdown or supported image files up to 16 MiB can open in a FloatyTerm viewer."
            }
        }
    }
}
