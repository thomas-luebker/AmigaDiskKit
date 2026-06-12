import Foundation

/// PART block — one partition entry in the RDB linked list.
/// Linked via nextPartitionBlock; list terminated by 0xFFFFFFFF.
public struct PartitionBlock {
    public static let identifier: UInt32 = 0x50415254  // "PART"

    public let hostId: UInt32
    public let nextPartitionBlock: UInt32  // next PART block LBA, or 0xFFFFFFFF

    // Drive environ (see exec/devices.h DeviceNode / FileSysStartupMsg)
    public let sizeOfVector: UInt32    // longs in environ vector (min 11, usually 16)
    public let sizeBlock: UInt32       // block size in longs (128 for 512-byte blocks)
    public let secOrg: UInt32          // sector origin (usually 0)
    public let surfaces: UInt32        // heads
    public let sectors: UInt32         // sectors per block (filesystem granularity multiplier)
    public let blocksPerTrack: UInt32  // physical sectors per track
    public let reserved: UInt32        // reserved blocks at partition start (usually 2)
    public let preAlloc: UInt32        // reserved blocks at partition end (usually 0)
    public let interleave: UInt32
    public let lowCyl: UInt32          // first cylinder (inclusive)
    public let highCyl: UInt32         // last cylinder (inclusive)
    public let numBuffer: UInt32
    public let bufMemType: UInt32
    public let maxTransfer: UInt32
    public let mask: UInt32
    public let bootPriority: Int32
    public let dosType: UInt32         // e.g. 0x444F5303 = DOS\3, 0x50445303 = PDS\3

    public let driveName: String       // AmigaDOS volume name (e.g. "DH0", "DH1")

    public let flags: UInt32
    /// Bit 0 set = partition is bootable (AmigaDOS standard; NOT bit 0 clear).
    public var isBootable: Bool { flags & 1 != 0 }
    /// Bit 1 set = partition should not be auto-mounted.
    public var noMount: Bool { flags & 2 != 0 }

    public let blockSize: UInt32       // physical block size (always 512 for standard RDB)
    /// Filesystem block size in bytes: de_sectorsPerBlock × 512.
    /// e.g. sectorsPerBlock=4 → 2048-byte filesystem blocks.
    public let fileSystemBlockSize: UInt32

    /// Byte offset of the first block of this partition within the disk image.
    /// Requires the parent RigidDiskBlock for geometry — always Int64.
    public func startByteOffset(rdb: RigidDiskBlock) -> Int64 {
        rdb.byteOffset(forCylinder: lowCyl)
    }

    /// Byte offset of the last block (exclusive) of this partition.
    public func endByteOffset(rdb: RigidDiskBlock) -> Int64 {
        rdb.byteOffset(forCylinder: highCyl + 1)
    }

    /// Human-readable dosType, e.g. "DOS\3".
    public var dosTypeFormatted: String {
        let bytes = [
            UInt8((dosType >> 24) & 0xFF),
            UInt8((dosType >> 16) & 0xFF),
            UInt8((dosType >>  8) & 0xFF),
            UInt8( dosType        & 0xFF),
        ]
        let prefix = bytes.prefix(3).map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : "." }.joined()
        return "\(prefix)\\\(bytes[3])"
    }

    /// Hex dosType, e.g. "0x444F5303".
    public var dosTypeHex: String {
        "0x\(String(dosType, radix: 16, uppercase: true).uppercased())"
    }

    // MARK: - Construction

    /// Create a new PART descriptor from explicit cylinder bounds and geometry.
    public init(
        name: String,
        dosType: UInt32,
        lowCyl: UInt32,
        highCyl: UInt32,
        geometry: DiskGeometry,
        isBootable: Bool = false,
        bootPriority: Int32 = 0,
        sectorsPerFSBlock: UInt32 = 1
    ) {
        driveName          = name
        self.dosType       = dosType
        self.lowCyl        = lowCyl
        self.highCyl       = highCyl
        surfaces           = geometry.heads
        blocksPerTrack     = geometry.sectors
        sectors            = sectorsPerFSBlock  // de_SectorsPerBlock (FS granularity)
        flags              = isBootable ? 1 : 0
        self.bootPriority  = bootPriority
        // Standard fixed values
        hostId             = 0x07
        nextPartitionBlock = 0xFFFFFFFF
        sizeOfVector       = 0x10   // 16 longs in DosEnvVec
        sizeBlock          = 0x80   // 128 longs = 512 bytes
        secOrg             = 0
        reserved           = 2
        preAlloc           = 0
        interleave         = 0
        numBuffer          = 30
        bufMemType         = 0
        maxTransfer        = 0x0001FE00
        mask               = 0x7FFFFFFE
        // Derived
        blockSize          = sizeBlock * 4
        fileSystemBlockSize = sectors * blockSize
    }

    /// Serialize this PART descriptor to a 512-byte block with a valid Amiga checksum.
    ///
    /// - Parameter next: Slice-relative LBA of the next PART block (0xFFFFFFFF = last).
    public func serialize(next: UInt32 = 0xFFFFFFFF) -> Data {
        var block = Data(count: 512)
        block.writeBE32(PartitionBlock.identifier, at: 0x00)
        block.writeBE32(UInt32(64), at: 0x04)  // summedLongs
        // 0x08: checksum — written by embedAmigaChecksum below
        block.writeBE32(hostId, at: 0x0C)
        block.writeBE32(next,   at: 0x10)
        block.writeBE32(flags,  at: 0x14)
        // 0x18–0x23: reserved (zero)
        block.writeBSTR(driveName, at: 0x24, maxLength: 32)
        // 0x44–0x7F: reserved (zero)
        block.writeBE32(sizeOfVector,  at: 0x80)
        block.writeBE32(sizeBlock,     at: 0x84)
        block.writeBE32(secOrg,        at: 0x88)
        block.writeBE32(surfaces,      at: 0x8C)
        block.writeBE32(sectors,       at: 0x90)  // de_SectorsPerBlock
        block.writeBE32(blocksPerTrack, at: 0x94)
        block.writeBE32(reserved,      at: 0x98)
        block.writeBE32(preAlloc,      at: 0x9C)
        block.writeBE32(interleave,    at: 0xA0)
        block.writeBE32(lowCyl,        at: 0xA4)
        block.writeBE32(highCyl,       at: 0xA8)
        block.writeBE32(numBuffer,     at: 0xAC)
        block.writeBE32(bufMemType,    at: 0xB0)
        block.writeBE32(maxTransfer,   at: 0xB4)
        block.writeBE32(mask,          at: 0xB8)
        block.writeBE32(bootPriority,  at: 0xBC)
        block.writeBE32(dosType,       at: 0xC0)
        embedAmigaChecksum(into: &block)
        return block
    }

    // MARK: - Parsing

    /// Parse a PART block from 512-byte block data.
    /// Throws `partitionBlockChecksumMismatch` if the Amiga checksum fails.
    public init(data: Data, lba: UInt32) throws {
        guard data.count >= 512 else {
            throw AmigaDiskError.readFailed(offset: Int64(lba) * 512, length: 512,
                                            reason: "PART block too short")
        }
        guard verifyAmigaBlockChecksum(data) else {
            throw AmigaDiskError.partitionBlockChecksumMismatch(block: lba)
        }
        // Header
        hostId             = data.readBE32(at: 0x0C)
        nextPartitionBlock = data.readBE32(at: 0x10)
        flags              = data.readBE32(at: 0x14)

        // driveName: BSTR at 0x24, max 32 bytes total
        driveName = data.readBSTR(at: 0x24, maxLength: 32)

        // DosEnvVec starts at 0x80
        sizeOfVector      = data.readBE32(at: 0x80)
        sizeBlock         = data.readBE32(at: 0x84)  // 128 → block size = 512 bytes
        secOrg            = data.readBE32(at: 0x88)
        surfaces          = data.readBE32(at: 0x8C)
        sectors           = data.readBE32(at: 0x90)  // sectorsPerBlock (FS granularity)
        blocksPerTrack    = data.readBE32(at: 0x94)
        reserved          = data.readBE32(at: 0x98)
        preAlloc          = data.readBE32(at: 0x9C)
        interleave        = data.readBE32(at: 0xA0)
        lowCyl            = data.readBE32(at: 0xA4)
        highCyl           = data.readBE32(at: 0xA8)
        numBuffer         = data.readBE32(at: 0xAC)
        bufMemType        = data.readBE32(at: 0xB0)
        maxTransfer       = data.readBE32(at: 0xB4)
        mask              = data.readBE32(at: 0xB8)
        bootPriority      = Int32(bitPattern: data.readBE32(at: 0xBC))
        dosType           = data.readBE32(at: 0xC0)

        // Derived geometry
        blockSize         = sizeBlock * 4          // sizeBlock=128 → 512 bytes
        fileSystemBlockSize = sectors * blockSize  // sectorsPerBlock × 512
    }
}

public struct KnownDosType {
    public static let dos0: UInt32 = 0x444F5300  // DOS\0 — OFS (no-intl)
    public static let dos1: UInt32 = 0x444F5301  // DOS\1 — OFS+INTL
    public static let dos2: UInt32 = 0x444F5302  // DOS\2 — FFS (no-intl, rare)
    public static let dos3: UInt32 = 0x444F5303  // DOS\3 — FFS
    public static let dos5: UInt32 = 0x444F5305  // DOS\5 — FFS+INTL
    public static let dos6: UInt32 = 0x444F5306  // DOS\6 — FFS2 long filenames
    public static let dos7: UInt32 = 0x444F5307  // DOS\7 — FFS2 long filenames + INTL

    public static let pds3: UInt32 = 0x50445303  // PDS\3 — PFS3

    public static func isOFS(_ dosType: UInt32) -> Bool {
        dosType == dos0 || dosType == dos1
    }

    public static func isFFS(_ dosType: UInt32) -> Bool {
        dosType == dos2 || dosType == dos3 || dosType == dos5 || dosType == dos6 || dosType == dos7
    }

    /// DOS\6 / DOS\7 — FFS2 long-filename mode (LNFS). Directory and file
    /// header blocks use a different layout: the filename (up to 110 chars)
    /// lives in the old comment area (block end − 184), the comment field is
    /// gone, and the dates move to block end − 60. The classic name field at
    /// block end − 80 is unused. Verified byte-for-byte against hst-imager
    /// reference volumes and the FFS2 handler's on-hardware behavior.
    public static func isLongNameFS(_ dosType: UInt32) -> Bool {
        dosType == dos6 || dosType == dos7
    }

    public static func isPFS3(_ dosType: UInt32) -> Bool {
        dosType == pds3
    }
}
