import XCTest
@testable import AmigaDiskKit

final class RDBWriterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDBWriterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - DiskGeometry

    func testDiskGeometryFromBytes() throws {
        // 4 GiB = 4 * 1024^3 = 4,294,967,296 bytes
        let size: Int64 = 4 * 1024 * 1024 * 1024
        let geo = try DiskGeometry(sizeBytes: size)
        // totalBlocks = 8388608; blocksPerCyl = 16*63 = 1008; cyls = 8388608/1008 = 8322
        XCTAssertEqual(geo.cylinders, 8322)
        XCTAssertEqual(geo.heads, 16)
        XCTAssertEqual(geo.sectors, 63)
        XCTAssertEqual(geo.blocksPerCylinder, 1008)
        XCTAssertEqual(geo.loCylinder, 2)
        XCTAssertEqual(geo.hiCylinder, 8321)
        XCTAssertEqual(geo.rdbBlockHi, 2015)  // 2*1008 - 1
    }

    // MaxTransfer/Mask (Classic --max-transfer/--mask). Default = Amiga stock;
    // a custom PartitionSpec value must land in the PART block at +0xB4/+0xB8.
    func testPartitionMaxTransferMaskDefaultAndCustom() throws {
        func partBlock(_ spec: PartitionSpec) throws -> Data {
            let url = tmpDir.appendingPathComponent("\(UUID().uuidString).hdf")
            try DiskBuilder.build(url: url, sizeBytes: 100 * 1024 * 1024,
                                  layout: .pureRDB(partitions: [spec]))
            let data = try Data(contentsOf: url)
            return data.subdata(in: (3 * 512)..<(3 * 512 + 512))  // PART @ slice LBA 3
        }
        let def = try partBlock(PartitionSpec(name: "DH0", dosType: KnownDosType.dos3))
        XCTAssertEqual(def.readBE32(at: 0xB4), 0x0001_FE00)
        XCTAssertEqual(def.readBE32(at: 0xB8), 0x7FFF_FFFE)

        let custom = try partBlock(PartitionSpec(name: "DH0", dosType: KnownDosType.dos3,
                                                 maxTransfer: 0x0001_0000, mask: 0xFFFF_FFFE))
        XCTAssertEqual(custom.readBE32(at: 0xB4), 0x0001_0000)
        XCTAssertEqual(custom.readBE32(at: 0xB8), 0xFFFF_FFFE)
    }

    func testDiskGeometryTooSmall() {
        // 2 cylinders would be rejected (minimum 3)
        let twoMiB: Int64 = 2 * 1008 * 512  // exactly 2 cylinders
        XCTAssertThrowsError(try DiskGeometry(sizeBytes: twoMiB)) { error in
            guard case AmigaDiskError.invalidGeometry = error else {
                XCTFail("Expected invalidGeometry, got \(error)")
                return
            }
        }
    }

    // MARK: - Checksum

    func testRDSKChecksumValid() throws {
        let geo = try DiskGeometry(sizeBytes: 256 * 1024 * 1024)
        let rdsk = RigidDiskBlock(geometry: geo)
        let data = rdsk.serialize()
        XCTAssertTrue(verifyAmigaBlockChecksum(data), "RDSK block checksum must be valid after serialize")
    }

    func testPARTChecksumValid() throws {
        let geo = try DiskGeometry(sizeBytes: 256 * 1024 * 1024)
        let part = PartitionBlock(name: "DH0", dosType: KnownDosType.dos3,
                                  lowCyl: 2, highCyl: 100, geometry: geo,
                                  isBootable: true)
        let data = part.serialize()
        XCTAssertTrue(verifyAmigaBlockChecksum(data), "PART block checksum must be valid after serialize")
    }

    // MARK: - MBR round-trip

    func testMBRSerializeRoundTrip() throws {
        let entries: [MBREntrySpec] = [
            MBREntrySpec(status: 0x80, partitionType: 0x0C, lbaStart: 2048, lbaSectors: 2_095_105),
            MBREntrySpec(status: 0x00, partitionType: 0x76, lbaStart: 2_097_153, lbaSectors: 6_291_456),
        ]
        let block = MBRPartitionTable.serialize(entries: entries)
        XCTAssertEqual(block.count, 512)
        let mbr = try MBRPartitionTable(data: block)
        XCTAssertEqual(mbr.partitions[0].status, 0x80)
        XCTAssertEqual(mbr.partitions[0].partitionType, 0x0C)
        XCTAssertEqual(mbr.partitions[0].lbaStart, 2048)
        XCTAssertEqual(mbr.partitions[0].lbaSectors, 2_095_105)
        XCTAssertEqual(mbr.partitions[1].partitionType, 0x76)
        XCTAssertEqual(mbr.partitions[1].lbaStart, 2_097_153)
        // Empty slots 2 and 3
        XCTAssertTrue(mbr.partitions[2].isEmpty)
        XCTAssertTrue(mbr.partitions[3].isEmpty)
    }

    // MARK: - Pure-RDB round-trip

    func testRoundTripPureRDB_SinglePartition() throws {
        let imageURL = tmpDir.appendingPathComponent("pure-rdb-1part.img")
        let sizeBytes: Int64 = 256 * 1024 * 1024  // 256 MiB

        let specs = [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos3, isBootable: true, bootPriority: 1),
        ]
        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes, layout: .pureRDB(partitions: specs))

        // Parse back
        let device = try BlockDevice(url: imageURL)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)

        XCTAssertEqual(rdb.cylinders, (try DiskGeometry(sizeBytes: sizeBytes)).cylinders)
        XCTAssertEqual(rdb.heads, 16)
        XCTAssertEqual(rdb.sectors, 63)
        XCTAssertEqual(rdb.loCylinder, 2)
        XCTAssertEqual(rdb.partitionBlocks.count, 1)

        let part = rdb.partitionBlocks[0]
        XCTAssertEqual(part.driveName, "DH0")
        XCTAssertEqual(part.dosType, KnownDosType.dos3)
        XCTAssertEqual(part.lowCyl, 2)
        XCTAssertEqual(part.highCyl, rdb.hiCylinder)
        XCTAssertTrue(part.isBootable)
        XCTAssertEqual(part.bootPriority, 1)
        XCTAssertEqual(part.nextPartitionBlock, 0xFFFFFFFF)
    }

    func testRoundTripPureRDB_TwoPartitions() throws {
        let imageURL = tmpDir.appendingPathComponent("pure-rdb-2part.img")
        let sizeBytes: Int64 = 512 * 1024 * 1024  // 512 MiB

        let geo = try DiskGeometry(sizeBytes: sizeBytes)
        let dh0Cyls: UInt32 = 100
        let specs = [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos3,
                          sizeCylinders: dh0Cyls, isBootable: true),
            PartitionSpec(name: "DH1", dosType: KnownDosType.dos7),
        ]
        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes, layout: .pureRDB(partitions: specs))

        let device = try BlockDevice(url: imageURL)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)

        XCTAssertEqual(rdb.partitionBlocks.count, 2)
        let dh0 = rdb.partitionBlocks[0]
        let dh1 = rdb.partitionBlocks[1]

        XCTAssertEqual(dh0.driveName, "DH0")
        XCTAssertEqual(dh0.lowCyl, geo.loCylinder)
        XCTAssertEqual(dh0.highCyl, geo.loCylinder + dh0Cyls - 1)
        XCTAssertTrue(dh0.isBootable)

        XCTAssertEqual(dh1.driveName, "DH1")
        XCTAssertEqual(dh1.lowCyl, geo.loCylinder + dh0Cyls)
        XCTAssertEqual(dh1.highCyl, geo.hiCylinder)
        XCTAssertFalse(dh1.isBootable)
        XCTAssertEqual(dh1.nextPartitionBlock, 0xFFFFFFFF)
    }

    // MARK: - MBR + RDB round-trip

    func testRoundTripMBRPlusRDB() throws {
        let imageURL = tmpDir.appendingPathComponent("mbr-rdb.img")
        // 4 GiB PiStorm-style image
        let sizeBytes: Int64 = 4 * 1024 * 1024 * 1024
        let fatStart: UInt32   = 2048
        let fatCount: UInt32   = 2_095_105
        let rdbStart: UInt32   = 2_097_153

        let specs = [
            PartitionSpec(name: "SDH0", dosType: KnownDosType.dos3,
                          sizeCylinders: 2000, isBootable: true, bootPriority: 1),
            PartitionSpec(name: "SDH1", dosType: KnownDosType.dos7),
        ]

        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes,
                              layout: .mbrPlusRDB(fatStartLBA: fatStart,
                                                  fatSectorCount: fatCount,
                                                  rdbStartLBA: rdbStart,
                                                  partitions: specs))

        let device = try BlockDevice(url: imageURL)

        // Verify MBR
        let mbrData = try device.readBlock(at: 0)
        let mbr = try MBRPartitionTable(data: mbrData)
        XCTAssertEqual(mbr.partitions[0].lbaStart, fatStart)
        XCTAssertEqual(mbr.partitions[0].lbaSectors, fatCount)
        XCTAssertEqual(mbr.partitions[0].partitionType, 0x0C)
        XCTAssertEqual(mbr.partitions[1].lbaStart, rdbStart)
        XCTAssertEqual(mbr.partitions[1].partitionType, 0x76)

        // Verify RDB in slice
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: Int64(rdbStart))
        XCTAssertEqual(rdb.partitionBlocks.count, 2)
        XCTAssertEqual(rdb.partitionBlocks[0].driveName, "SDH0")
        XCTAssertEqual(rdb.partitionBlocks[1].driveName, "SDH1")
        XCTAssertEqual(rdb.partitionBlocks[0].dosType, KnownDosType.dos3)
        XCTAssertEqual(rdb.partitionBlocks[1].dosType, KnownDosType.dos7)
    }

    // MARK: - High-cylinder overflow safety

    func testPartitionAtHighCylinderNoOverflow() throws {
        // Simulate SDH2 fixture: LowCyl=10372 on a 3-partition PiStorm layout.
        // byteOffset must not overflow Int64.
        let geo = try DiskGeometry(sizeBytes: 32 * 1024 * 1024 * 1024)  // 32 GiB
        let part = PartitionBlock(name: "SDH2", dosType: KnownDosType.dos7,
                                  lowCyl: 10_372, highCyl: 30_000, geometry: geo)
        let data = part.serialize()
        XCTAssertTrue(verifyAmigaBlockChecksum(data))

        // Round-trip: parse the block back and verify cylinder values.
        let parsed = try PartitionBlock(data: data, lba: 5)
        XCTAssertEqual(parsed.lowCyl, 10_372)
        XCTAssertEqual(parsed.highCyl, 30_000)
        XCTAssertEqual(parsed.driveName, "SDH2")

        // byteOffset uses Int64 — must not crash or overflow.
        let rdsk = RigidDiskBlock(geometry: geo)
        let startOffset = part.startByteOffset(rdb: rdsk)
        XCTAssertGreaterThan(startOffset, 0)
        // 10372 * 1008 * 512 = 5,352,947,712 ≈ 5 GiB — within Int64
        XCTAssertEqual(startOffset, Int64(10_372) * 1008 * 512)
    }

    // MARK: - PartitionSpec last-fills-remaining

    func testLastPartitionFillsRemaining() throws {
        let imageURL = tmpDir.appendingPathComponent("fills-remaining.img")
        let sizeBytes: Int64 = 256 * 1024 * 1024
        let geo = try DiskGeometry(sizeBytes: sizeBytes)

        let specs = [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos3, sizeCylinders: 50),
            PartitionSpec(name: "DH1", dosType: KnownDosType.dos3, sizeCylinders: 50),
            PartitionSpec(name: "DH2", dosType: KnownDosType.dos7),  // sizeCylinders=0 → fill
        ]
        try DiskBuilder.build(url: imageURL, sizeBytes: sizeBytes, layout: .pureRDB(partitions: specs))

        let device = try BlockDevice(url: imageURL)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        XCTAssertEqual(rdb.partitionBlocks.count, 3)
        XCTAssertEqual(rdb.partitionBlocks[2].highCyl, geo.hiCylinder)
    }
}
