//
//  ISO9660Image.swift
//  AmigaDiskKit
//
//  Native read-only ISO 9660 reader — the replacement for the engine's
//  hdiutil mounts (extraction plan Phase 4d; iOS has no hdiutil). Reads
//  plain ISO 9660 and prefers a Joliet supplementary descriptor when one
//  exists, matching macOS's cd9660 driver so file names come out exactly
//  as the old mount-based path saw them (the AmigaOS 3.9 CD is Joliet).
//
//  Deliberately scoped to what the build engine's CD media needs:
//  single-extent files, no interleave, no Rock Ridge (macOS prefers
//  Joliet when both exist). Multi-extent files throw loudly.
//

import Foundation

public enum ISO9660Error: Error, Equatable {
    case notAnISO
    case truncated(String)
    case pathNotFound(String)
    case multiExtentUnsupported(String)
}

public final class ISO9660Image {

    public struct Entry {
        public let name: String
        public let isDirectory: Bool
        public let size: Int
        public let extentLBA: Int
        /// Recording date from the directory record, when representable.
        public let modified: Date?
    }

    private let data: Data
    private let rootExtentLBA: Int
    private let rootSize: Int
    /// True when names decode as UCS-2 BE (Joliet SVD chosen).
    private let joliet: Bool

    private static let sectorSize = 2048

    // MARK: - Init: volume descriptors

    public init(url: URL) throws {
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        var pvdRoot: (Int, Int)?
        var svdRoot: (Int, Int)?

        var sector = 16
        while true {
            let off = sector * Self.sectorSize
            guard off + Self.sectorSize <= data.count else { break }
            let type = data[data.startIndex + off]
            let magic = data.subdata(in: (data.startIndex + off + 1)..<(data.startIndex + off + 6))
            guard String(decoding: magic, as: UTF8.self) == "CD001" else {
                if sector == 16 { throw ISO9660Error.notAnISO }
                break
            }
            if type == 255 { break }
            // Root directory record lives at descriptor offset 156 (34 bytes).
            let extent = Self.leU32(data, off + 156 + 2)
            let size = Self.leU32(data, off + 156 + 10)
            if type == 1, pvdRoot == nil {
                pvdRoot = (extent, size)
            } else if type == 2 {
                // Joliet escape sequences at descriptor offset 88: %/@ %/C %/E.
                let esc = data.subdata(in: (data.startIndex + off + 88)..<(data.startIndex + off + 91))
                if esc.count == 3, esc[esc.startIndex] == 0x25, esc[esc.startIndex + 1] == 0x2F,
                   [0x40, 0x43, 0x45].contains(esc[esc.startIndex + 2]) {
                    svdRoot = (extent, size)
                }
            }
            sector += 1
        }

        if let (extent, size) = svdRoot {
            rootExtentLBA = extent
            rootSize = size
            joliet = true
        } else if let (extent, size) = pvdRoot {
            rootExtentLBA = extent
            rootSize = size
            joliet = false
        } else {
            throw ISO9660Error.notAnISO
        }
    }

    // MARK: - Directory parsing

    /// Parse one directory extent into entries ("." / ".." skipped).
    private func parseDirectory(extentLBA: Int, size: Int) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = extentLBA * Self.sectorSize
        let end = offset + size
        guard end <= data.count else { throw ISO9660Error.truncated("directory extent") }

        while offset < end {
            let len = Int(data[data.startIndex + offset])
            if len == 0 {
                // Records never straddle sectors: skip to the next boundary.
                let next = ((offset / Self.sectorSize) + 1) * Self.sectorSize
                if next >= end { break }
                offset = next
                continue
            }
            guard offset + len <= end else { throw ISO9660Error.truncated("directory record") }

            let extent = Self.leU32(data, offset + 2)
            let size = Self.leU32(data, offset + 10)
            let flags = data[data.startIndex + offset + 25]
            let nameLen = Int(data[data.startIndex + offset + 32])
            let nameData = data.subdata(
                in: (data.startIndex + offset + 33)..<(data.startIndex + offset + 33 + nameLen))

            defer { offset += len }

            if flags & 0x80 != 0 {
                throw ISO9660Error.multiExtentUnsupported(decodeName(nameData))
            }
            // Self / parent pseudo-entries.
            if nameLen == 1, nameData.first == 0x00 || nameData.first == 0x01 {
                continue
            }
            let name = decodeName(nameData)
            guard !name.isEmpty else { continue }
            entries.append(Entry(
                name: name,
                isDirectory: flags & 0x02 != 0,
                size: size,
                extentLBA: extent,
                modified: Self.recordingDate(data, offset + 18)))
        }
        return entries
    }

    private func decodeName(_ raw: Data) -> String {
        var name: String
        if joliet {
            // UCS-2 big-endian.
            var scalars: [UInt16] = []
            var i = raw.startIndex
            while i + 1 < raw.endIndex {
                scalars.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
                i += 2
            }
            name = String(decoding: scalars, as: UTF16.self)
        } else {
            // Plain ISO 9660: macOS's cd9660 presents non-ASCII name bytes
            // as '_' (verified against a Latin-1-mastered disc) — match it,
            // the engine's staged trees were built from those names.
            name = String(raw.map { byte in
                (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "_"
            })
        }
        // Strip the ISO version suffix (";1") and a bare trailing dot.
        if let semi = name.lastIndex(of: ";") { name = String(name[..<semi]) }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    // MARK: - Lookup (case-insensitive, like the macOS cd9660 mount)

    public func entry(atPath path: String) throws -> Entry? {
        var current = Entry(name: "", isDirectory: true, size: rootSize,
                            extentLBA: rootExtentLBA, modified: nil)
        for component in path.split(separator: "/").map(String.init) {
            guard current.isDirectory else { return nil }
            let children = try parseDirectory(extentLBA: current.extentLBA, size: current.size)
            guard let match = children.first(where: {
                $0.name.compare(component, options: .caseInsensitive) == .orderedSame
            }) else { return nil }
            current = match
        }
        return current
    }

    public func directoryExists(_ path: String) -> Bool {
        (try? entry(atPath: path))?.isDirectory ?? false
    }

    public func list(_ path: String) throws -> [Entry] {
        guard let dir = try entry(atPath: path), dir.isDirectory else {
            throw ISO9660Error.pathNotFound(path)
        }
        return try parseDirectory(extentLBA: dir.extentLBA, size: dir.size)
    }

    // MARK: - Reading / extraction

    public func readFile(_ entry: Entry) throws -> Data {
        let start = entry.extentLBA * Self.sectorSize
        guard start + entry.size <= data.count else {
            throw ISO9660Error.truncated(entry.name)
        }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.size))
    }

    /// Write `entry`'s bytes to `dest`, overwriting, preserving the ISO
    /// recording date as the host mtime (the mount-based path saw the same).
    public func extractFile(_ entry: Entry, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try readFile(entry).write(to: dest)
        if let date = entry.modified {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: dest.path)
        }
    }

    /// Recursively extract the directory at `path` INTO `dest` (its children
    /// land directly in `dest`), merging with existing content and
    /// overwriting files — `cp -R path/* dest/` semantics.
    public func extractTree(_ path: String, mergingInto dest: URL) throws {
        guard let dir = try entry(atPath: path), dir.isDirectory else {
            throw ISO9660Error.pathNotFound(path)
        }
        try extractChildren(of: dir, into: dest)
    }

    private func extractChildren(of dir: Entry, into dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for child in try parseDirectory(extentLBA: dir.extentLBA, size: dir.size) {
            let target = dest.appendingPathComponent(child.name)
            if child.isDirectory {
                try extractChildren(of: child, into: target)
            } else {
                try extractFile(child, to: target)
            }
        }
    }

    /// Depth-first walk of the whole image. The visitor receives each entry's
    /// full slash-joined path; return values are collected by the caller.
    public func walk(_ visitor: (String, Entry) -> Void) throws {
        func recurse(_ dir: Entry, prefix: String) throws {
            for child in try parseDirectory(extentLBA: dir.extentLBA, size: dir.size) {
                let path = prefix.isEmpty ? child.name : "\(prefix)/\(child.name)"
                visitor(path, child)
                if child.isDirectory {
                    try recurse(child, prefix: path)
                }
            }
        }
        let root = Entry(name: "", isDirectory: true, size: rootSize,
                         extentLBA: rootExtentLBA, modified: nil)
        try recurse(root, prefix: "")
    }

    // MARK: - Helpers

    private static func leU32(_ data: Data, _ offset: Int) -> Int {
        let b = data.startIndex + offset
        return Int(data[b]) | Int(data[b + 1]) << 8 | Int(data[b + 2]) << 16 | Int(data[b + 3]) << 24
    }

    /// 7-byte directory-record date: years-since-1900, month, day, hour,
    /// minute, second, tz in signed 15-minute units.
    private static func recordingDate(_ data: Data, _ offset: Int) -> Date? {
        let b = data.startIndex + offset
        let year = Int(data[b])
        guard year > 0 else { return nil }
        var comps = DateComponents()
        comps.year = 1900 + year
        comps.month = Int(data[b + 1])
        comps.day = Int(data[b + 2])
        comps.hour = Int(data[b + 3])
        comps.minute = Int(data[b + 4])
        comps.second = Int(data[b + 5])
        let tzQuarters = Int(Int8(bitPattern: data[b + 6]))
        comps.timeZone = TimeZone(secondsFromGMT: tzQuarters * 15 * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: comps)
    }
}
