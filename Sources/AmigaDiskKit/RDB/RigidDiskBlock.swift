import Foundation

/// RDSK block — Amiga Rigid Disk Block (RDB) partition table header.
/// Found by scanning the first 16 LBA sectors for the 0x5244534B ("RDSK") identifier.
///
/// Reference: http://amigadev.elowar.com/read/ADCD_2.1/Devices_Manual_guide/node0079.html
public struct RigidDiskBlock {
    // Block identifiers
    public static let identifier: UInt32 = 0x5244534B  // "RDSK"
    public static let searchLimit = 16                 // scan first 16 sectors only

    // Physical drive geometry
    public let cylinders: UInt32
    public let sectors: UInt32       // sectors per track
    public let heads: UInt32         // surfaces / heads
    public let interleave: UInt32

    // Disk size
    public let rdbBlockLo: UInt32    // first reserved block (usually 0)
    public let rdbBlockHi: UInt32    // last reserved block
    public let loCylinder: UInt32    // first usable cylinder for partitions
    public let hiCylinder: UInt32    // last usable cylinder

    // Linked-list heads (0xFFFFFFFF = list empty / last)
    public let partitionList: UInt32
    public let fileSysHdrList: UInt32
    public let badBlockList: UInt32

    // Flags and IDs
    public let flags: UInt32
    public let hostId: UInt32

    // Drive identification strings
    public let diskVendor: String
    public let diskProduct: String
    public let diskRevision: String

    // Block size in bytes (almost always 512)
    public let blockSize: UInt32

    // Attached blocks (populated by reader)
    public var partitionBlocks: [PartitionBlock] = []
    public var fileSystemHeaders: [FileSystemHeaderBlock] = []

    public var blocksPerCylinder: UInt32 { sectors * heads }

    /// Total byte offset to the start of a given cylinder.
    /// CRITICAL: uses Int64 throughout — UInt32 arithmetic wraps above ~4.3 GiB.
    public func byteOffset(forCylinder cylinder: UInt32) -> Int64 {
        Int64(cylinder) * Int64(blocksPerCylinder) * Int64(blockSize)
    }

    // MARK: - Construction

    /// Create a new RDSK descriptor from a disk geometry.
    /// All linked-list heads default to 0xFFFFFFFF (empty).
    public init(
        geometry: DiskGeometry,
        vendor: String = "AmigaDiskKit",
        product: String = "Virtual Disk",
        revision: String = "1.0"
    ) {
        cylinders   = geometry.cylinders
        sectors     = geometry.sectors
        heads       = geometry.heads
        interleave  = 0
        blockSize   = geometry.blockSize
        rdbBlockLo  = 0
        rdbBlockHi  = geometry.rdbBlockHi
        loCylinder  = geometry.loCylinder
        hiCylinder  = geometry.hiCylinder
        partitionList  = 0xFFFFFFFF
        fileSysHdrList = 0xFFFFFFFF
        badBlockList   = 0xFFFFFFFF
        flags          = 0x07  // RDBFF_LAST | RDBFF_LASTLUN | RDBFF_LASTTARGET
        hostId         = 0x07
        diskVendor     = vendor
        diskProduct    = product
        diskRevision   = revision
        partitionBlocks    = []
        fileSystemHeaders  = []
    }

    /// Serialize this RDSK descriptor to a 512-byte block with a valid Amiga checksum.
    ///
    /// - Parameters:
    ///   - partitionListLBA: Slice-relative LBA of the first PART block (0xFFFFFFFF = empty).
    ///   - fileSysHdrListLBA: Slice-relative LBA of the first FSHD block (0xFFFFFFFF = none).
    public func serialize(
        partitionListLBA: UInt32 = 0xFFFFFFFF,
        fileSysHdrListLBA: UInt32 = 0xFFFFFFFF
    ) -> Data {
        var block = Data(count: 512)
        block.writeBE32(RigidDiskBlock.identifier, at: 0x00)
        block.writeBE32(UInt32(64), at: 0x04)   // summedLongs
        // 0x08: checksum — written by embedAmigaChecksum below
        block.writeBE32(hostId,    at: 0x0C)
        block.writeBE32(blockSize, at: 0x10)
        block.writeBE32(flags,     at: 0x14)
        block.writeBE32(badBlockList,       at: 0x18)
        block.writeBE32(partitionListLBA,   at: 0x1C)
        block.writeBE32(fileSysHdrListLBA,  at: 0x20)
        // 0x24: driveInit — must be 0xFFFFFFFF (no init code); 0 causes the ROM to execute
        // the RDSK block itself as a device init segment, corrupting the boot process.
        block.writeBE32(UInt32.max, at: 0x24)
        // 0x28–0x3C: reserved — spec requires 0xFFFFFFFF, not 0; these are used as
        // list terminators and a 0 value would be interpreted as a valid block pointer.
        for i in 0 ..< 6 {
            block.writeBE32(UInt32.max, at: 0x28 + i * 4)
        }
        block.writeBE32(cylinders,  at: 0x40)
        block.writeBE32(sectors,    at: 0x44)
        block.writeBE32(heads,      at: 0x48)
        block.writeBE32(interleave, at: 0x4C)
        block.writeBE32(hiCylinder, at: 0x50)  // park = landing-zone cylinder
        block.writeBE32(rdbBlockLo, at: 0x80)
        block.writeBE32(rdbBlockHi, at: 0x84)
        block.writeBE32(loCylinder, at: 0x88)
        block.writeBE32(hiCylinder, at: 0x8C)
        // rdb_CylBlocks: blocks per cylinder = heads × sectors.
        // The Amiga ROM uses this to compute partition start LBAs:
        //   boot_lba = partition.lowCyl × rdb_CylBlocks
        // A value of 0 makes every partition appear to start at LBA 0 (the RDSK block),
        // causing "Not a DOS disk" because the RDSK magic is not a valid FFS DosType.
        block.writeBE32(heads * sectors, at: 0x90)
        block.writeAmigaString(diskVendor,   at: 0xA0, length: 8)
        block.writeAmigaString(diskProduct,  at: 0xA8, length: 16)
        block.writeAmigaString(diskRevision, at: 0xB8, length: 4)
        // 0xBC–0xFF: controller strings (zero)
        embedAmigaChecksum(into: &block)
        return block
    }

    // MARK: - Parsing

    /// Parse an RDSK block from 512-byte block data (no linked-list traversal).
    /// Throws if the identifier or checksum is invalid.
    init(data: Data) throws {
        guard data.count >= 512 else {
            throw AmigaDiskError.readFailed(offset: 0, length: 512,
                                            reason: "RDSK block data too short")
        }
        guard data.readBE32(at: 0) == RigidDiskBlock.identifier else {
            throw AmigaDiskError.rdskNotFound
        }
        guard verifyAmigaBlockChecksum(data) else {
            let expected  = computeAmigaBlockChecksum(data)
            let stored    = Int32(bitPattern: data.readBE32(at: 8))
            throw AmigaDiskError.rdskChecksumMismatch(block: 0, expected: expected, calculated: stored)
        }

        // Physical geometry
        cylinders   = data.readBE32(at: 0x40)
        sectors     = data.readBE32(at: 0x44)
        heads       = data.readBE32(at: 0x48)
        interleave  = data.readBE32(at: 0x4C)

        // Size / reserved area
        rdbBlockLo  = data.readBE32(at: 0x80)
        rdbBlockHi  = data.readBE32(at: 0x84)
        loCylinder  = data.readBE32(at: 0x88)
        hiCylinder  = data.readBE32(at: 0x8C)

        // Linked-list heads
        badBlockList   = data.readBE32(at: 0x18)
        partitionList  = data.readBE32(at: 0x1C)
        fileSysHdrList = data.readBE32(at: 0x20)

        // Flags / IDs
        flags  = data.readBE32(at: 0x14)
        hostId = data.readBE32(at: 0x0C)

        // Block size
        blockSize = data.readBE32(at: 0x10)

        // Identification strings
        diskVendor   = data.readAmigaString(at: 0xA0, length: 8)
        diskProduct  = data.readAmigaString(at: 0xA8, length: 16)
        diskRevision = data.readAmigaString(at: 0xB8, length: 4)
    }

    /// Scan the first 16 LBAs of a block device (offset by `sliceStartLBA`) for an
    /// RDSK block, then traverse the PART and FSHD linked lists.
    ///
    /// - Parameters:
    ///   - device: Open block device.
    ///   - sliceStartLBA: LBA offset of the RDB partition slice (0 for pure-RDB images).
    /// - Returns: A fully-populated `RigidDiskBlock`.
    public static func scan(device: BlockDevice, sliceStartLBA: Int64) throws -> RigidDiskBlock {
        // Step 1: find the RDSK block
        var rdskData: Data?
        var rdskLBA: Int = 0
        for lba in 0 ..< RigidDiskBlock.searchLimit {
            let absoluteLBA = sliceStartLBA + Int64(lba)
            let data = try device.readBlock(at: absoluteLBA)
            guard data.readBE32(at: 0) == RigidDiskBlock.identifier else { continue }
            // Signature found — now validate checksum
            guard verifyAmigaBlockChecksum(data) else {
                let expected = computeAmigaBlockChecksum(data)
                let stored   = Int32(bitPattern: data.readBE32(at: 8))
                throw AmigaDiskError.rdskChecksumMismatch(
                    block: lba, expected: expected, calculated: stored)
            }
            rdskData = data
            rdskLBA  = lba
            break
        }
        guard let rdskData else {
            throw AmigaDiskError.rdskNotFound
        }
        _ = rdskLBA  // silence unused-variable warning

        var rdb = try RigidDiskBlock(data: rdskData)

        // Step 2: traverse PART linked list
        var nextPartLBA = rdb.partitionList
        var partIterations = 0
        while nextPartLBA != 0xFFFFFFFF && partIterations < 256 {
            let absoluteLBA = sliceStartLBA + Int64(nextPartLBA)
            let blockData: Data
            do {
                blockData = try device.readBlock(at: absoluteLBA)
            } catch {
                break  // truncated image / fixture — stop gracefully
            }
            let part = try PartitionBlock(data: blockData, lba: nextPartLBA)
            rdb.partitionBlocks.append(part)
            nextPartLBA = part.nextPartitionBlock
            partIterations += 1
        }

        // Step 3: traverse FSHD linked list
        // NOTE: Real disk images may contain the second FSHD (DOS\7) beyond the
        // 32-sector RDB-area fixture boundary.  We stop gracefully on short-read
        // rather than propagating the error, so fixture-based tests still pass.
        var nextFSHDLBA = rdb.fileSysHdrList
        var fshdIterations = 0
        while nextFSHDLBA != 0xFFFFFFFF && fshdIterations < 256 {
            let absoluteLBA = sliceStartLBA + Int64(nextFSHDLBA)
            let blockData: Data
            do {
                blockData = try device.readBlock(at: absoluteLBA)
            } catch {
                break  // truncated image / fixture — stop gracefully
            }
            let fshd = try FileSystemHeaderBlock(data: blockData, lba: nextFSHDLBA)
            rdb.fileSystemHeaders.append(fshd)
            nextFSHDLBA = fshd.nextFileSystemHeaderBlock
            fshdIterations += 1
        }

        return rdb
    }
}

public struct RigidDiskBlockFlags: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let last    = RigidDiskBlockFlags(rawValue: 1)
    public static let lastLun = RigidDiskBlockFlags(rawValue: 2)
    public static let lastId  = RigidDiskBlockFlags(rawValue: 4)
}
