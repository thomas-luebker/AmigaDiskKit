import XCTest
@testable import AmigaDiskKit

final class FFSFormatterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFSFormatterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Checksum unit tests

    func testFFSBootBlockChecksum_roundTrip() {
        var block = Data(count: 1024)
        block.writeBE32(KnownDosType.dos3, at: 0)
        block.writeBE32(UInt32(262080), at: 8)
        embedFFSBootBlockChecksum(into: &block)
        XCTAssertTrue(verifyFFSBootBlockChecksum(block), "Boot block checksum must verify after embed")
        // Mutate one byte and verify it breaks
        block[100] ^= 0xFF
        XCTAssertFalse(verifyFFSBootBlockChecksum(block))
    }

    func testFFSBlockChecksum_roundTrip() {
        var block = Data(count: 512)
        block.writeBE32(UInt32(2), at: 0)    // type = T_SHORT
        block.writeBE32(UInt32(72), at: 12)  // ht_size
        block.writeBE32(UInt32(1), at: (128 - 1) * 4)  // sec_type = ST_ROOT
        embedFFSBlockChecksum(into: &block)
        XCTAssertTrue(verifyFFSBlockChecksum(block))
    }

    func testBitmapBlockChecksum_roundTrip() {
        var block = Data(count: 512)
        for i in 1..<128 { block.writeBE32(UInt32.max, at: i * 4) }
        embedBitmapBlockChecksum(into: &block)
        XCTAssertTrue(verifyBitmapBlockChecksum(block))
    }

    // MARK: - Layout computation

    func testLayout_DOS3_SmallPartition() throws {
        // 32 MiB disk: loCyl=2, hiCyl=64, partition: lowCyl=2, highCyl=64 (63 cylinders)
        // totalFSBlocks = 63 * 1008 = 63,504
        // bitsPerBitmapBlock = (128-1)*32 = 4064
        // numBitmapBlocks = ceil(63504/4064) = 16 → no extension blocks
        let geo = try DiskGeometry(sizeBytes: 32 * 1024 * 1024)
        let part = PartitionBlock(name: "DH0", dosType: KnownDosType.dos3,
                                  lowCyl: geo.loCylinder, highCyl: geo.hiCylinder,
                                  geometry: geo)
        let rdb = RigidDiskBlock(geometry: geo)
        let layout = FFSFormatter.layout(partition: part, rdb: rdb)

        let partCylinders = Int(geo.hiCylinder - geo.loCylinder + 1)
        let expectedTotal = partCylinders * 1008
        XCTAssertEqual(layout.totalFSBlocks, expectedTotal)
        XCTAssertEqual(layout.fsBlockSize, 512)
        XCTAssertEqual(layout.reserved, 2)
        XCTAssertEqual(layout.rootBlockFSBlock, expectedTotal / 2)
        XCTAssertEqual(layout.bitmapBlockFSBlocks.first, 2)
        XCTAssertTrue(layout.bitmapExtFSBlocks.isEmpty, "Small partition needs no extension blocks")

        let numBitmap = layout.bitmapBlockFSBlocks.count
        XCTAssertLessThanOrEqual(numBitmap, 25)
    }

    func testLayout_DOS3_LargePartition_WithExtension() throws {
        // 256 MiB disk: ~518 cylinders in partition
        // totalFSBlocks ≈ 521,744
        // numBitmapBlocks = 129 → needs 1 extension block (ceil((129-25)/127) = 1)
        let sizeBytes: Int64 = 256 * 1024 * 1024
        let geo = try DiskGeometry(sizeBytes: sizeBytes)
        let part = PartitionBlock(name: "DH0", dosType: KnownDosType.dos3,
                                  lowCyl: geo.loCylinder, highCyl: geo.hiCylinder,
                                  geometry: geo)
        let rdb = RigidDiskBlock(geometry: geo)
        let layout = FFSFormatter.layout(partition: part, rdb: rdb)

        XCTAssertGreaterThan(layout.bitmapBlockFSBlocks.count, 25)
        XCTAssertEqual(layout.bitmapExtFSBlocks.count, 1)

        // Extension block must follow immediately after the last bitmap block
        let lastBitmap = layout.bitmapBlockFSBlocks.last!
        XCTAssertEqual(layout.bitmapExtFSBlocks[0], lastBitmap + 1)
    }

    func testLayout_DOS7() throws {
        // 256 MiB DOS\7: sectorsPerFSBlock=4, fsBlockSize=2048
        // totalFSBlocks = partSectors / 4
        let sizeBytes: Int64 = 256 * 1024 * 1024
        let geo = try DiskGeometry(sizeBytes: sizeBytes)
        let part = PartitionBlock(name: "DH0", dosType: KnownDosType.dos7,
                                  lowCyl: geo.loCylinder, highCyl: geo.hiCylinder,
                                  geometry: geo, sectorsPerFSBlock: 4)
        let rdb = RigidDiskBlock(geometry: geo)
        let layout = FFSFormatter.layout(partition: part, rdb: rdb)

        XCTAssertEqual(layout.fsBlockSize, 2048)
        let partCylinders = Int(geo.hiCylinder - geo.loCylinder + 1)
        let expectedTotal = partCylinders * 1008 / 4
        XCTAssertEqual(layout.totalFSBlocks, expectedTotal)
        XCTAssertEqual(layout.bitsPerBitmapBlock, (512 - 1) * 32)
    }

    // MARK: - Format + verify round-trips

    func testFormatDOS3_NoExtension() throws {
        let imageURL = tmpDir.appendingPathComponent("dos3-small.img")
        let sizeBytes: Int64 = 32 * 1024 * 1024

        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .pureRDB(partitions: [
                                PartitionSpec(name: "DH0", dosType: KnownDosType.dos3)
                              ]))

        let device = try BlockDevice(url: imageURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks[0]
        let spec   = FFSFormatSpec(volumeName: "TestDisk",
                                   creationDate: Date(timeIntervalSince1970: 1_750_000_000))

        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb, spec: spec)

        let layout        = FFSFormatter.layout(partition: part, rdb: rdb)
        let partAbsByte   = Int64(part.lowCyl) * Int64(rdb.blocksPerCylinder) * 512

        // Boot block
        let bootData = try device.read(at: partAbsByte, length: 1024)
        XCTAssertTrue(verifyFFSBootBlockChecksum(bootData), "Boot block checksum must be valid")
        XCTAssertEqual(bootData.readBE32(at: 0), KnownDosType.dos3)
        XCTAssertEqual(Int(bootData.readBE32(at: 8)), layout.rootBlockFSBlock)

        // Root block
        let rootOffset = partAbsByte + Int64(layout.rootBlockFSBlock) * Int64(layout.fsBlockSize)
        let rootData   = try device.read(at: rootOffset, length: layout.fsBlockSize)
        XCTAssertTrue(verifyFFSBlockChecksum(rootData), "Root block checksum must be valid")
        let rootBlock  = try RootBlock(data: rootData)
        XCTAssertEqual(rootBlock.diskName, "TestDisk")
        XCTAssertEqual(rootBlock.secondaryType, 1)
        XCTAssertEqual(rootBlock.bitmapFlag, Int32(-1))
        XCTAssertTrue(layout.bitmapExtFSBlocks.isEmpty)

        // Bitmap blocks
        for bitmapFSBlock in layout.bitmapBlockFSBlocks {
            let offset     = partAbsByte + Int64(bitmapFSBlock) * Int64(layout.fsBlockSize)
            let bitmapData = try device.read(at: offset, length: layout.fsBlockSize)
            XCTAssertTrue(verifyBitmapBlockChecksum(bitmapData),
                          "Bitmap block \(bitmapFSBlock) checksum must be valid")
        }
    }

    func testFormatDOS3_WithExtension() throws {
        let imageURL = tmpDir.appendingPathComponent("dos3-large.img")
        let sizeBytes: Int64 = 256 * 1024 * 1024

        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .pureRDB(partitions: [
                                PartitionSpec(name: "DH0", dosType: KnownDosType.dos3)
                              ]))

        let device = try BlockDevice(url: imageURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks[0]
        let spec   = FFSFormatSpec(volumeName: "BigDisk")

        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb, spec: spec)

        let layout      = FFSFormatter.layout(partition: part, rdb: rdb)
        let partAbsByte = Int64(part.lowCyl) * Int64(rdb.blocksPerCylinder) * 512

        XCTAssertGreaterThan(layout.bitmapBlockFSBlocks.count, 25)
        XCTAssertEqual(layout.bitmapExtFSBlocks.count, 1)

        // Boot block
        let bootData = try device.read(at: partAbsByte, length: 1024)
        XCTAssertTrue(verifyFFSBootBlockChecksum(bootData))

        // Root block: bitmap extension pointer must be set
        let rootOffset = partAbsByte + Int64(layout.rootBlockFSBlock) * Int64(layout.fsBlockSize)
        let rootData   = try device.read(at: rootOffset, length: layout.fsBlockSize)
        XCTAssertTrue(verifyFFSBlockChecksum(rootData))
        let rootBlock  = try RootBlock(data: rootData)
        XCTAssertEqual(rootBlock.bitmapExtensionBlock, UInt32(layout.bitmapExtFSBlocks[0]))
        XCTAssertEqual(rootBlock.diskName, "BigDisk")

        // All bitmap blocks have valid checksums
        for bitmapFSBlock in layout.bitmapBlockFSBlocks {
            let offset     = partAbsByte + Int64(bitmapFSBlock) * Int64(layout.fsBlockSize)
            let bitmapData = try device.read(at: offset, length: layout.fsBlockSize)
            XCTAssertTrue(verifyBitmapBlockChecksum(bitmapData),
                          "Bitmap block \(bitmapFSBlock) must have valid checksum")
        }

        // Extension block at expected position
        let extFSBlock = layout.bitmapExtFSBlocks[0]
        let extOffset  = partAbsByte + Int64(extFSBlock) * Int64(layout.fsBlockSize)
        let extData    = try device.read(at: extOffset, length: layout.fsBlockSize)
        // First pointer = bitmap block 25 (first overflow)
        XCTAssertEqual(extData.readBE32(at: 0), UInt32(layout.bitmapBlockFSBlocks[25]))
        // Last long = 0 (no further extension — adflib/hst-imager convention)
        let lastLongOffset = (layout.fsBlockSize / 4 - 1) * 4
        XCTAssertEqual(extData.readBE32(at: lastLongOffset), 0)
    }

    func testFormatDOS7() throws {
        let imageURL = tmpDir.appendingPathComponent("dos7.img")
        let sizeBytes: Int64 = 256 * 1024 * 1024

        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .pureRDB(partitions: [
                                PartitionSpec(name: "DH0", dosType: KnownDosType.dos7,
                                              sectorsPerFSBlock: 4)
                              ]))

        let device = try BlockDevice(url: imageURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks[0]
        let spec   = FFSFormatSpec(volumeName: "FFS2Vol")

        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb, spec: spec)

        let layout      = FFSFormatter.layout(partition: part, rdb: rdb)
        let partAbsByte = Int64(part.lowCyl) * Int64(rdb.blocksPerCylinder) * 512

        XCTAssertEqual(layout.fsBlockSize, 2048)

        let bootData = try device.read(at: partAbsByte, length: 1024)
        XCTAssertTrue(verifyFFSBootBlockChecksum(bootData))
        XCTAssertEqual(bootData.readBE32(at: 0), KnownDosType.dos7)

        let rootOffset = partAbsByte + Int64(layout.rootBlockFSBlock) * Int64(layout.fsBlockSize)
        let rootData   = try device.read(at: rootOffset, length: layout.fsBlockSize)
        XCTAssertTrue(verifyFFSBlockChecksum(rootData))
        let rootBlock  = try RootBlock(data: rootData)
        XCTAssertEqual(rootBlock.diskName, "FFS2Vol")
        XCTAssertEqual(rootBlock.hashtableSize, Int32(512 - 56))  // 456 for 2048b blocks

        for bitmapFSBlock in layout.bitmapBlockFSBlocks {
            let offset     = partAbsByte + Int64(bitmapFSBlock) * Int64(layout.fsBlockSize)
            let bitmapData = try device.read(at: offset, length: layout.fsBlockSize)
            XCTAssertTrue(verifyBitmapBlockChecksum(bitmapData),
                          "DOS\\7 bitmap block \(bitmapFSBlock) must have valid checksum")
        }
    }

    func testFormatMBRPlusRDB() throws {
        // PiStorm-style 4 GiB: verify format works correctly with non-zero sliceStartLBA
        let imageURL  = tmpDir.appendingPathComponent("mbr-rdb-fmt.img")
        let sizeBytes: Int64 = 4 * 1024 * 1024 * 1024
        let fatStart: UInt32 = 2048
        let fatCount: UInt32 = 2_095_105
        let rdbStart: UInt32 = 2_097_153

        let specs = [PartitionSpec(name: "SDH0", dosType: KnownDosType.dos3,
                                   sizeCylinders: 200, isBootable: true)]
        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .mbrPlusRDB(fatStartLBA: fatStart,
                                                  fatSectorCount: fatCount,
                                                  rdbStartLBA: rdbStart,
                                                  partitions: specs))

        let device = try BlockDevice(url: imageURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: Int64(rdbStart))
        let part   = rdb.partitionBlocks[0]

        try FFSFormatter.format(device: device, sliceStartLBA: Int64(rdbStart),
                                partition: part, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: "System"))

        let layout = FFSFormatter.layout(partition: part, rdb: rdb)
        let partAbsByte = (Int64(rdbStart) + Int64(part.lowCyl) * Int64(rdb.blocksPerCylinder)) * 512

        let bootData = try device.read(at: partAbsByte, length: 1024)
        XCTAssertTrue(verifyFFSBootBlockChecksum(bootData))
        XCTAssertEqual(bootData.readBE32(at: 0), KnownDosType.dos3)

        let rootOffset = partAbsByte + Int64(layout.rootBlockFSBlock) * Int64(layout.fsBlockSize)
        let rootData   = try device.read(at: rootOffset, length: layout.fsBlockSize)
        XCTAssertTrue(verifyFFSBlockChecksum(rootData))
        let rootBlock  = try RootBlock(data: rootData)
        XCTAssertEqual(rootBlock.diskName, "System")
    }

    func testBitmapMarksFreeAndUsedBlocks() throws {
        // Verifies the canonical Amiga FFS bitmap convention — confirmed byte-for-byte
        // against hst-imager's Bitmap.AdfSetBlockUsed/AdfIsBlockFree:
        //   sectOfMap = blockNum - reserved
        //   bit       = sectOfMap % 32   (LSB-first, mask 1 << k)
        //   word      = sectOfMap / 32   (word 0 = first data long, after the checksum)
        //   bit set (1) = free, bit clear (0) = used
        // Blocks below `reserved` have NO representation in the bitmap at all — they're
        // implicitly unavailable to the allocator regardless of bitmap content.
        let imageURL  = tmpDir.appendingPathComponent("bitmap-check.img")
        let sizeBytes: Int64 = 32 * 1024 * 1024

        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .pureRDB(partitions: [
                                PartitionSpec(name: "DH0", dosType: KnownDosType.dos3)
                              ]))

        let device = try BlockDevice(url: imageURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks[0]

        try FFSFormatter.format(device: device, sliceStartLBA: 0,
                                partition: part, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: "Check"))

        let layout      = FFSFormatter.layout(partition: part, rdb: rdb)
        let partAbsByte = Int64(part.lowCyl) * Int64(rdb.blocksPerCylinder) * 512

        func isFree(fsBlock blockNum: Int) throws -> Bool {
            let sectOfMap      = blockNum - layout.reserved
            XCTAssertGreaterThanOrEqual(sectOfMap, 0, "block \(blockNum) is below reserved")
            let bitmapBlockIdx = sectOfMap / layout.bitsPerBitmapBlock
            let localBit       = sectOfMap % layout.bitsPerBitmapBlock
            let longIdx        = 1 + localBit / 32
            let bitPos         = localBit % 32
            let fsBlock        = layout.bitmapBlockFSBlocks[bitmapBlockIdx]
            let off            = partAbsByte + Int64(fsBlock) * Int64(layout.fsBlockSize)
            let data           = try device.read(at: off, length: layout.fsBlockSize)
            let word           = data.readBE32(at: longIdx * 4)
            return (word >> UInt32(bitPos)) & 1 == 1
        }

        XCTAssertEqual(layout.reserved, 2)

        // The bitmap block itself (sectOfMap 0 → LSB of the first data word) must be used.
        XCTAssertFalse(try isFree(fsBlock: layout.bitmapBlockFSBlocks[0]),
                       "Bitmap block must be marked used (bit=0)")

        // The root block must be marked used.
        XCTAssertFalse(try isFree(fsBlock: layout.rootBlockFSBlock),
                       "Root block must be marked used (bit=0)")

        // A middle-of-disk FS block that isn't root/bitmap/reserved should be free.
        let midBlock = layout.totalFSBlocks / 4
        let isMidUsed = (Set([layout.rootBlockFSBlock])
                            .union(layout.bitmapBlockFSBlocks)
                            .union(layout.bitmapExtFSBlocks)
                            .union(Set(0..<layout.reserved))).contains(midBlock)
        if !isMidUsed {
            XCTAssertTrue(try isFree(fsBlock: midBlock),
                          "Free FS block \(midBlock) must be marked free (bit=1)")
        }
    }

    func testAmigaDateEncoding() throws {
        // Known date: 1978-01-02 00:01:00 UTC (day 1, minute 1, tick 0)
        let knownDate = Date(timeIntervalSince1970: 252460800 + 86400 + 60)  // epoch + 1 day + 1 min

        let imageURL = tmpDir.appendingPathComponent("dates.img")
        let sizeBytes: Int64 = 32 * 1024 * 1024

        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .pureRDB(partitions: [
                                PartitionSpec(name: "DH0", dosType: KnownDosType.dos3)
                              ]))

        let device = try BlockDevice(url: imageURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks[0]

        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: "DateTest", creationDate: knownDate))

        let layout      = FFSFormatter.layout(partition: part, rdb: rdb)
        let partAbsByte = Int64(part.lowCyl) * Int64(rdb.blocksPerCylinder) * 512
        let rootOffset  = partAbsByte + Int64(layout.rootBlockFSBlock) * Int64(layout.fsBlockSize)
        let rootData    = try device.read(at: rootOffset, length: layout.fsBlockSize)
        let rootBlock   = try RootBlock(data: rootData)

        XCTAssertEqual(rootBlock.rootAlterationDays, 1,  "Expected 1 day since Amiga epoch")
        XCTAssertEqual(rootBlock.rootAlterationMins, 1,  "Expected 1 minute since midnight")
        XCTAssertEqual(rootBlock.rootAlterationTicks, 0, "Expected 0 ticks in the minute")
        XCTAssertEqual(rootBlock.creationDays, 1)
        XCTAssertEqual(rootBlock.creationMins, 1)
        XCTAssertEqual(rootBlock.creationTicks, 0)
    }
}
