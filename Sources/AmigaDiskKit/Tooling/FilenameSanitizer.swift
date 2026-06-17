//
//  FilenameSanitizer.swift
//  AmigaDiskKit
//
//  Host-side filename ASCII sanitization for staged Amiga trees, moved
//  verbatim from amiga-tools' main.swift (the CLI remains a thin shim).
//

import Foundation

public enum FilenameSanitizer {

    public struct Result {
        public let renamed: Int
        public let removed: Int
        /// Per-file log lines in historical CLI format (" -> renamed: …").
        public let log: [String]
    }

    /// NFKD-decompose every path component under `dir`, dropping non-ASCII
    /// scalars; deepest-first so children rename before their parents. When
    /// the ASCII name already exists, the non-ASCII duplicate is removed.
    @discardableResult
    public static func sanitize(dir: String) throws -> Result {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir, isDirectory: true)

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) else {
            throw ToolingError.enumerationFailed(dir)
        }

        var entries: [URL] = []
        for case let url as URL in enumerator {
            entries.append(url)
        }
        // Deepest first: child paths are longer, so sort descending by length
        entries.sort { $0.path.count > $1.path.count }

        var renamed = 0
        var removed = 0
        var log: [String] = []

        for url in entries {
            let name = url.lastPathComponent
            let asciiName = name
                .decomposedStringWithCompatibilityMapping
                .unicodeScalars
                .filter { $0.value < 128 }
                .map { Character($0) }
                .reduce("") { $0 + String($1) }

            guard asciiName != name, !asciiName.isEmpty else { continue }

            let dst = url.deletingLastPathComponent().appendingPathComponent(asciiName)

            if fm.fileExists(atPath: dst.path) {
                do {
                    try fm.removeItem(at: url)
                    log.append("  -> removed duplicate: \(name) (ASCII version \(asciiName) exists)")
                    removed += 1
                } catch {
                    log.append("  -> failed to remove \(name): \(error)")
                }
            } else {
                do {
                    try fm.moveItem(at: url, to: dst)
                    log.append("  -> renamed: \(name) -> \(asciiName)")
                    renamed += 1
                } catch {
                    log.append("  -> failed to rename \(name): \(error)")
                }
            }
        }

        return Result(renamed: renamed, removed: removed, log: log)
    }
}
