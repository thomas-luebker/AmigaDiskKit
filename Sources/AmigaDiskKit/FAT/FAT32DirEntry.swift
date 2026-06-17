import Foundation

// MARK: - FAT32 attribute constants

enum FAT32Attr {
    static let readOnly:  UInt8 = 0x01
    static let hidden:    UInt8 = 0x02
    static let system:    UInt8 = 0x04
    static let volumeID:  UInt8 = 0x08
    static let directory: UInt8 = 0x10
    static let archive:   UInt8 = 0x20
    static let lfn:       UInt8 = 0x0F   // all four low bits set = LFN sub-entry
}

// MARK: - FAT32Entry (public, parsed)

/// A parsed FAT32 directory entry (file or subdirectory).
public struct FAT32Entry {
    public let name: String          // full name (LFN if available, else decoded 8.3)
    public let isDirectory: Bool
    public let firstCluster: UInt32  // 0 for empty files; rootCluster for directories
    public let fileSize: UInt32      // 0 for directories
    public let attributes: UInt8
    public let writeDate: UInt16     // FAT date encoding
    public let writeTime: UInt16     // FAT time encoding

    var isDot: Bool { name == "." || name == ".." }
}

// MARK: - Parsing

extension FAT32Entry {

    /// Parse all valid (non-deleted, non-volume-label) entries from a flat directory data buffer.
    static func parseDirectory(_ data: Data) -> [FAT32Entry] {
        var results: [FAT32Entry] = []
        var pendingLFN: [(seq: Int, chars: String)] = []
        let count = data.count / 32

        for i in 0 ..< count {
            let base = data.startIndex + i * 32
            let first = data[base]

            if first == 0x00 { break }         // end-of-directory sentinel
            if first == 0xE5 {                 // deleted entry
                pendingLFN.removeAll()
                continue
            }

            let attr = data[base + 11]

            if attr == FAT32Attr.lfn {         // LFN sub-entry
                pendingLFN.append((seq: Int(first & 0x3F), chars: lfnCharsAt(data, base: base)))
                continue
            }

            // Volume label: skip (don't expose to callers)
            if attr & FAT32Attr.volumeID != 0 && attr & FAT32Attr.directory == 0 {
                pendingLFN.removeAll()
                continue
            }

            let longName = pendingLFN.isEmpty
                ? decodeSFNAt(data, base: base)
                : pendingLFN.sorted { $0.seq < $1.seq }.map(\.chars).joined()
            pendingLFN.removeAll()

            let clusterHigh = UInt32(data[base + 20]) | (UInt32(data[base + 21]) << 8)
            let clusterLow  = UInt32(data[base + 26]) | (UInt32(data[base + 27]) << 8)
            let cluster = (clusterHigh << 16) | clusterLow

            results.append(FAT32Entry(
                name: longName,
                isDirectory: attr & FAT32Attr.directory != 0,
                firstCluster: cluster,
                fileSize: Data(data[base ..< base + 32]).readLE32(at: 28),
                attributes: attr,
                writeDate: Data(data[base ..< base + 32]).readLE16(at: 24),
                writeTime: Data(data[base ..< base + 32]).readLE16(at: 22)
            ))
        }
        return results
    }

    // MARK: - Internal parse helpers (package-internal for use by FAT32Volume)

    // Called by FAT32Volume — must stay internal (not private)
    static func decodeSFNAt(_ data: Data, base: Data.Index) -> String {
        var nameBytes = Array(data[base ..< base + 8])
        let extBytes  = Array(data[base + 8 ..< base + 11])
        if nameBytes[0] == 0x05 { nameBytes[0] = 0xE5 }  // Kanji compat
        let name = String(bytes: nameBytes, encoding: .isoLatin1)?
            .trimmingCharacters(in: .init(charactersIn: " ")) ?? ""
        let ext  = String(bytes: extBytes,  encoding: .isoLatin1)?
            .trimmingCharacters(in: .init(charactersIn: " ")) ?? ""
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    static func lfnCharsAt(_ data: Data, base: Data.Index) -> String {
        let offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        var chars: [Character] = []
        for off in offsets {
            let lo = data[base + off]
            let hi = data[base + off + 1]
            let cp = UInt16(lo) | (UInt16(hi) << 8)
            if cp == 0x0000 || cp == 0xFFFF { break }
            if let scalar = Unicode.Scalar(cp) { chars.append(Character(scalar)) }
        }
        return String(chars)
    }
}

// MARK: - Serialization

extension FAT32Entry {

    /// Build the on-disk byte sequence for a new directory entry.
    ///
    /// Returns an array of 32-byte `Data` blocks: zero or more LFN sub-entries
    /// (in on-disk order, highest seq first) followed by one SFN entry.
    static func serialize(
        name: String,
        attributes: UInt8,
        firstCluster: UInt32,
        fileSize: UInt32,
        date: UInt16 = 0x4A21,   // 2017-01-01 as a reasonable static default
        time: UInt16 = 0x0000
    ) -> [Data] {
        // Dot entries never need LFN
        if name == "." || name == ".." {
            return [sfnBlock(bytes: dotSFNBytes(name), attributes: attributes,
                             firstCluster: firstCluster, fileSize: 0, date: date, time: time)]
        }

        let (base, ext) = split83(name)
        let sfn = makeSFNBytes(base: base, ext: ext)
        let csum = lfnChecksum(sfn)

        var blocks: [Data] = []

        // Write LFN whenever the name differs from its uppercase SFN form (including mixed-case)
        let sfnFull = ext.isEmpty ? base : "\(base).\(ext)"
        if name != sfnFull {
            blocks += lfnBlocks(name: name, checksum: csum)
        }

        blocks.append(sfnBlock(bytes: sfn, attributes: attributes,
                                firstCluster: firstCluster, fileSize: fileSize,
                                date: date, time: time))
        return blocks
    }

    // MARK: - SFN helpers

    private static func split83(_ name: String) -> (base: String, ext: String) {
        let upper = name.uppercased()
        if let dot = upper.lastIndex(of: "."), dot != upper.startIndex {
            return (
                sanitize83(String(upper[upper.startIndex ..< dot]), maxLen: 8),
                sanitize83(String(upper[upper.index(after: dot)...]), maxLen: 3)
            )
        }
        return (sanitize83(upper, maxLen: 8), "")
    }

    private static let sfnValid: CharacterSet = {
        var cs = CharacterSet.uppercaseLetters
        cs.formUnion(CharacterSet.decimalDigits)
        cs.insert(charactersIn: "!#$%&'()-@^_`{}~")
        return cs
    }()

    private static func sanitize83(_ s: String, maxLen: Int) -> String {
        String(s.unicodeScalars.filter { sfnValid.contains($0) }.map { String($0) }.joined().prefix(maxLen))
    }

    private static func makeSFNBytes(base: String, ext: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x20, count: 11)
        for (i, b) in base.utf8.prefix(8).enumerated() { bytes[i]     = b }
        for (i, b) in ext.utf8.prefix(3).enumerated()  { bytes[8 + i] = b }
        return bytes
    }

    private static func dotSFNBytes(_ name: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x20, count: 11)
        for (i, b) in name.utf8.enumerated() { bytes[i] = b }
        return bytes
    }

    static func lfnChecksum(_ sfn: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for b in sfn {
            sum = ((sum & 1) != 0 ? 0x80 : 0) &+ (sum >> 1) &+ b
        }
        return sum
    }

    private static func sfnBlock(bytes: [UInt8], attributes: UInt8, firstCluster: UInt32,
                                  fileSize: UInt32, date: UInt16, time: UInt16) -> Data {
        var d = Data(count: 32)
        for (i, b) in bytes.enumerated() { d[i] = b }
        d[11] = attributes
        d[20] = UInt8((firstCluster >> 16) & 0xFF)
        d[21] = UInt8((firstCluster >> 24) & 0xFF)
        d[26] = UInt8( firstCluster        & 0xFF)
        d[27] = UInt8((firstCluster >>  8) & 0xFF)
        d[28] = UInt8( fileSize        & 0xFF)
        d[29] = UInt8((fileSize >>  8) & 0xFF)
        d[30] = UInt8((fileSize >> 16) & 0xFF)
        d[31] = UInt8((fileSize >> 24) & 0xFF)
        d[22] = UInt8( time        & 0xFF)
        d[23] = UInt8((time >>  8) & 0xFF)
        d[24] = UInt8( date        & 0xFF)
        d[25] = UInt8((date >>  8) & 0xFF)
        return d
    }

    // MARK: - LFN helpers

    private static func lfnBlocks(name: String, checksum: UInt8) -> [Data] {
        let scalars = Array(name.unicodeScalars)
        let groupCount = (scalars.count + 12) / 13   // ceil(n/13)
        var entries: [Data] = []

        for g in 0 ..< groupCount {
            // g=0 is farthest from SFN (highest seq, 0x40 bit set); g=N-1 is closest (seq=1)
            let seq = groupCount - g
            let isLast = (g == 0)  // "last" in LFN spec = highest seq = farthest from SFN
            var d = Data(count: 32)
            d[0]  = UInt8(seq) | (isLast ? 0x40 : 0x00)
            d[11] = FAT32Attr.lfn
            d[13] = checksum

            let start = (seq - 1) * 13
            let chars: [UInt16] = (0 ..< 13).map { i in
                let idx = start + i
                if idx < scalars.count  { return UInt16(scalars[idx].value) }
                if idx == scalars.count { return 0x0000 }
                return 0xFFFF
            }

            let offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
            for (i, off) in offsets.enumerated() {
                d[off]     = UInt8(chars[i] & 0xFF)
                d[off + 1] = UInt8(chars[i] >> 8)
            }
            entries.append(d)
        }
        return entries   // on-disk order: highest seq first (farthest from SFN)
    }
}
