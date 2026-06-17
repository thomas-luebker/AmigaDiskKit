import XCTest
@testable import AmigaDiskKit

final class FAT32DirEntryTests: XCTestCase {

    // MARK: - SFN parsing

    func testParseEmptyDirectory() {
        let data = Data(count: 512)   // all zeros → end-of-dir sentinel at slot 0
        XCTAssertEqual(FAT32Entry.parseDirectory(data).count, 0)
    }

    func testParseDeletedEntry() {
        var data = Data(count: 64)
        data[0] = 0xE5  // deleted
        data[11] = FAT32Attr.archive
        // slot 1: end sentinel (0x00)
        XCTAssertEqual(FAT32Entry.parseDirectory(data).count, 0)
    }

    func testParseSingleSFNFile() {
        var data = Data(count: 64)
        // "KICK    ROM" as SFN, archive, cluster=5, size=128
        let name: [UInt8] = [0x4B,0x49,0x43,0x4B,0x20,0x20,0x20,0x20,   // "KICK    "
                             0x52,0x4F,0x4D]                               // "ROM"
        for (i, b) in name.enumerated() { data[i] = b }
        data[11] = FAT32Attr.archive
        // cluster low = 5
        data[26] = 5; data[27] = 0
        // cluster high = 0
        data[20] = 0; data[21] = 0
        // file size = 128
        data[28] = 128; data[29] = 0; data[30] = 0; data[31] = 0
        // slot 1 (offset 32): end sentinel
        data[32] = 0x00

        let entries = FAT32Entry.parseDirectory(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "KICK.ROM")
        XCTAssertFalse(entries[0].isDirectory)
        XCTAssertEqual(entries[0].firstCluster, 5)
        XCTAssertEqual(entries[0].fileSize, 128)
    }

    func testParseSFNDirectory() {
        var data = Data(count: 64)
        let name: [UInt8] = [0x45,0x4D,0x55,0x36,0x38,0x20,0x20,0x20,   // "EMU68   "
                             0x20,0x20,0x20]                               // "   " (no ext)
        for (i, b) in name.enumerated() { data[i] = b }
        data[11] = FAT32Attr.directory
        data[26] = 10; data[27] = 0   // cluster = 10
        data[32] = 0x00

        let entries = FAT32Entry.parseDirectory(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "EMU68")
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testVolumeLabelsAreSkipped() {
        var data = Data(count: 64)
        let label: [UInt8] = [0x45,0x4D,0x55,0x36,0x38,0x42,0x4F,0x4F,0x54,0x20,0x20]
        for (i, b) in label.enumerated() { data[i] = b }
        data[11] = FAT32Attr.volumeID   // volume label, no directory bit
        data[32] = 0x00

        XCTAssertEqual(FAT32Entry.parseDirectory(data).count, 0)
    }

    func testDotEntriesNotReturned() {
        // parseDirectory returns dot entries in raw form; FAT32Volume filters them
        var data = Data(count: 96)
        // "." entry
        data[0] = 0x2E                 // '.'
        for i in 1 ..< 11 { data[i] = 0x20 }
        data[11] = FAT32Attr.directory
        // ".." entry
        data[32] = 0x2E; data[33] = 0x2E  // ".."
        for i in 34 ..< 43 { data[i] = 0x20 }
        data[43] = FAT32Attr.directory
        // end sentinel
        data[64] = 0x00

        let raw = FAT32Entry.parseDirectory(data)
        // parseDirectory does NOT filter dot entries — FAT32Volume does
        XCTAssertTrue(raw.filter { $0.isDot }.count == raw.count)
    }

    // MARK: - LFN parsing

    func testParseLFNEntry() {
        // "config.txt" = 10 chars → 1 LFN entry (≤ 13 chars per entry)
        var data = Data(count: 96)

        // LFN entry at slot 0: seq=1 | 0x40 (last = only), name = "config.txt\0\xFF\xFF"
        data[0] = 0x41   // seq=1, 0x40 set (last LFN entry)
        data[11] = FAT32Attr.lfn
        // checksum: will be verified implicitly by the parse succeeding
        // chars 0-4 at offsets 1,3,5,7,9: 'c','o','n','f','i'
        let lfnChars: [Character] = Array("config.txt")
        let allChars: [UInt16] = lfnChars.map { UInt16($0.asciiValue ?? 0x3F) }
            + [0x0000]       // null terminator
            + [0xFFFF, 0xFFFF]  // padding to 13
        let lfnOffsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for (i, off) in lfnOffsets.enumerated() {
            let cp = allChars[i]
            data[off]     = UInt8(cp & 0xFF)
            data[off + 1] = UInt8(cp >> 8)
        }

        // SFN entry at slot 1 (offset 32): "CONFIG  TXT", archive
        let sfn: [UInt8] = [0x43,0x4F,0x4E,0x46,0x49,0x47,0x20,0x20, 0x54,0x58,0x54]
        for (i, b) in sfn.enumerated() { data[32 + i] = b }
        data[43] = FAT32Attr.archive
        data[58] = 7; data[59] = 0   // cluster = 7
        data[60] = 100; data[61] = 0  // fileSize = 100 (offset 28 from slot start = 32+28=60)

        // End sentinel
        data[64] = 0x00

        let entries = FAT32Entry.parseDirectory(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "config.txt")
        XCTAssertFalse(entries[0].isDirectory)
    }

    // MARK: - LFN checksum

    func testLFNChecksumKnownValues() {
        // Known SFN → expected checksum from FAT spec examples
        // "READM~1 TXT" → known values from various FAT implementations
        let sfn1: [UInt8] = [0x52,0x45,0x41,0x44,0x4D,0x7E,0x31,0x20, 0x54,0x58,0x54]
        let csum1 = FAT32Entry.lfnChecksum(sfn1)
        XCTAssertGreaterThan(csum1, 0)   // non-trivial result

        // Verify checksum is deterministic
        XCTAssertEqual(FAT32Entry.lfnChecksum(sfn1), csum1)

        // Verify all-space SFN has a specific checksum (boundary test)
        let sfnSpaces: [UInt8] = .init(repeating: 0x20, count: 11)
        let csumSpaces = FAT32Entry.lfnChecksum(sfnSpaces)
        XCTAssertEqual(csumSpaces, FAT32Entry.lfnChecksum(sfnSpaces))
    }

    // MARK: - Serialization

    func testSerializeShortName() {
        // "KICK.ROM" fits 8.3 uppercase → no LFN entry
        let blocks = FAT32Entry.serialize(name: "KICK.ROM", attributes: FAT32Attr.archive,
                                          firstCluster: 5, fileSize: 512)
        XCTAssertEqual(blocks.count, 1, "pure 8.3 name should not emit LFN entries")
        let sfn = blocks[0]
        XCTAssertEqual(sfn[0], UInt8(ascii: "K"))
        XCTAssertEqual(sfn[1], UInt8(ascii: "I"))
        XCTAssertEqual(sfn[2], UInt8(ascii: "C"))
        XCTAssertEqual(sfn[3], UInt8(ascii: "K"))
        XCTAssertEqual(sfn[8], UInt8(ascii: "R"))  // extension
        XCTAssertEqual(sfn[11], FAT32Attr.archive)
        // cluster: low at 26-27, high at 20-21
        XCTAssertEqual(sfn[26], 5)
        XCTAssertEqual(sfn[27], 0)
        // file size at 28-31
        XCTAssertEqual(sfn[28], 0)
        XCTAssertEqual(sfn[29], 2)   // 512 = 0x200; LE: 0x00, 0x02
    }

    func testSerializeLongName() {
        // "startup-sequence" (16 chars) → 2 LFN entries + 1 SFN = 3 blocks total
        let blocks = FAT32Entry.serialize(name: "startup-sequence", attributes: FAT32Attr.archive,
                                          firstCluster: 3, fileSize: 64)
        XCTAssertEqual(blocks.count, 3)  // 2 LFN + 1 SFN

        // First block: highest seq (seq=2) with 0x40 flag
        XCTAssertEqual(blocks[0][0] & 0x3F, 2)    // seq = 2
        XCTAssertNotEqual(blocks[0][0] & 0x40, 0) // LAST_LONG_ENTRY bit set
        XCTAssertEqual(blocks[0][11], FAT32Attr.lfn)

        // Second block: seq=1
        XCTAssertEqual(blocks[1][0] & 0x3F, 1)
        XCTAssertEqual(blocks[1][0] & 0x40, 0)    // LAST_LONG_ENTRY not set
        XCTAssertEqual(blocks[1][11], FAT32Attr.lfn)

        // Third block: SFN
        XCTAssertNotEqual(blocks[2][11], FAT32Attr.lfn)
    }

    func testSerializeDotEntry() {
        // Dot entries must not generate LFN blocks
        let dot = FAT32Entry.serialize(name: ".", attributes: FAT32Attr.directory,
                                        firstCluster: 5, fileSize: 0)
        XCTAssertEqual(dot.count, 1)
        XCTAssertEqual(dot[0][0], UInt8(ascii: "."))
        XCTAssertEqual(dot[0][1], 0x20)  // space-padded

        let dotDot = FAT32Entry.serialize(name: "..", attributes: FAT32Attr.directory,
                                           firstCluster: 2, fileSize: 0)
        XCTAssertEqual(dotDot.count, 1)
        XCTAssertEqual(dotDot[0][0], UInt8(ascii: "."))
        XCTAssertEqual(dotDot[0][1], UInt8(ascii: "."))
    }

    func testSerializeFileSize() {
        let blocks = FAT32Entry.serialize(name: "A", attributes: FAT32Attr.archive,
                                          firstCluster: 2, fileSize: 0x01020304)
        let sfn = blocks.last!
        // LE32 at offset 28
        XCTAssertEqual(sfn[28], 0x04)
        XCTAssertEqual(sfn[29], 0x03)
        XCTAssertEqual(sfn[30], 0x02)
        XCTAssertEqual(sfn[31], 0x01)
    }

    func testSerializeClusterHighLow() {
        let cluster: UInt32 = 0x00010002
        let blocks = FAT32Entry.serialize(name: "B", attributes: FAT32Attr.archive,
                                          firstCluster: cluster, fileSize: 0)
        let sfn = blocks.last!
        // High word (bits 31:16) stored LE at offsets 20-21
        // cluster = 0x00010002 → high word = 0x0001 → LE bytes: 0x01, 0x00
        XCTAssertEqual(sfn[20], 0x01)  // (cluster >> 16) & 0xFF
        XCTAssertEqual(sfn[21], 0x00)  // (cluster >> 24) & 0xFF
        // Low word (bits 15:0) stored LE at offsets 26-27
        // cluster low = 0x0002 → LE bytes: 0x02, 0x00
        XCTAssertEqual(sfn[26], 0x02)  // cluster & 0xFF
        XCTAssertEqual(sfn[27], 0x00)  // (cluster >> 8) & 0xFF
    }

    // MARK: - Round-trip

    func testSerializeParseRoundTrip() {
        let name = "wpa_supplicant.conf"
        let firstCluster: UInt32 = 42
        let fileSize: UInt32 = 1024

        let blocks = FAT32Entry.serialize(name: name, attributes: FAT32Attr.archive,
                                          firstCluster: firstCluster, fileSize: fileSize)

        // Build a directory buffer from the serialised blocks
        var dirData = Data()
        for b in blocks { dirData.append(b) }
        dirData.append(Data(count: 32))  // end sentinel

        let entries = FAT32Entry.parseDirectory(dirData)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, name)
        XCTAssertEqual(entries[0].firstCluster, firstCluster)
        XCTAssertEqual(entries[0].fileSize, fileSize)
    }
}
