import Foundation

/// Amiga names are case-insensitive; host file systems may not be.
///
/// Extracting several Amiga volumes into ONE host tree must merge `DEVS` into
/// an existing `Devs` (the OS 3.2 Modules and Storage disks spell their
/// drawers in capitals, Workbench does not). macOS's case-insensitive APFS does
/// that by itself. A case-sensitive host (APFS on iPadOS, most Linux file
/// systems) instead grows a second, separate `DEVS` tree — and the iOS
/// Simulator's Foundation fails `createDirectory` with EIO. So resolve each
/// name against the entries already there first and reuse a match; the first
/// spelling to arrive wins, which is what macOS keeps too.
struct HostNameMerge {
    private let fm = FileManager.default
    /// lowercased name -> name on disk, per host directory already listed
    private var cache: [String: [String: String]] = [:]

    /// The URL to write `name` to inside `dir`: an existing entry whose name
    /// matches case-insensitively, else `dir/name`.
    mutating func child(of dir: URL, named name: String) -> URL {
        let key = dir.standardizedFileURL.path
        if cache[key] == nil {
            var names: [String: String] = [:]
            for existing in (try? fm.contentsOfDirectory(atPath: key)) ?? [] {
                names[existing.lowercased()] = names[existing.lowercased()] ?? existing
            }
            cache[key] = names
        }
        let folded = name.lowercased()
        if let existing = cache[key]?[folded] {
            return dir.appendingPathComponent(existing)
        }
        cache[key]?[folded] = name
        return dir.appendingPathComponent(name)
    }
}

/// Find a path inside a host tree the way AmigaOS would: each component
/// matched without regard to case. An archive may ship `libs/x.library`
/// where an install rule says `Libs/x.library` — macOS's file system finds it
/// either way, a case-sensitive one (iPadOS, Linux) does not.
public enum HostPathResolver {
    /// The existing URL for `relativePath` (components separated by "/")
    /// under `root`, or nil. An exact hit is returned without listing.
    public static func resolve(_ relativePath: String, under root: URL) -> URL? {
        let fm = FileManager.default
        let exact = root.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: exact.path) { return exact }
        var current = root
        for component in relativePath.split(separator: "/").map(String.init) where !component.isEmpty {
            let direct = current.appendingPathComponent(component)
            if fm.fileExists(atPath: direct.path) { current = direct; continue }
            let folded = component.lowercased()
            guard let match = (try? fm.contentsOfDirectory(atPath: current.path))?
                    .first(where: { $0.lowercased() == folded }) else { return nil }
            current = current.appendingPathComponent(match)
        }
        return current
    }
}
