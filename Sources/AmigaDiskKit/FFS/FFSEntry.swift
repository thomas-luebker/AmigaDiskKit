import Foundation

// MARK: - FFSEntry

/// A parsed FFS directory or file-header block.
public struct FFSEntry {
    public enum Kind: Equatable {
        case directory  // ST_USERDIR = 2
        case file       // ST_FILE   = -3
    }

    public let kind: Kind
    public let name: String
    public let fsBlock: UInt32       // own partition-relative FS-block number
    public let parent: UInt32        // parent directory FS-block
    public let hashChain: UInt32     // next entry in same hash bucket (0 = end)
    public let protect: UInt32       // AmigaDOS protection bits
    public let byteSize: UInt32      // file size in bytes (0 for dirs)
    public let comment: String
    public let days: UInt32          // last-modification date (Amiga epoch)
    public let mins: UInt32
    public let ticks: UInt32
    public let highSeq: UInt32       // # data-block ptrs used in this header/ext block
    public let extension_: UInt32    // first file-extension block (0 if none / dir)

    /// Data-block FS-block numbers ordered by block index (0 = first block).
    /// Populated only for files; empty for directories.
    public let dataPtrs: [UInt32]

    /// Full hashtable for this directory, indexed by hash slot.
    /// Each non-zero value is the FS-block of the first chain entry for that slot.
    /// Populated only for directories; empty for files.
    public let hashTable: [UInt32]

    public var isDirectory: Bool { kind == .directory }
    public var isFile: Bool      { kind == .file }
}

// MARK: - Parsing

extension FFSEntry {
    /// Parse an FFS directory or file-header block from raw block data.
    /// Throws on checksum failure or unexpected secondary type.
    /// `longNames` selects the FFS2 LNFS layout (DOS\6/DOS\7): name in the
    /// old comment area (block end − 184), dates at block end − 60.
    static func parse(data: Data, longNames: Bool = false) throws -> FFSEntry {
        let bl = data.count / 4
        guard bl >= 56 else {
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                reason: "FFS block too short (\(data.count) bytes)")
        }
        guard verifyFFSBlockChecksum(data) else {
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                reason: "FFS block checksum mismatch")
        }
        let rawSec = Int32(bitPattern: data.readBE32(at: (bl - 1) * 4))
        let kind: FFSEntry.Kind
        switch rawSec {
        case  2: kind = .directory
        case -3: kind = .file
        default:
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                reason: "unexpected FFS sec_type \(rawSec)")
        }

        let fsBlock  = data.readBE32(at: 1 * 4)
        let highSeq  = data.readBE32(at: 2 * 4)
        // OFS file headers store long[3] = 0 rather than the expected bl-56.
        // Compute ht_size from block size directly (safe for FFS and OFS).
        let htSize   = bl - 56

        let hashTable: [UInt32]
        let dataPtrs:  [UInt32]

        if kind == .directory {
            hashTable = (0 ..< htSize).map { data.readBE32(at: (6 + $0) * 4) }
            dataPtrs  = []
        } else {
            hashTable = []
            // Data ptrs stored reversed: table[htSize-1] = block 0, table[htSize-2] = block 1 …
            let n = Int(highSeq)
            dataPtrs = (0 ..< n).map { i in data.readBE32(at: (6 + htSize - 1 - i) * 4) }
        }

        let protect    = data.readBE32(at: (bl - 48) * 4)
        let byteSize   = data.readBE32(at: (bl - 47) * 4)
        let comment: String
        let name: String
        let days, mins, ticks: UInt32
        if longNames {
            // LNFS: long filename occupies the old comment area; no comment field.
            name    = data.readBSTR(at: (bl - 46) * 4, maxLength: 112)
            comment = ""
            days    = data.readBE32(at: (bl - 15) * 4)
            mins    = data.readBE32(at: (bl - 14) * 4)
            ticks   = data.readBE32(at: (bl - 13) * 4)
        } else {
            comment = data.readBSTR(at: (bl - 46) * 4, maxLength: 80)
            days    = data.readBE32(at: (bl - 23) * 4)
            mins    = data.readBE32(at: (bl - 22) * 4)
            ticks   = data.readBE32(at: (bl - 21) * 4)
            name    = data.readBSTR(at: (bl - 20) * 4, maxLength: 32)
        }
        let hashChain  = data.readBE32(at: (bl -  4) * 4)
        let parent     = data.readBE32(at: (bl -  3) * 4)
        let extension_ = data.readBE32(at: (bl -  2) * 4)

        return FFSEntry(
            kind: kind, name: name,
            fsBlock: fsBlock, parent: parent, hashChain: hashChain,
            protect: protect, byteSize: byteSize, comment: comment,
            days: days, mins: mins, ticks: ticks,
            highSeq: highSeq, extension_: extension_,
            dataPtrs: dataPtrs, hashTable: hashTable
        )
    }
}

// MARK: - FFS hash function

/// Compute the FFS hash slot for a name using the simple ASCII toupper algorithm.
/// Returns a value in `0 ..< htSize`.
public func ffsHashName(_ name: String, htSize: Int) -> Int {
    guard htSize > 0 else { return 0 }
    var hash = UInt32(name.count)
    for scalar in name.unicodeScalars {
        let c = scalar.value
        let upper: UInt32 = (c >= 0x61 && c <= 0x7A) ? c - 0x20 : c
        hash = hash &* 13 &+ upper
    }
    hash &= 0x7FF
    return Int(hash) % htSize
}
