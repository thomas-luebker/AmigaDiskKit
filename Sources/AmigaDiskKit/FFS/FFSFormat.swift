import Foundation

// MARK: - FFSFormatSpec

/// Parameters for a fresh FFS/FFS2 format.
public struct FFSFormatSpec {
    public var volumeName: String
    public var creationDate: Date

    public init(volumeName: String = "Empty", creationDate: Date = Date()) {
        self.volumeName = volumeName
        self.creationDate = creationDate
    }
}

// MARK: - FFSLayout

/// Computed block layout for a fresh FFS/FFS2 format — no writes performed.
public struct FFSLayout {
    /// Total number of filesystem blocks in the partition (boot block area included).
    public let totalFSBlocks: Int
    /// FS-block number of the root block (relative to partition start).
    public let rootBlockFSBlock: Int
    /// FS-block numbers of the bitmap blocks.
    public let bitmapBlockFSBlocks: [Int]
    /// FS-block numbers of the bitmap extension blocks (empty when ≤ 25 bitmap blocks).
    public let bitmapExtFSBlocks: [Int]
    /// Reserved FS blocks at partition start (boot block area; always 2).
    public let reserved: Int
    /// FS block size in bytes (512 for DOS\3, 2048 for DOS\7).
    public let fsBlockSize: Int
    /// Number of filesystem block bits covered by one bitmap block.
    public let bitsPerBitmapBlock: Int
}

// MARK: - FFSFormatter

/// Writes FFS or FFS2 filesystem structures onto a partition that has already been
/// allocated in an RDB.  Phases: boot block → bitmap blocks → bitmap extension
/// blocks → root block.  No data area is touched.
public enum FFSFormatter {

    // Amiga epoch: Jan 1 1978 00:00:00 UTC = Unix timestamp 252,460,800.
    // 1970-01-01 to 1978-01-01: 2922 days (leap years 1972, 1976) = 252,460,800 s.
    private static let amigaEpochUnixSeconds: TimeInterval = 252_460_800

    // MARK: - Public API

    /// Compute the block layout without performing any I/O.
    public static func layout(partition: PartitionBlock, rdb: RigidDiskBlock) -> FFSLayout {
        let sectorsPerFSBlock = Int(partition.sectors)
        let fsBlockSize       = Int(partition.fileSystemBlockSize)
        let blockLongs        = fsBlockSize / 4
        let bitsPerBitmapBlock = (blockLongs - 1) * 32

        let partCylinders   = Int(partition.highCyl - partition.lowCyl + 1)
        let partSectors     = partCylinders * Int(rdb.blocksPerCylinder)
        let totalFSBlocks   = partSectors / sectorsPerFSBlock

        let reserved        = Int(partition.reserved)   // usually 2
        let rootBlockFSBlock = totalFSBlocks / 2

        let numBitmapBlocks = (totalFSBlocks + bitsPerBitmapBlock - 1) / bitsPerBitmapBlock
        let bitmapBlockFSBlocks = (0 ..< numBitmapBlocks).map { reserved + $0 }

        let extCapacity   = blockLongs - 1  // last long of ext block = next-ext pointer
        let excessBitmap  = max(0, numBitmapBlocks - 25)
        let numExtBlocks  = excessBitmap > 0
            ? (excessBitmap + extCapacity - 1) / extCapacity
            : 0
        let extBase = reserved + numBitmapBlocks
        let bitmapExtFSBlocks = (0 ..< numExtBlocks).map { extBase + $0 }

        return FFSLayout(
            totalFSBlocks:      totalFSBlocks,
            rootBlockFSBlock:   rootBlockFSBlock,
            bitmapBlockFSBlocks: bitmapBlockFSBlocks,
            bitmapExtFSBlocks:  bitmapExtFSBlocks,
            reserved:           reserved,
            fsBlockSize:        fsBlockSize,
            bitsPerBitmapBlock: bitsPerBitmapBlock
        )
    }

    /// Format a partition: write the boot block, bitmap blocks, bitmap extension blocks,
    /// and root block.  The image must already exist and contain a valid RDB.
    ///
    /// - Parameters:
    ///   - device:        Open `BlockDevice` wrapping the image file.
    ///   - sliceStartLBA: LBA offset of the RDB slice (0 for pure-RDB; rdbStartLBA for MBR+RDB).
    ///   - partition:     The partition to format (from a scanned `RigidDiskBlock`).
    ///   - rdb:           The `RigidDiskBlock` that owns `partition`.
    ///   - spec:          Volume name and creation date.
    public static func format(
        device: BlockDevice,
        sliceStartLBA: Int64 = 0,
        partition: PartitionBlock,
        rdb: RigidDiskBlock,
        spec: FFSFormatSpec = FFSFormatSpec()
    ) throws {
        let layout  = Self.layout(partition: partition, rdb: rdb)
        let fsSize  = layout.fsBlockSize

        // Absolute byte offset of partition start on the disk image.
        let partAbsByte: Int64 =
            (sliceStartLBA + Int64(partition.lowCyl) * Int64(rdb.blocksPerCylinder)) * 512

        func byteOffset(forFSBlock fsBlock: Int) -> Int64 {
            partAbsByte + Int64(fsBlock) * Int64(fsSize)
        }

        // 1. Boot block — always 1024 bytes (2 physical sectors), at partition start.
        let bootBlock = makeBootBlock(dosType: partition.dosType,
                                      rootBlockFSBlock: layout.rootBlockFSBlock)
        try device.write(bootBlock, at: partAbsByte)

        // 2. Bitmap blocks.
        let usedFSBlocks: Set<Int> = Set(
            Array(0 ..< layout.reserved) +
            layout.bitmapBlockFSBlocks +
            layout.bitmapExtFSBlocks +
            [layout.rootBlockFSBlock]
        )

        // The bitmap's bit domain is `sectOfMap = blockNum - reserved` (canonical Amiga FFS
        // convention — blocks below `reserved` have no representation in the bitmap at all).
        let totalMapBits = layout.totalFSBlocks - layout.reserved
        for (idx, bitmapFSBlock) in layout.bitmapBlockFSBlocks.enumerated() {
            let rangeStart = idx * layout.bitsPerBitmapBlock
            let rangeEnd   = Swift.min(rangeStart + layout.bitsPerBitmapBlock, totalMapBits)
            let bitmapData = makeBitmapBlock(fsBlockSize: fsSize,
                                             rangeStart: rangeStart,
                                             rangeEnd: rangeEnd,
                                             reserved: layout.reserved,
                                             usedBlocks: usedFSBlocks)
            try device.write(bitmapData, at: byteOffset(forFSBlock: bitmapFSBlock))
        }

        // 3. Bitmap extension blocks (if numBitmapBlocks > 25).
        let blockLongs   = fsSize / 4
        let extCapacity  = blockLongs - 1

        for (extIdx, extFSBlock) in layout.bitmapExtFSBlocks.enumerated() {
            let start = 25 + extIdx * extCapacity
            let end   = Swift.min(start + extCapacity, layout.bitmapBlockFSBlocks.count)
            let nextExtLBA: UInt32 = extIdx + 1 < layout.bitmapExtFSBlocks.count
                ? UInt32(layout.bitmapExtFSBlocks[extIdx + 1])
                : 0  // 0 = end of chain (adflib/hst-imager convention — NOT 0xFFFFFFFF)
            let extData = makeBitmapExtBlock(fsBlockSize: fsSize,
                                             bitmapFSBlocks: layout.bitmapBlockFSBlocks,
                                             start: start,
                                             end: end,
                                             nextExtLBA: nextExtLBA)
            try device.write(extData, at: byteOffset(forFSBlock: extFSBlock))
        }

        // 4. Root block.
        let bitmapExtPtr: UInt32 = layout.bitmapExtFSBlocks.first.map(UInt32.init) ?? 0
        let rootData = makeRootBlock(fsBlockSize: fsSize,
                                     rootFSBlock: layout.rootBlockFSBlock,
                                     spec: spec,
                                     bitmapFSBlocks: layout.bitmapBlockFSBlocks,
                                     bitmapExtPtr: bitmapExtPtr)
        try device.write(rootData, at: byteOffset(forFSBlock: layout.rootBlockFSBlock))
    }

    // MARK: - Block builders

    private static func makeBootBlock(dosType: UInt32, rootBlockFSBlock: Int) -> Data {
        var block = Data(count: 1024)
        block.writeBE32(dosType, at: 0)
        // offset 4: checksum (set below)
        block.writeBE32(UInt32(rootBlockFSBlock), at: 8)
        embedFFSBootBlockChecksum(into: &block)
        return block
    }

    /// Builds one bitmap block. `rangeStart`/`rangeEnd` are `sectOfMap` bounds (i.e.
    /// `blockNum - reserved`) — the canonical Amiga FFS bitmap domain, confirmed
    /// byte-for-byte against hst-imager's `Bitmap.AdfSetBlockUsed`/`AdfIsBlockFree`:
    /// bit `sectOfMap % 32` (LSB-first, mask `1 << k`) of data word `sectOfMap / 32`
    /// (word 0 = the long immediately after the checksum). Bit set (1) = free.
    private static func makeBitmapBlock(
        fsBlockSize: Int,
        rangeStart: Int,
        rangeEnd: Int,
        reserved: Int,
        usedBlocks: Set<Int>
    ) -> Data {
        var block = Data(count: fsBlockSize)

        let validBits   = rangeEnd - rangeStart
        let fullLongs   = validBits / 32
        let remainder   = validBits % 32

        // Fill complete words with all-free (1 = free).
        for i in 1 ..< (fullLongs + 1) {
            block.writeBE32(UInt32.max, at: i * 4)
        }
        // Partial last word: low `remainder` bits free (lowest sectOfMap values are LSB-first),
        // high bits = 0 (non-existent blocks beyond the partition).
        if remainder > 0 {
            let partialIdx = fullLongs + 1
            let validMask  = (UInt32(1) << UInt32(remainder)) &- 1
            block.writeBE32(validMask, at: partialIdx * 4)
        }

        // Mark used blocks (bit = 0). blockNum -> sectOfMap = blockNum - reserved.
        for blockNum in usedBlocks {
            let sectOfMap = blockNum - reserved
            guard sectOfMap >= rangeStart && sectOfMap < rangeEnd else { continue }
            let localBit = sectOfMap - rangeStart
            let longIdx  = 1 + localBit / 32
            let bitPos   = localBit % 32
            let word     = block.readBE32(at: longIdx * 4)
            block.writeBE32(word & ~(UInt32(1) << UInt32(bitPos)), at: longIdx * 4)
        }

        embedBitmapBlockChecksum(into: &block)
        return block
    }

    private static func makeBitmapExtBlock(
        fsBlockSize: Int,
        bitmapFSBlocks: [Int],
        start: Int,
        end: Int,
        nextExtLBA: UInt32
    ) -> Data {
        let blockLongs = fsBlockSize / 4
        var block = Data(count: fsBlockSize)
        // longs[0..(blockLongs-2)] = bitmap LBA pointers (0 = unused slot).
        // adflib/hst-imager stop reading at 0, not 0xFFFFFFFF, so unused slots must be 0.
        for i in 0 ..< (blockLongs - 1) {
            let bitmapIdx = start + i
            if bitmapIdx < end && bitmapIdx < bitmapFSBlocks.count {
                block.writeBE32(UInt32(bitmapFSBlocks[bitmapIdx]), at: i * 4)
            }
            // else: leave as 0 (block was initialised with Data(count:) = all zeros)
        }
        // last long = next extension block LBA.
        block.writeBE32(nextExtLBA, at: (blockLongs - 1) * 4)
        // No checksum in extension blocks.
        return block
    }

    private static func makeRootBlock(
        fsBlockSize: Int,
        rootFSBlock: Int,
        spec: FFSFormatSpec,
        bitmapFSBlocks: [Int],
        bitmapExtPtr: UInt32
    ) -> Data {
        let blockLongs  = fsBlockSize / 4
        let htSize      = blockLongs - 56
        var block       = Data(count: fsBlockSize)

        // Fixed header.
        block.writeBE32(UInt32(2),           at: 0)   // type = T_SHORT
        block.writeBE32(UInt32(0),           at: 4)   // header_key = 0 for root blocks (RKM spec; adflib/hst-imager convention)
        block.writeBE32(UInt32(0),           at: 8)   // high_seq = 0
        block.writeBE32(UInt32(htSize),      at: 12)  // ht_size
        block.writeBE32(UInt32(0),           at: 16)  // first_data = 0
        // long[5] at offset 20 = checksum (written by embedFFSBlockChecksum below)
        // long[6..(6+htSize-1)] = hashtable (all zeros for empty volume)

        // Bitmap info region: long[6+htSize] = long[blockLongs-50].
        let bmFlagIdx = 6 + htSize
        block.writeBE32(UInt32.max, at: bmFlagIdx * 4)        // bm_flag = -1 (valid)

        let bmPagesBase = (bmFlagIdx + 1) * 4
        for i in 0 ..< 25 {
            let lba: UInt32 = i < bitmapFSBlocks.count
                ? UInt32(bitmapFSBlocks[i])
                : 0
            block.writeBE32(lba, at: bmPagesBase + i * 4)
        }

        let bmExtIdx = bmFlagIdx + 26                          // = blockLongs - 24
        block.writeBE32(bitmapExtPtr, at: bmExtIdx * 4)       // bm_ext

        let (days, mins, ticks) = amigaDate(spec.creationDate)
        let rDaysIdx = bmExtIdx + 1                            // = blockLongs - 23
        block.writeBE32(days,  at: rDaysIdx * 4)              // r_days
        block.writeBE32(mins,  at: (rDaysIdx + 1) * 4)        // r_mins
        block.writeBE32(ticks, at: (rDaysIdx + 2) * 4)        // r_ticks

        // diskName BSTR at long[blockLongs-20] (8 longs = 32 bytes, max 30-char name).
        block.writeBSTR(spec.volumeName, at: (blockLongs - 20) * 4, maxLength: 32)

        // v_days/v_mins/v_ticks at long[blockLongs-10].
        block.writeBE32(days,  at: (blockLongs - 10) * 4)
        block.writeBE32(mins,  at: (blockLongs - 9)  * 4)
        block.writeBE32(ticks, at: (blockLongs - 8)  * 4)

        // c_days/c_mins/c_ticks at long[blockLongs-7..-5] (disk creation date).
        // Set equal to modification date — hst-imager convention for fresh format.
        block.writeBE32(days,  at: (blockLongs - 7) * 4)
        block.writeBE32(mins,  at: (blockLongs - 6) * 4)
        block.writeBE32(ticks, at: (blockLongs - 5) * 4)

        // extension at long[blockLongs-2]: hst-imager writes a self-reference to the root
        // block's own FS block number. Standard specifies 0; match hst-imager for compatibility.
        block.writeBE32(UInt32(rootFSBlock), at: (blockLongs - 2) * 4)

        // sec_type = ST_ROOT = 1 at last long.
        block.writeBE32(UInt32(1), at: (blockLongs - 1) * 4)

        embedFFSBlockChecksum(into: &block)
        return block
    }

    // MARK: - Date helpers

    private static func amigaDate(_ date: Date) -> (days: UInt32, mins: UInt32, ticks: UInt32) {
        let elapsed = date.timeIntervalSince1970 - amigaEpochUnixSeconds
        guard elapsed >= 0 else { return (0, 0, 0) }
        let totalSeconds = Int(elapsed)
        let days  = UInt32(totalSeconds / 86400)
        let secsToday = totalSeconds % 86400
        let mins  = UInt32(secsToday / 60)
        let ticks = UInt32(secsToday % 60) * 50
        return (days, mins, ticks)
    }
}
