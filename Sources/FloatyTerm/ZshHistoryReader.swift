import Foundation

/// Reads and parses `~/.zsh_history`, returning a de-duplicated list of recent
/// commands, most-recent-first, capped at `limit` unique entries.
///
/// Handles:
///  - Extended history format:  `: <timestamp>:<elapsed>;<command>`
///  - Multi-line commands whose lines end with a backslash continuation
///  - Lenient encoding: tries UTF-8, falls back to ISO Latin-1
///  - De-duplication: keeps only the most-recent occurrence of each command
enum ZshHistoryReader {

    static func load(limit: Int = 500) -> [String] {
        let path = NSHomeDirectory() + "/.zsh_history"
        guard let rawData = FileManager.default.contents(atPath: path), !rawData.isEmpty else {
            return []
        }

        // zsh "metafies" history on disk: bytes that clash with its internals
        // (0x83–0x9D and others) are written as 0x83 followed by the byte XOR
        // 0x20. Undo that first, or any command containing multibyte UTF-8
        // (accents, emoji, CJK) decodes as mojibake.
        let data = unmetafy(rawData)

        // Leniently decode: try UTF-8, fall back to ISO Latin-1 (never crashes).
        let raw: String
        if let s = String(data: data, encoding: .utf8) {
            raw = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            raw = s
        } else {
            // Last resort: strip non-ASCII bytes one by one.
            let cleaned = data.filter { $0 < 0x80 || ($0 >= 0xA0) }
            raw = String(data: Data(cleaned), encoding: .isoLatin1) ?? ""
        }

        // Split into logical lines, joining continuation lines (trailing `\`).
        let physicalLines = raw.components(separatedBy: "\n")
        var logicalLines: [String] = []
        var current = ""

        for line in physicalLines {
            if line.hasSuffix("\\") {
                // Strip the trailing backslash and append to the in-progress line.
                let trimmed = String(line.dropLast())
                current += (current.isEmpty ? trimmed : "\n" + trimmed)
            } else {
                current += (current.isEmpty ? line : "\n" + line)
                if !current.isEmpty {
                    logicalLines.append(current)
                }
                current = ""
            }
        }
        // Flush any unterminated continuation at end-of-file.
        if !current.isEmpty { logicalLines.append(current) }

        // Strip the extended history prefix `: <digits>:<digits>;` if present.
        // Pattern: literal colon, space, digits, colon, digits, semicolon.
        // We use NSRegularExpression to avoid Swift regex literal parser edge
        // cases with leading colons.
        let extendedPrefixRegex = try? NSRegularExpression(
            pattern: #"^: \d+:\d+;"#, options: [])
        var commands: [String] = []
        for rawLine in logicalLines {
            let cmd: String
            if let regex = extendedPrefixRegex {
                let nsStr = rawLine as NSString
                let fullRange = NSRange(location: 0, length: nsStr.length)
                if let match = regex.firstMatch(in: rawLine, options: [], range: fullRange) {
                    let afterPrefix = match.range.upperBound
                    cmd = nsStr.substring(from: afterPrefix)
                } else {
                    cmd = rawLine
                }
            } else {
                cmd = rawLine
            }
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                commands.append(trimmed)
            }
        }

        // De-duplicate: scan from most-recent, keep first occurrence (most recent).
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(limit)
        for cmd in commands.reversed() {
            guard seen.insert(cmd).inserted else { continue }
            result.append(cmd)
            if result.count >= limit { break }
        }
        // `result` is already most-recent-first because we reversed before de-dup.
        return result
    }

    /// Reverses zsh's on-disk "metafication": 0x83 marks the next byte as
    /// escaped (real value = byte ^ 0x20).
    private static func unmetafy(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var out = Data(capacity: data.count)
        var escaped = false
        for byte in data {
            if escaped {
                out.append(byte ^ 0x20)
                escaped = false
            } else if byte == 0x83 {
                escaped = true
            } else {
                out.append(byte)
            }
        }
        return out
    }
}
