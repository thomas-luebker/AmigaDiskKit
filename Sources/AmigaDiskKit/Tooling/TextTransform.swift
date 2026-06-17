//
//  TextTransform.swift
//  AmigaDiskKit
//
//  Text-file transforms used on AmigaDOS scripts and prefs sources, moved
//  verbatim from amiga-tools' main.swift (the CLI remains a thin shim).
//
//  Encoding caveat (historical, preserved for parity): the line-based
//  transforms read UTF-8-first with Latin-1 fallback and write back UTF-8.
//  A pure-Latin-1 input with high-bit bytes therefore comes back re-encoded.
//  The native build engine's AmigaTextFile is the encoding-safe path; these
//  functions exist for byte-exact parity with the historical CLI.
//

import Foundation

public enum TextTransform {

    /// Remove leading UTF-8 BOM (EF BB BF) if present.
    public static func stripBOM(path: String) {
        let url = URL(fileURLWithPath: path)
        guard var data = try? Data(contentsOf: url) else { return }
        guard data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF else { return }
        data = Data(data.dropFirst(3))
        try? data.write(to: url, options: .atomic)
    }

    /// Convert CRLF and lone CR to LF in-place (byte-level; encoding-agnostic).
    public static func normalizeEndings(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let raw = try? Data(contentsOf: url) else { return }
        let bytes = Array(raw)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var changed = false
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D {
                out.append(0x0A)
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 1 }
                changed = true
            } else {
                out.append(bytes[i])
            }
            i += 1
        }
        if changed { try? Data(out).write(to: url, options: .atomic) }
    }

    /// Replace every line whose start matches prefix (case-insensitive,
    /// literal string) with replacement. Replacement may contain embedded
    /// newlines → one matched line → multiple output lines.
    public static func replaceLinePrefix(path: String, prefix: String, replacement: String) {
        guard let content = toolingReadTextFile(path) else { return }
        let pl = prefix.lowercased()
        var changed = false
        let newLines = content.components(separatedBy: "\n").map { line -> String in
            if line.lowercased().hasPrefix(pl) { changed = true; return replacement }
            return line
        }
        if changed {
            try? newLines.joined(separator: "\n").write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }

    /// Insert text before the first line where the regex matches at the start
    /// of the line. Text may contain embedded newlines; it is inserted
    /// verbatim before the matched line.
    public static func insertBeforeLine(path: String, pattern: String, text: String) throws {
        guard let content = toolingReadTextFile(path) else { return }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw ToolingError.invalidPattern(pattern)
        }
        var inserted = false
        var out: [String] = []
        for line in content.components(separatedBy: "\n") {
            if !inserted {
                let r = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, options: [.anchored], range: r) != nil {
                    out.append(contentsOf: text.components(separatedBy: "\n"))
                    inserted = true
                }
            }
            out.append(line)
        }
        if inserted {
            try? out.joined(separator: "\n").write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }

    /// Global in-place regex substitution, line by line (like
    /// `perl -pi -e 's/.../.../'[i]`). Capture group references in replacement:
    /// {1}, {2}, … → translated to $1, $2 for NSRegularExpression. Actual
    /// newlines in replacement are preserved → one matched line can expand to
    /// multiple output lines.
    public static func regexReplace(path: String, pattern: String, replacement: String,
                                    caseInsensitive: Bool) throws {
        guard let content = toolingReadTextFile(path) else { return }
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else {
            throw ToolingError.invalidPattern(pattern)
        }
        var template = replacement
        for n in (1...9).reversed() { template = template.replacingOccurrences(of: "{\(n)}", with: "$\(n)") }
        var changed = false
        var out: [String] = []
        for line in content.components(separatedBy: "\n") {
            let r = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, options: [], range: r) != nil {
                let replaced = regex.stringByReplacingMatches(in: line, options: [], range: r, withTemplate: template)
                if replaced != line { changed = true }
                out.append(replaced)
            } else {
                out.append(line)
            }
        }
        if changed {
            try? out.joined(separator: "\n").write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }
}
