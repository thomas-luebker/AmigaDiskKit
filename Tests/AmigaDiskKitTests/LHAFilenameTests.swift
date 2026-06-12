import XCTest
@testable import AmigaDiskKit

/// LHA header filename parsing.
final class LHAFilenameTests: XCTestCase {

    /// Builds a minimal level-0 LHA archive with one stored (-lh0-) member.
    /// The name field carries the raw bytes as given (Amiga LhA appends the
    /// file note after a NUL inside the name field).
    private func makeLevel0Archive(nameField: [UInt8], content: [UInt8]) -> Data {
        var d = Data()
        let headerSize = 20 + nameField.count + 2  // pos+2 through end of CRC
        d.append(UInt8(headerSize))
        d.append(0)                                 // checksum (not verified by parser)
        d.append(contentsOf: Array("-lh0-".utf8))   // method
        d.append(contentsOf: le32(UInt32(content.count)))  // compressed size
        d.append(contentsOf: le32(UInt32(content.count)))  // original size
        d.append(contentsOf: [0, 0, 0, 0])          // time
        d.append(0x20)                              // attribute
        d.append(0x00)                              // header level 0
        d.append(UInt8(nameField.count))
        d.append(contentsOf: nameField)
        d.append(contentsOf: [0, 0])                // crc16 (unused here)
        d.append(contentsOf: content)
        d.append(0)                                 // archive terminator
        return d
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    func testLevel0FilenameTruncatesAtAmigaFileNote() throws {
        // Real-world case (Aminet comm/tcp/MiniFTP.lha): name field is
        // "MiniFTP.info\0PiDisk" — "PiDisk" is the Amiga file note.
        var nameField = Array("MiniFTP.info".utf8)
        nameField.append(0x00)
        nameField.append(contentsOf: Array("PiDisk".utf8))

        let data = makeLevel0Archive(nameField: nameField, content: [0x78])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lha-filenote-\(UUID().uuidString).lha")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try LHAArchive(url: url)
        XCTAssertEqual(archive.members.count, 1)
        XCTAssertEqual(archive.members.first?.path, "MiniFTP.info")
    }

    func testLevel0PlainFilenameUnchanged() throws {
        let data = makeLevel0Archive(nameField: Array("ReadMe.txt".utf8), content: [0x78])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lha-plain-\(UUID().uuidString).lha")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try LHAArchive(url: url)
        XCTAssertEqual(archive.members.first?.path, "ReadMe.txt")
    }
}
