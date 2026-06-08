import Foundation

// MARK: - LHA archive reader
// Supports level-0 and level-1 headers.
// Methods: -lh0- (stored), -lhd- (directory), -lh5-, -lh6-, -lh7- (LZH compressed).

public struct LHAMember {
    public let path: String        // relative path of this member (may include subdirectories)
    public let isDirectory: Bool
    public let originalSize: Int
    public let method: String      // e.g. "-lh5-"
    public let compressedSize: Int
    public let crc16: UInt16
    public let dataOffset: Int     // byte offset of compressed data within the archive Data
}

public struct LHAArchive {

    public let members: [LHAMember]
    private let data: Data

    // MARK: - Init

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        members = try LHAArchive.parseMembers(data: data)
    }

    // MARK: - Extract

    public func extract(to hostURL: URL) throws {
        let fm = FileManager.default
        for member in members {
            let dest = hostURL.appendingPathComponent(member.path)
            if member.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let out = try decompressMember(member)
            guard crc16(out) == member.crc16 else {
                throw LHAError.crcMismatch(path: member.path)
            }
            try out.write(to: dest)
        }
    }

    // MARK: - Public per-member extraction (for testing/diagnostics)

    public func extractMember(_ m: LHAMember, to destURL: URL) throws {
        if m.isDirectory { return }
        let out = try decompressMember(m)
        guard crc16(out) == m.crc16 else { throw LHAError.crcMismatch(path: m.path) }
        try out.write(to: destURL)
    }

    // MARK: - Decompression dispatch

    private func decompressMember(_ m: LHAMember) throws -> Data {
        // Use Data(subdata:) to get a zero-based copy — Data slice indices are absolute,
        // which would cause BitReader to crash on out-of-bounds access at index 0.
        let compressed = data.subdata(in: m.dataOffset ..< m.dataOffset + m.compressedSize)
        switch m.method {
        case "-lh0-", "-lzs-":
            return Data(compressed)
        case "-lh5-":
            return try LHDecoder(data: compressed, originalSize: m.originalSize,
                                 dictBits: 13, maxMatch: 256, nc: 510, np: 14).decode()
        case "-lh6-":
            return try LHDecoder(data: compressed, originalSize: m.originalSize,
                                 dictBits: 15, maxMatch: 256, nc: 510, np: 16).decode()
        case "-lh7-":
            return try LHDecoder(data: compressed, originalSize: m.originalSize,
                                 dictBits: 16, maxMatch: 256, nc: 512, np: 17).decode()
        default:
            throw LHAError.unsupportedMethod(m.method)
        }
    }

    // MARK: - Header parsing

    private static func parseMembers(data: Data) throws -> [LHAMember] {
        var members: [LHAMember] = []
        var pos = 0

        while pos < data.count {
            // End of archive: two null bytes (or EOF)
            guard pos + 2 <= data.count else { break }
            if data[pos] == 0 { break }

            // Peek at level byte (offset 20 from start of header)
            guard pos + 22 <= data.count else { break }
            let level = data[pos + 20]

            let member: LHAMember?
            let advance: Int

            switch level {
            case 0:
                (member, advance) = try parseLevel0(data: data, pos: pos)
            case 1:
                (member, advance) = try parseLevel1(data: data, pos: pos)
            case 2:
                (member, advance) = try parseLevel2(data: data, pos: pos)
            default:
                throw LHAError.unsupportedHeaderLevel(level)
            }

            if let m = member { members.append(m) }
            guard advance > 0 else { break }
            pos += advance
        }
        return members
    }

    // MARK: Level 0

    private static func parseLevel0(data: Data, pos: Int) throws -> (LHAMember?, Int) {
        guard pos + 22 <= data.count else { return (nil, 0) }
        let headerSize = Int(data[pos])
        guard headerSize > 0 else { return (nil, 0) }
        let method     = String(bytes: data[(pos+2)..<(pos+7)], encoding: .isoLatin1) ?? ""
        let compSize   = Int(LE32(data, pos + 7))
        let origSize   = Int(LE32(data, pos + 11))
        let nameLen    = Int(data[pos + 21])
        guard pos + 22 + nameLen + 2 <= data.count else { throw LHAError.truncatedHeader }
        let name       = String(bytes: data[(pos+22)..<(pos+22+nameLen)], encoding: .isoLatin1) ?? ""
        let crc        = LE16(data, pos + 22 + nameLen)
        let dataStart  = pos + 2 + headerSize + 2   // skip header (size + body + 2-byte CRC)
        // Level-0 header total = 2 + headerSize + 2  (leading byte + body + trailing CRC field)
        // The "header size" field covers bytes 2..end, so total non-data = 2 + headerSize
        let advance    = (2 + headerSize) + compSize

        guard pos + advance <= data.count else { throw LHAError.truncatedData(path: name) }

        let isDir = method == "-lhd-"
        let cleanName = sanitizePath(name)
        guard !cleanName.isEmpty else { return (nil, advance) }
        let m = LHAMember(path: cleanName, isDirectory: isDir,
                          originalSize: isDir ? 0 : origSize,
                          method: method, compressedSize: compSize,
                          crc16: crc, dataOffset: dataStart)
        return (m, advance)
    }

    // MARK: Level 1

    private static func parseLevel1(data: Data, pos: Int) throws -> (LHAMember?, Int) {
        guard pos + 25 <= data.count else { return (nil, 0) }
        let basicHeaderSize = Int(data[pos])
        guard basicHeaderSize > 0 else { return (nil, 0) }
        let method     = String(bytes: data[(pos+2)..<(pos+7)], encoding: .isoLatin1) ?? ""
        var compSize   = Int(LE32(data, pos + 7))   // will be adjusted for extended headers
        let origSize   = Int(LE32(data, pos + 11))
        let nameLen    = Int(data[pos + 21])
        guard pos + 22 + nameLen + 3 <= data.count else { throw LHAError.truncatedHeader }
        var name       = String(bytes: data[(pos+22)..<(pos+22+nameLen)], encoding: .isoLatin1) ?? ""
        let crc        = LE16(data, pos + 22 + nameLen)
        // Layout: [name][crc16(2)][osid(1)][firstExtHdrSize(2)]
        var extPos     = pos + 22 + nameLen + 2 + 1  // past crc(2) + osid(1)

        guard extPos + 2 <= data.count else { throw LHAError.truncatedHeader }
        var nextSize = Int(LE16(data, extPos))
        extPos += 2

        while nextSize > 0 {
            guard extPos + nextSize <= data.count else { break }
            let extType = data[extPos]
            if extType == 0x02 {
                // Directory path — Amiga LHA level-1 uses type 0x02; path separator = 0xFF
                let dirBytes = data[(extPos+1)..<(extPos + nextSize - 2)]
                var dir = String(bytes: dirBytes, encoding: .isoLatin1) ?? ""
                dir = dir.replacingOccurrences(of: "\u{FF}", with: "/")
                if !dir.hasSuffix("/") { dir += "/" }
                name = dir + name
            }
            compSize -= nextSize   // extended headers come out of the compressed-size field
            extPos   += nextSize - 2
            nextSize  = Int(LE16(data, extPos))
            extPos   += 2
        }

        let dataStart = extPos
        let totalAdvance = dataStart - pos + compSize

        guard pos + totalAdvance <= data.count else { throw LHAError.truncatedData(path: name) }

        let isDir = method == "-lhd-"
        let cleanName = sanitizePath(name)
        guard !cleanName.isEmpty else { return (nil, totalAdvance) }
        let m = LHAMember(path: cleanName, isDirectory: isDir,
                          originalSize: isDir ? 0 : origSize,
                          method: method, compressedSize: compSize,
                          crc16: crc, dataOffset: dataStart)
        return (m, totalAdvance)
    }

    // MARK: Level 2

    private static func parseLevel2(data: Data, pos: Int) throws -> (LHAMember?, Int) {
        // Level 2: fixed 26-byte base header, all sizes LE16/LE32
        guard pos + 26 <= data.count else { return (nil, 0) }
        let totalHeaderSize = Int(LE16(data, pos))
        let method   = String(bytes: data[(pos+2)..<(pos+7)], encoding: .isoLatin1) ?? ""
        let compSize = Int(LE32(data, pos + 7))
        let origSize = Int(LE32(data, pos + 11))
        let crc      = LE16(data, pos + 21)
        // Extended headers start at pos+26
        var extPos   = pos + 26
        var name     = ""
        var nextSize = Int(LE16(data, pos + 24))

        while nextSize > 0 && extPos + nextSize <= data.count {
            let extType = data[extPos + 2]
            switch extType {
            case 0x01:  // filename
                let nameBytes = data[(extPos+3)..<(extPos + nextSize - 2)]
                name = String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            case 0x02:  // directory
                let dirBytes = data[(extPos+3)..<(extPos + nextSize - 2)]
                let dir = (String(bytes: dirBytes, encoding: .isoLatin1) ?? "")
                    .replacingOccurrences(of: "\u{FF}", with: "/")
                name = dir + name
            default: break
            }
            extPos  += nextSize
            nextSize = Int(LE16(data, extPos - 2))
        }

        let dataStart    = pos + totalHeaderSize
        let totalAdvance = totalHeaderSize + compSize

        guard pos + totalAdvance <= data.count else { throw LHAError.truncatedData(path: name) }

        let isDir = method == "-lhd-"
        let cleanName = sanitizePath(name)
        guard !cleanName.isEmpty else { return (nil, totalAdvance) }
        let m = LHAMember(path: cleanName, isDirectory: isDir,
                          originalSize: isDir ? 0 : origSize,
                          method: method, compressedSize: compSize,
                          crc16: crc, dataOffset: dataStart)
        return (m, totalAdvance)
    }

    // MARK: - Helpers

    /// Normalise Amiga/DOS path separators and strip dangerous components.
    private static func sanitizePath(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "/")  // DOS backslash
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
            .joined(separator: "/")
    }

    private static func LE16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[i]) | (UInt16(d[i+1]) << 8)
    }

    private static func LE32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
    }
}

// MARK: - CRC-16 (polynomial 0xA001, initial value 0x0000)

func crc16(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0
    for byte in data {
        crc ^= UInt16(byte)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
        }
    }
    return crc
}

// MARK: - Errors

public enum LHAError: Error, CustomStringConvertible {
    case truncatedHeader
    case truncatedData(path: String)
    case unsupportedMethod(String)
    case unsupportedHeaderLevel(UInt8)
    case crcMismatch(path: String)
    case decompressOverflow
    case huffmanError

    public var description: String {
        switch self {
        case .truncatedHeader:              return "LHA: truncated header"
        case .truncatedData(let p):         return "LHA: truncated data for '\(p)'"
        case .unsupportedMethod(let m):     return "LHA: unsupported method '\(m)'"
        case .unsupportedHeaderLevel(let l):return "LHA: unsupported header level \(l)"
        case .crcMismatch(let p):           return "LHA: CRC mismatch for '\(p)'"
        case .decompressOverflow:           return "LHA: decompressed output exceeded expected size"
        case .huffmanError:                 return "LHA: Huffman decode error"
        }
    }
}
