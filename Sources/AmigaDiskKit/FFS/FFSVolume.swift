import Foundation

/// Mounted FFS volume — wraps a partition and provides filesystem operations.
/// All internal offsets are Int64 from the start of the disk image; no UInt32 arithmetic.
public struct FFSVolume {
    public let partition: PartitionBlock
    public let rdb: RigidDiskBlock

    /// Byte offset from image start to the first byte of this partition.
    public var partitionStartOffset: Int64 {
        rdb.byteOffset(forCylinder: partition.lowCyl)
    }

    public let blocksPerCylinder: UInt32
    public let totalBlocks: UInt32
    public let rootBlockOffset: UInt32    // block number relative to partition start
    public let reserved: UInt32           // reserved blocks at start (usually 2)
    public let blockSize: Int             // file system block size (512 or 2048)

    public let dosType: UInt32
    public var useFFS: Bool { dosType & 1 != 0 }
    public var useIntl: Bool { dosType & 2 != 0 }
    public var useDirCache: Bool { dosType & 4 != 0 }

    // Populated after mounting
    public var rootBlock: RootBlock?
    public var volumeName: String { rootBlock?.diskName ?? "" }

    /// Byte offset from image start to a given block number (relative to partition start).
    public func byteOffset(forBlock block: UInt32) -> Int64 {
        partitionStartOffset + Int64(block) * Int64(blockSize)
    }
}

/// FFS root block — the volume root directory.
/// Located at approximately the middle of the partition.
/// Block type = 2 (T_SHORT), secondary type = 1 (ST_ROOT).
public struct RootBlock {
    public static let primaryType: Int32 = 2   // T_SHORT
    public static let secondaryType: Int32 = 1  // ST_ROOT

    public let hashtableSize: Int32
    public let bitmapFlag: Int32         // -1 if bitmap valid
    public let bitmapBlockPointers: [UInt32]
    public let bitmapExtensionBlock: UInt32

    public let rootAlterationDays: UInt32
    public let rootAlterationMins: UInt32
    public let rootAlterationTicks: UInt32

    public let diskName: String
    public let diskAltDays: UInt32
    public let diskAltMins: UInt32
    public let diskAltTicks: UInt32

    public let creationDays: UInt32
    public let creationMins: UInt32
    public let creationTicks: UInt32

    public let nextHash: Int32
    public let parentDir: Int32
    public let extension_: Int32
    public let secondaryType: Int32

    /// Parse a root block from raw data.
    /// `data.count` must equal the filesystem block size (512, 2048, etc.).
    public init(data: Data) throws {
        let blockLongs = data.count / 4
        guard blockLongs >= 56 else {
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                                            reason: "root block too short (\(data.count) bytes)")
        }
        guard data.readBE32(at: 0) == 2 else {  // type = T_SHORT
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                                            reason: "not a root block (type=\(data.readBE32(at: 0)))")
        }
        guard verifyFFSBlockChecksum(data) else {
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                                            reason: "root block checksum mismatch")
        }
        let htSz = Int(data.readBE32(at: 12))
        guard htSz == blockLongs - 56 else {
            throw AmigaDiskError.readFailed(offset: 0, length: data.count,
                                            reason: "unexpected ht_size \(htSz) for \(data.count)-byte block")
        }
        hashtableSize = Int32(htSz)

        let bmFlagIdx  = 6 + htSz              // = blockLongs - 50
        bitmapFlag     = Int32(bitPattern: data.readBE32(at: bmFlagIdx * 4))

        var ptrs: [UInt32] = []
        let bmPagesBase = (bmFlagIdx + 1) * 4
        for i in 0 ..< 25 {
            ptrs.append(data.readBE32(at: bmPagesBase + i * 4))
        }
        bitmapBlockPointers = ptrs

        let bmExtIdx         = bmFlagIdx + 26  // = blockLongs - 24
        bitmapExtensionBlock = data.readBE32(at: bmExtIdx * 4)

        let rDaysIdx         = bmExtIdx + 1    // = blockLongs - 23
        rootAlterationDays   = data.readBE32(at: rDaysIdx * 4)
        rootAlterationMins   = data.readBE32(at: (rDaysIdx + 1) * 4)
        rootAlterationTicks  = data.readBE32(at: (rDaysIdx + 2) * 4)

        diskName = data.readBSTR(at: (blockLongs - 20) * 4, maxLength: 32)

        // v_days at [blockLongs-10]
        diskAltDays  = data.readBE32(at: (blockLongs - 10) * 4)
        diskAltMins  = data.readBE32(at: (blockLongs -  9) * 4)
        diskAltTicks = data.readBE32(at: (blockLongs -  8) * 4)

        // c_days/c_mins/c_ticks at blockLongs-7..-5 (disk creation date).
        creationDays  = data.readBE32(at: (blockLongs - 7) * 4)
        creationMins  = data.readBE32(at: (blockLongs - 6) * 4)
        creationTicks = data.readBE32(at: (blockLongs - 5) * 4)

        nextHash     = Int32(bitPattern: data.readBE32(at: (blockLongs - 4) * 4))
        parentDir    = Int32(bitPattern: data.readBE32(at: (blockLongs - 3) * 4))
        extension_   = Int32(bitPattern: data.readBE32(at: (blockLongs - 2) * 4))
        secondaryType = Int32(bitPattern: data.readBE32(at: (blockLongs - 1) * 4))
    }
}

/// FFS boot block — first two blocks of a partition.
/// Bytes 0-3: DOS type (e.g. 0x444F5303 for DOS\3).
/// Bytes 4-7: checksum.
/// Bytes 8-11: root block offset.
/// Bytes 12+: optional boot code.
public struct FFSBootBlock {
    public let dosType: [UInt8]    // 4 bytes
    public let checksum: UInt32
    public let rootBlockOffset: UInt32
    public let bootCode: Data

    public var dosTypeString: String {
        let bytes = dosType.prefix(3)
        return bytes.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : "." }.joined()
    }

    public var hasDosSignature: Bool {
        dosType[0] == 0x44 && dosType[1] == 0x4F && dosType[2] == 0x53
    }

    /// Parse an FFS boot block from raw data (at least 12 bytes; typically 1024 bytes).
    /// Throws `invalidBootBlock` if the first 3 bytes are not 'D', 'O', 'S'.
    public init(data: Data) throws {
        guard data.count >= 12 else {
            throw AmigaDiskError.readFailed(offset: 0, length: 12,
                                            reason: "boot block too short (\(data.count) bytes)")
        }
        let b0 = data.readBE8(at: 0)
        let b1 = data.readBE8(at: 1)
        let b2 = data.readBE8(at: 2)
        let b3 = data.readBE8(at: 3)
        let parsedDosType: [UInt8] = [b0, b1, b2, b3]
        guard b0 == 0x44 && b1 == 0x4F && b2 == 0x53 else {
            throw AmigaDiskError.invalidBootBlock(dosType: parsedDosType)
        }
        dosType         = parsedDosType
        checksum        = data.readBE32(at: 4)
        rootBlockOffset = data.readBE32(at: 8)
        bootCode        = data.count > 12 ? data.advanced(by: 12) : Data()
    }
}
