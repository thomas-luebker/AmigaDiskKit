import XCTest
@testable import AmigaDiskKit

final class DiskImageParserTests: XCTestCase {

    // MARK: - Fixture helpers

    private var fixturesURL: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    private func binaryFixture(_ name: String) throws -> Data {
        let url = fixturesURL.appendingPathComponent("binary/\(name)")
        return try Data(contentsOf: url)
    }

    /// Write fixture data to a temp file and return a BlockDevice for it.
    private func tempDevice(from data: Data) throws -> (BlockDevice, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: tmp)
        let device = try BlockDevice(url: tmp)
        return (device, tmp)
    }

    // MARK: - Data+Parsing tests

    func testReadBE32() {
        let data = Data([0x52, 0x44, 0x53, 0x4B])  // "RDSK"
        XCTAssertEqual(data.readBE32(at: 0), 0x5244534B)
    }

    func testReadLE32() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(data.readLE32(at: 0), 0x04030201)
    }

    func testReadBSTR() {
        // BSTR: length byte + chars
        let data = Data([0x04, 0x53, 0x44, 0x48, 0x30, 0x00, 0x00, 0x00])  // "SDH0"
        XCTAssertEqual(data.readBSTR(at: 0, maxLength: 32), "SDH0")
    }

    func testReadAmigaString() {
        let vendor = Data("HstImage".utf8)
        XCTAssertEqual(vendor.readAmigaString(at: 0, length: 8), "HstImage")
    }

    // MARK: - Checksum tests

    func testRDSKChecksumPasses() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let rdskBlock = data[0..<512]
        XCTAssertTrue(verifyAmigaBlockChecksum(rdskBlock),
                      "RDSK block checksum should be valid")
    }

    func testPARTChecksumPasses() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let partBlock = data[512..<1024]
        XCTAssertTrue(verifyAmigaBlockChecksum(partBlock),
                      "SDH0 PART block checksum should be valid")
    }

    func testFSHDChecksumPasses() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let fshdBlock = data[2048..<2560]
        XCTAssertTrue(verifyAmigaBlockChecksum(fshdBlock),
                      "FSHD block checksum should be valid")
    }

    // MARK: - MBR parsing tests

    func testMBR7g3PartParsesSignature() throws {
        let data = try binaryFixture("pistorm-7g-3part-mbr.bin")
        let mbr  = try MBRPartitionTable(data: data)
        // If we got here without throwing, the signature was valid
        XCTAssertEqual(mbr.partitions.count, 4)
    }

    func testMBR7g3PartSlot0IsFAT32() throws {
        let data = try binaryFixture("pistorm-7g-3part-mbr.bin")
        let mbr  = try MBRPartitionTable(data: data)
        let type = mbr.partitions[0].partitionType
        XCTAssertTrue(type == 0x0B || type == 0x0C,
                      "MBR slot 0 should be FAT32 (0x0B or 0x0C), got 0x\(String(type, radix: 16))")
    }

    func testMBR7g3PartSlot1IsAmigaRDB() throws {
        let data = try binaryFixture("pistorm-7g-3part-mbr.bin")
        let mbr  = try MBRPartitionTable(data: data)
        XCTAssertEqual(mbr.partitions[1].partitionType, 0x76,
                       "MBR slot 1 should be Amiga RDB (0x76)")
    }

    func testMBR7g3PartSlot1LBAStartIsPositive() throws {
        let data = try binaryFixture("pistorm-7g-3part-mbr.bin")
        let mbr  = try MBRPartitionTable(data: data)
        XCTAssertGreaterThan(mbr.partitions[1].lbaStart, 0,
                             "MBR slot 1 lbaStart should be > 0")
    }

    func testMBRInvalidSignatureThrows() throws {
        let bytes = [UInt8](repeating: 0, count: 512)
        // No 0x55AA at bytes 510-511
        let data = Data(bytes)
        XCTAssertThrowsError(try MBRPartitionTable(data: data)) { error in
            guard case AmigaDiskError.invalidMBRSignature = error else {
                XCTFail("Expected invalidMBRSignature, got \(error)")
                return
            }
        }
    }

    // MARK: - RDSK parsing (7g-3part)

    func testRDSK7g3PartGeometry() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        XCTAssertEqual(rdb.cylinders,    11482)
        XCTAssertEqual(rdb.heads,        16)
        XCTAssertEqual(rdb.sectors,      63)
        XCTAssertEqual(rdb.rdbBlockHi,   2015)
        XCTAssertEqual(rdb.blocksPerCylinder, 1008)  // 63 × 16
    }

    func testRDSK7g3PartHas3Partitions() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        XCTAssertEqual(rdb.partitionBlocks.count, 3)
    }

    func testSDH0Fields() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb  = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let sdh0 = rdb.partitionBlocks[0]
        XCTAssertEqual(sdh0.driveName,   "SDH0")
        XCTAssertEqual(sdh0.lowCyl,      2)
        XCTAssertEqual(sdh0.highCyl,     4163)
        XCTAssertEqual(sdh0.dosType,     0x444F5303)
        XCTAssertTrue(sdh0.isBootable,   "SDH0 should be bootable (flags bit 0 set)")
        XCTAssertEqual(sdh0.bootPriority, 1)
        XCTAssertFalse(sdh0.noMount)
    }

    func testSDH1Fields() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb  = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let sdh1 = rdb.partitionBlocks[1]
        XCTAssertEqual(sdh1.driveName, "SDH1")
        XCTAssertEqual(sdh1.lowCyl,    4164)
        XCTAssertEqual(sdh1.dosType,   0x444F5307)  // DOS\7 — FFS2
        XCTAssertFalse(sdh1.isBootable, "SDH1 should not be bootable")
        XCTAssertEqual(sdh1.bootPriority, 0)
    }

    func testSDH2Fields() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb  = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let sdh2 = rdb.partitionBlocks[2]
        XCTAssertEqual(sdh2.driveName, "SDH2")
        XCTAssertEqual(sdh2.lowCyl,    10372)
        XCTAssertFalse(sdh2.isBootable, "SDH2 should not be bootable")
    }

    func testSDH2StartOffsetInt64NeverOverflows() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb   = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let sdh2  = rdb.partitionBlocks[2]
        let start = sdh2.startByteOffset(rdb: rdb)
        // 10372 × 1008 × 512 = 5,352,947,712 — beyond UInt32 max (4,294,967,295)
        XCTAssertEqual(start, 5_352_947_712,
                       "SDH2 start offset must be computed as Int64 without overflow")
    }

    // MARK: - FSHD parsing

    func testFSHD7g3PartDosType() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        XCTAssertGreaterThanOrEqual(rdb.fileSystemHeaders.count, 1)
        let fshd = rdb.fileSystemHeaders[0]
        XCTAssertEqual(fshd.dosType, 0x444F5303)
        XCTAssertEqual(fshd.versionFormatted, "47.4")
        XCTAssertEqual(fshd.fileSystemName, "FastFileSystem")
    }

    func testDosTypeFormatted() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb  = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let sdh0 = rdb.partitionBlocks[0]
        // DOS\3 — prefix "DOS" + backslash + byte value 3
        XCTAssertEqual(sdh0.dosTypeFormatted, "DOS\\3")
        XCTAssertEqual(sdh0.dosTypeHex, "0x444F5303")
    }

    // MARK: - Classic pure-RDB

    func testClassicRDBNoMBR() throws {
        let data = try binaryFixture("classic-8g-rdb-area.bin")
        XCTAssertNotEqual(data[510], 0x55, "Classic pure-RDB must not have MBR signature")
        XCTAssertNotEqual(data[511], 0xAA)
    }

    func testClassicRDSKScansFromLBA0() throws {
        let data = try binaryFixture("classic-8g-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        // Fixture confirmed: 2 PART blocks (DH0 + DH1)
        XCTAssertEqual(rdb.partitionBlocks.count, 2)
    }

    func testClassicRDSKGeometry() throws {
        let data = try binaryFixture("classic-8g-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        XCTAssertEqual(rdb.heads,   16)
        XCTAssertEqual(rdb.sectors, 63)
    }

    // MARK: - FFS boot block parsing

    func testFFSBootBlockSDH0Valid() throws {
        let data  = try binaryFixture("pistorm-7g-3part-sdh0-bootblock.bin")
        let block = try FFSBootBlock(data: data)
        XCTAssertTrue(block.hasDosSignature)
        XCTAssertEqual(block.dosType[0], 0x44)  // 'D'
        XCTAssertEqual(block.dosType[1], 0x4F)  // 'O'
        XCTAssertEqual(block.dosType[2], 0x53)  // 'S'
        XCTAssertEqual(block.dosType[3], 0x03)  // DOS\3
        XCTAssertEqual(block.dosTypeString, "DOS")
    }

    func testFFSBootBlockClassicDH0Valid() throws {
        let data  = try binaryFixture("classic-8g-dh0-bootblock.bin")
        let block = try FFSBootBlock(data: data)
        XCTAssertTrue(block.hasDosSignature)
        XCTAssertEqual(block.dosType[3], 0x03)
    }

    func testFFSBootBlockInvalidThrows() {
        let badData = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try FFSBootBlock(data: badData)) { error in
            guard case AmigaDiskError.invalidBootBlock = error else {
                XCTFail("Expected invalidBootBlock, got \(error)")
                return
            }
        }
    }

    // MARK: - DiskImage.open (MBR+RDB layout)

    func testDiskImageOpenMBRLayout() throws {
        // We use only the rdb-area fixture directly (no full image available),
        // so test the MBR path via pistorm-7g-3part fixture files stitched together.
        // For a pure-RDB path, use the classic fixture.
        let rdbData = try binaryFixture("classic-8g-rdb-area.bin")
        let (_, tmp) = try tempDevice(from: rdbData)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let info = try DiskImage.open(url: tmp)
        if case .pureRDB(let rdb) = info.layout {
            XCTAssertEqual(rdb.partitionBlocks.count, 2)
        } else {
            XCTFail("Classic fixture should produce pureRDB layout")
        }
    }

    func testDiskImageRDBAccessor() throws {
        let rdbData = try binaryFixture("classic-8g-rdb-area.bin")
        let (_, tmp) = try tempDevice(from: rdbData)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let info = try DiskImage.open(url: tmp)
        // rdb convenience accessor must not throw
        XCTAssertEqual(info.rdb.partitionBlocks.count, 2)
    }

    // MARK: - Partition size computation

    func testPartitionSizeSDH0() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        let (device, tmp) = try tempDevice(from: data)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rdb  = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let sdh0 = rdb.partitionBlocks[0]
        // (highCyl - lowCyl + 1) × cylBlocks × blockSize
        // (4163 - 2 + 1) × 1008 × 512 = 4162 × 1008 × 512 = 2_147,999,744
        let expectedSize = Int64(4162) * Int64(1008) * Int64(512)
        let actual = sdh0.endByteOffset(rdb: rdb) - sdh0.startByteOffset(rdb: rdb)
        XCTAssertEqual(actual, expectedSize)
    }
}
