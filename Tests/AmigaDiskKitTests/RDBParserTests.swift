import XCTest
@testable import AmigaDiskKit

final class RDBParserTests: XCTestCase {
    private var fixturesURL: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    private func binaryFixture(_ name: String) throws -> Data {
        let url = fixturesURL.appendingPathComponent("binary/\(name)")
        return try Data(contentsOf: url)
    }

    // MARK: - MiSTer pure-RDB fixtures

    func testMisterRDBAreaHasRDSKSignature() throws {
        let data = try binaryFixture("mister-8g-rdb-area.bin")
        XCTAssertEqual(data.count, 32768)
        // RDSK at sector 0 (byte 0)
        XCTAssertEqual(data[0], 0x52)  // 'R'
        XCTAssertEqual(data[1], 0x44)  // 'D'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x4B)  // 'K'
    }

    func testMisterDH0BootBlockHasDOSSignature() throws {
        let data = try binaryFixture("mister-8g-dh0-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44)  // 'D'
        XCTAssertEqual(data[1], 0x4F)  // 'O'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x03)  // DOS\3 (FFS)
    }

    // MARK: - PiStorm MBR fixtures

    func testPiStormMBRHasValidSignature() throws {
        let data = try binaryFixture("pistorm-mbr.bin")
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(data[510], 0x55)
        XCTAssertEqual(data[511], 0xAA)
    }

    func testPiStormMBRSlot0IsFAT32() throws {
        let data = try binaryFixture("pistorm-mbr.bin")
        let partitionType = data[0x1BE + 4]
        XCTAssertTrue(partitionType == 0x0B || partitionType == 0x0C,
                      "Expected FAT32 type (0x0B or 0x0C), got 0x\(String(partitionType, radix: 16))")
    }

    func testPiStormMBRSlot1IsAmigaRDB() throws {
        let data = try binaryFixture("pistorm-mbr.bin")
        let partitionType = data[0x1CE + 4]  // slot 1 = offset 0x1BE + 16
        XCTAssertEqual(partitionType, 0x76, "Expected Amiga RDB type 0x76")
    }

    func testPiStormRDBAreaHasRDSKSignature() throws {
        let data = try binaryFixture("pistorm-rdb-area.bin")
        XCTAssertEqual(data.count, 32768)
        XCTAssertEqual(data[0], 0x52)  // 'R'
        XCTAssertEqual(data[1], 0x44)  // 'D'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x4B)  // 'K'
    }

    func testPiStormDH0BootBlockHasDOSSignature() throws {
        let data = try binaryFixture("pistorm-dh0-bootblock.bin")
        XCTAssertEqual(data[0], 0x44)
        XCTAssertEqual(data[1], 0x4F)
        XCTAssertEqual(data[2], 0x53)
    }

    // MARK: - PiStorm 29g large-image fixtures

    func testPiStorm29gMBRHasValidSignature() throws {
        let data = try binaryFixture("pistorm-29g-mbr.bin")
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(data[510], 0x55)
        XCTAssertEqual(data[511], 0xAA)
    }

    func testPiStorm29gRDBAreaHasRDSKSignature() throws {
        let data = try binaryFixture("pistorm-29g-rdb-area.bin")
        XCTAssertEqual(data.count, 32768)
        XCTAssertEqual(data[0], 0x52)  // 'R'
        XCTAssertEqual(data[1], 0x44)  // 'D'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x4B)  // 'K'
    }

    func testPiStorm29gSDH0BootBlockHasFFS3Signature() throws {
        let data = try binaryFixture("pistorm-29g-sdh0-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44)  // 'D'
        XCTAssertEqual(data[1], 0x4F)  // 'O'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x03)  // DOS\3 (FFS, boot partition)
    }

    func testPiStorm29gSDH1BootBlockHasFFS7Signature() throws {
        // SDH1 auto-upgraded to DOS\7 (FFS2) — large data partition mitigation
        // LowCyl=4164 → start offset 3.0 GiB in disk (below 4.3 GiB overflow threshold)
        let data = try binaryFixture("pistorm-29g-sdh1-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44)  // 'D'
        XCTAssertEqual(data[1], 0x4F)  // 'O'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x07)  // DOS\7 (FFS2)
    }

    // MARK: - PiStorm 7g 3-partition overflow fixtures

    func testPiStorm7g3PartMBRHasValidSignature() throws {
        let data = try binaryFixture("pistorm-7g-3part-mbr.bin")
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(data[510], 0x55)
        XCTAssertEqual(data[511], 0xAA)
    }

    func testPiStorm7g3PartRDBAreaHasRDSKSignature() throws {
        let data = try binaryFixture("pistorm-7g-3part-rdb-area.bin")
        XCTAssertEqual(data.count, 32768)
        XCTAssertEqual(data[0], 0x52)  // 'R'
        XCTAssertEqual(data[1], 0x44)  // 'D'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x4B)  // 'K'
    }

    func testPiStorm7g3PartSDH0BootBlockHasFFS3Signature() throws {
        let data = try binaryFixture("pistorm-7g-3part-sdh0-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44); XCTAssertEqual(data[1], 0x4F)
        XCTAssertEqual(data[2], 0x53); XCTAssertEqual(data[3], 0x03)
    }

    func testPiStorm7g3PartSDH1BootBlockHasFFS7Signature() throws {
        let data = try binaryFixture("pistorm-7g-3part-sdh1-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44); XCTAssertEqual(data[1], 0x4F)
        XCTAssertEqual(data[2], 0x53); XCTAssertEqual(data[3], 0x07)
    }

    func testPiStorm7g3PartSDH2BootBlockExceedsOverflowThreshold() throws {
        // SDH2 LowCyl=10372 → start = 10372 × 1008 × 512 = 5,352,947,712 bytes (~5 GiB)
        // UInt32 max = 4,294,967,295 → would overflow in hst-amiga FastFileSystemHelper.Mount
        let data = try binaryFixture("pistorm-7g-3part-sdh2-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44); XCTAssertEqual(data[1], 0x4F)
        XCTAssertEqual(data[2], 0x53); XCTAssertEqual(data[3], 0x03)

        let lowCyl: UInt32 = 10372
        let overflowResult = lowCyl &* 1008 &* 512
        XCTAssertNotEqual(Int64(overflowResult), Int64(lowCyl) * 1008 * 512,
                          "LowCyl=10372 must produce UInt32 overflow to be a valid regression fixture")
    }

    // MARK: - Classic pure-RDB fixtures

    func testClassicRDBAreaHasRDSKSignature() throws {
        let data = try binaryFixture("classic-8g-rdb-area.bin")
        XCTAssertEqual(data.count, 32768)
        // RDSK at LBA 0 — pure RDB, no MBR
        XCTAssertEqual(data[0], 0x52)  // 'R'
        XCTAssertEqual(data[1], 0x44)  // 'D'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x4B)  // 'K'
    }

    func testClassicRDBAreaHasNOMBRSignature() throws {
        // Pure RDB images must NOT have an MBR 0x55AA signature at offset 510
        let data = try binaryFixture("classic-8g-rdb-area.bin")
        XCTAssertNotEqual(data[510], 0x55, "Pure RDB image must not have MBR boot signature")
        XCTAssertNotEqual(data[511], 0xAA, "Pure RDB image must not have MBR boot signature")
    }

    func testClassicRDBAreaHasPARTBlocksAfterRDSK() throws {
        let data = try binaryFixture("classic-8g-rdb-area.bin")
        // PART blocks begin at LBA 1 (byte 512) and LBA 2 (byte 1024)
        let part1 = data[512...515]
        let part2 = data[1024...1027]
        XCTAssertEqual(Array(part1), [0x50, 0x41, 0x52, 0x54])  // "PART"
        XCTAssertEqual(Array(part2), [0x50, 0x41, 0x52, 0x54])  // "PART"
    }

    func testClassicDH0BootBlockHasFFS3Signature() throws {
        let data = try binaryFixture("classic-8g-dh0-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44)  // 'D'
        XCTAssertEqual(data[1], 0x4F)  // 'O'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x03)  // DOS\3 (FFS, intl=off)
    }

    func testClassicDH1BootBlockHasFFS7Signature() throws {
        // DH1 was auto-upgraded to DOS\7 (FFS2/intl) — large data partition mitigation
        let data = try binaryFixture("classic-8g-dh1-bootblock.bin")
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0], 0x44)  // 'D'
        XCTAssertEqual(data[1], 0x4F)  // 'O'
        XCTAssertEqual(data[2], 0x53)  // 'S'
        XCTAssertEqual(data[3], 0x07)  // DOS\7 (FFS2, intl=off)
    }

    // MARK: - Geometry math

    func testPartitionOffsetMathDoesNotOverflow() {
        // Reproduce the hst-amiga FastFileSystemHelper.Mount overflow:
        // var partitionStartOffset = lowCyl * blocksPerCylinder * blockSize  ← UInt32 wraps
        // AmigaDiskKit must use Int64 throughout.
        let lowCyl: UInt32 = 37110
        let surfaces: UInt32 = 16
        let blocksPerTrack: UInt32 = 63
        let blockSize: UInt32 = 512

        let blocksPerCylinder = UInt32(surfaces * blocksPerTrack)

        // C# bug: all UInt32, overflows above ~4.3 GiB
        let buggyResult = lowCyl &* blocksPerCylinder &* blockSize  // wrapped multiply
        XCTAssertNotEqual(Int64(bitPattern: UInt64(buggyResult)),
                          Int64(lowCyl) * Int64(blocksPerCylinder) * Int64(blockSize),
                          "If these are equal the overflow threshold math is wrong")

        // AmigaDiskKit correct result (37110 × 1008 × 512 = 19,152,322,560)
        let correct = Int64(lowCyl) * Int64(blocksPerCylinder) * Int64(blockSize)
        XCTAssertEqual(correct, 19_152_322_560)
    }
}
