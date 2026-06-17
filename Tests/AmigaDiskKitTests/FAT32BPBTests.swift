import XCTest
@testable import AmigaDiskKit

final class FAT32BPBTests: XCTestCase {

    private var fixturesURL: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    private func binaryFixture(_ name: String) throws -> Data {
        let url = fixturesURL.appendingPathComponent("binary/\(name)")
        return try Data(contentsOf: url)
    }

    // MARK: - Fixture parsing (all three PiStorm images have identical FAT32 layout)

    func testParsePiStorm8g() throws {
        let data = try binaryFixture("pistorm-fat32-boot-sector.bin")
        let bpb = try FAT32BPB(data: data)

        XCTAssertEqual(bpb.bytesPerSector, 512)
        XCTAssertEqual(bpb.sectorsPerCluster, 8)
        XCTAssertEqual(bpb.reservedSectorCount, 32)
        XCTAssertEqual(bpb.fatCount, 2)
        XCTAssertEqual(bpb.totalSectors, 2_095_105)
        XCTAssertEqual(bpb.sectorsPerFAT, 2042)
        XCTAssertEqual(bpb.rootCluster, 2)
        XCTAssertEqual(bpb.fsInfoSector, 1)
        XCTAssertEqual(bpb.backupBootSector, 6)
        XCTAssertEqual(bpb.volumeLabel, "EMU68BOOT")
    }

    func testParsePiStorm29g() throws {
        let data = try binaryFixture("pistorm-29g-fat32-boot-sector.bin")
        let bpb = try FAT32BPB(data: data)
        // Identical layout to 8g — same 1 GB FAT32 partition.
        XCTAssertEqual(bpb.bytesPerSector, 512)
        XCTAssertEqual(bpb.sectorsPerCluster, 8)
        XCTAssertEqual(bpb.totalSectors, 2_095_105)
        XCTAssertEqual(bpb.sectorsPerFAT, 2042)
        XCTAssertEqual(bpb.rootCluster, 2)
        XCTAssertEqual(bpb.volumeLabel, "EMU68BOOT")
    }

    func testParsePiStorm7g3Part() throws {
        let data = try binaryFixture("pistorm-7g-3part-fat32-boot-sector.bin")
        let bpb = try FAT32BPB(data: data)
        XCTAssertEqual(bpb.bytesPerSector, 512)
        XCTAssertEqual(bpb.sectorsPerCluster, 8)
        XCTAssertEqual(bpb.totalSectors, 2_095_105)
        XCTAssertEqual(bpb.sectorsPerFAT, 2042)
        XCTAssertEqual(bpb.rootCluster, 2)
        XCTAssertEqual(bpb.volumeLabel, "EMU68BOOT")
    }

    // MARK: - Derived geometry

    func testDerivedGeometry() throws {
        let data = try binaryFixture("pistorm-fat32-boot-sector.bin")
        let bpb = try FAT32BPB(data: data)

        // 8 sectors × 512 bytes = 4096 bytes per cluster.
        XCTAssertEqual(bpb.bytesPerCluster, 4096)

        // First FAT starts right after reserved sectors.
        XCTAssertEqual(bpb.fatSectorOffset(fatIndex: 0), 32)
        // Second FAT follows immediately after the first.
        XCTAssertEqual(bpb.fatSectorOffset(fatIndex: 1), 32 + 2042)

        // Data region = reservedSectorCount + numFATs × sectorsPerFAT
        // = 32 + 2 × 2042 = 4116.
        XCTAssertEqual(bpb.dataRegionSector, 4116)

        // Root directory (cluster 2) is the very first data cluster.
        // Byte offset = 4116 × 512 = 2_107_392.
        XCTAssertEqual(bpb.clusterOffset(2), 2_107_392)

        // Cluster 3 is one cluster further: 2_107_392 + 4096 = 2_111_488.
        XCTAssertEqual(bpb.clusterOffset(3), 2_111_488)
    }

    func testClusterCount() throws {
        let data = try binaryFixture("pistorm-fat32-boot-sector.bin")
        let bpb = try FAT32BPB(data: data)
        // dataSectors = 2_095_105 − 4116 = 2_090_989; / 8 = 261_373 clusters.
        XCTAssertEqual(bpb.clusterCount, 261_373)
    }

    // MARK: - Validation errors

    func testRejectsBadSignature() {
        var data = Data(count: 512)
        data[510] = 0x00; data[511] = 0x00
        XCTAssertThrowsError(try FAT32BPB(data: data)) { error in
            guard case AmigaDiskError.invalidFAT32Signature = error else {
                XCTFail("expected invalidFAT32Signature, got \(error)"); return
            }
        }
    }

    func testRejectsDataTooShort() {
        let data = Data(count: 256)
        XCTAssertThrowsError(try FAT32BPB(data: data)) { error in
            guard case AmigaDiskError.readFailed = error else {
                XCTFail("expected readFailed, got \(error)"); return
            }
        }
    }

    func testRejectsFAT16Marker() throws {
        var data = try binaryFixture("pistorm-fat32-boot-sector.bin")
        // Set rootEntCnt to non-zero — marks it as FAT12/16.
        data[17] = 0x10; data[18] = 0x00   // rootEntCnt = 16
        XCTAssertThrowsError(try FAT32BPB(data: data)) { error in
            guard case AmigaDiskError.notFAT32 = error else {
                XCTFail("expected notFAT32, got \(error)"); return
            }
        }
    }

    func testRejectsInvalidSectorsPerCluster() throws {
        var data = try binaryFixture("pistorm-fat32-boot-sector.bin")
        data[13] = 0x03  // 3 — not a power of two
        XCTAssertThrowsError(try FAT32BPB(data: data)) { error in
            guard case AmigaDiskError.invalidFAT32BPB = error else {
                XCTFail("expected invalidFAT32BPB, got \(error)"); return
            }
        }
    }
}
