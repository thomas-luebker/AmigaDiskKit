import Foundation

/// MBR partition entry (16 bytes at offsets 0x1BE, 0x1CE, 0x1DE, 0x1EE).
/// Used by PiStorm/Emu68 images: MBR slot 0 = FAT32 boot, slot 1 = RDB slice.
public struct MBRPartitionEntry {
    public let status: UInt8          // 0x80 = bootable, 0x00 = inactive
    public let firstCHSHead: UInt8
    public let firstCHSSector: UInt8
    public let firstCHSCylinder: UInt8
    public let partitionType: UInt8   // 0x0B/0x0C = FAT32, 0xEB = Amiga RDB slice
    public let lastCHSHead: UInt8
    public let lastCHSSector: UInt8
    public let lastCHSCylinder: UInt8
    public let lbaStart: UInt32       // first LBA sector (little-endian)
    public let lbaSectors: UInt32     // sector count (little-endian)

    public var startByte: Int64 { Int64(lbaStart) * 512 }
    public var endByte: Int64 { Int64(lbaStart + lbaSectors) * 512 - 1 }
    public var isBootable: Bool { status == 0x80 }
    public var isEmpty: Bool { partitionType == 0 && lbaStart == 0 && lbaSectors == 0 }

    /// Parse one 16-byte MBR entry from a Data slice starting at `offset`.
    public init(data: Data, at offset: Int) throws {
        guard data.count >= offset + 16 else {
            throw AmigaDiskError.readFailed(offset: Int64(offset), length: 16,
                                            reason: "MBR entry extends past data boundary")
        }
        status           = data.readBE8(at: offset + 0)
        firstCHSHead     = data.readBE8(at: offset + 1)
        firstCHSSector   = data.readBE8(at: offset + 2)
        firstCHSCylinder = data.readBE8(at: offset + 3)
        partitionType    = data.readBE8(at: offset + 4)
        lastCHSHead      = data.readBE8(at: offset + 5)
        lastCHSSector    = data.readBE8(at: offset + 6)
        lastCHSCylinder  = data.readBE8(at: offset + 7)
        lbaStart         = data.readLE32(at: offset + 8)
        lbaSectors       = data.readLE32(at: offset + 12)
    }
}

/// One entry to pass to `MBRPartitionTable.serialize(entries:)`.
public struct MBREntrySpec {
    public let status: UInt8         // 0x80 = bootable, 0x00 = inactive
    public let partitionType: UInt8  // 0x0B/0x0C = FAT32, 0xEB = Amiga RDB slice
    public let lbaStart: UInt32
    public let lbaSectors: UInt32

    public init(status: UInt8, partitionType: UInt8, lbaStart: UInt32, lbaSectors: UInt32) {
        self.status = status
        self.partitionType = partitionType
        self.lbaStart = lbaStart
        self.lbaSectors = lbaSectors
    }
}

/// Master Boot Record (first 512 bytes of a PiStorm image).
/// Signature: bytes 510-511 == 0x55 0xAA.
public struct MBRPartitionTable {
    public static let signature: UInt16 = 0xAA55
    public static let signatureOffset = 510
    public static let partitionTableOffset = 0x1BE
    public static let entryCount = 4

    public let partitions: [MBRPartitionEntry]   // always 4 entries

    public var bootablePartitions: [MBRPartitionEntry] {
        partitions.filter { $0.isBootable }
    }

    /// Serialize up to 4 partition entries into a 512-byte MBR block.
    /// Unused slots are left as 16 zero bytes. The 0x55AA signature is always written.
    /// CHS fields are set to 0 (LBA mode; CHS is meaningless for Amiga/modern drives).
    public static func serialize(entries: [MBREntrySpec]) -> Data {
        precondition(entries.count <= entryCount, "MBR supports at most \(entryCount) entries")
        var block = Data(count: 512)
        block.writeLE16(signature, at: signatureOffset)
        for (i, entry) in entries.enumerated() {
            let offset = partitionTableOffset + i * 16
            block.writeBE8(entry.status,        at: offset + 0)
            // CHS first: 0 (LBA-only mode)
            block.writeBE8(entry.partitionType, at: offset + 4)
            // CHS last: 0 (LBA-only mode)
            block.writeLE32(entry.lbaStart,   at: offset + 8)
            block.writeLE32(entry.lbaSectors, at: offset + 12)
        }
        return block
    }

    /// Parse an MBR from a 512-byte Data buffer.
    /// Throws `invalidMBRSignature` if the 0x55AA boot signature is absent.
    public init(data: Data) throws {
        guard data.count >= 512 else {
            throw AmigaDiskError.readFailed(offset: 0, length: 512,
                                            reason: "data too short for MBR (\(data.count) bytes)")
        }
        // Bytes 510-511 must be 0x55, 0xAA.
        // Reading as LE16: byte510 | (byte511 << 8) = 0x55 | 0xAA00 = 0xAA55.
        let sig = data.readLE16(at: 510)
        guard sig == MBRPartitionTable.signature else {
            throw AmigaDiskError.invalidMBRSignature(found: sig)
        }
        var entries: [MBRPartitionEntry] = []
        for i in 0 ..< MBRPartitionTable.entryCount {
            let offset = MBRPartitionTable.partitionTableOffset + i * 16
            entries.append(try MBRPartitionEntry(data: data, at: offset))
        }
        partitions = entries
    }
}
