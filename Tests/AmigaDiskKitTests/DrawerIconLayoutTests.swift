import XCTest
@testable import AmigaDiskKit

/// DrawerData comes FIRST in a DiskObject's variable-length section, before the
/// images — not last, and it is 56 bytes (NewWindow 48 + dd_CurrentX/Y), not 88.
///
/// `walkDiskObject` had it last and 88 bytes, and nothing caught it: every icon
/// fixture in this suite is a TOOL icon, which has no DrawerData at all, so the
/// wrong branch was never taken. On a real drawer icon the images were parsed
/// starting *inside* DrawerData, which skewed every offset after them — so a
/// tool-type rewrite on a drawer icon wrote to the wrong place.
///
/// Checked against a real OS 3.2.3 install (A4000, 2026-08-24): in
/// `SYS:Programs.info`, `SYS:Utilities.info` and `SYS:Disk.info` the Image1
/// header at 78+56=134 reads 8x8x1, 8x8x1 and 36x17x2. Read at 78 instead, all
/// three report a depth of −1.
final class DrawerIconLayoutTests: XCTestCase {

    /// A structurally real DRAWER icon: header + DrawerData + one 8x8x1 image
    /// + ToolTypes.
    private func makeDrawerInfo(toolTypes: [String]) -> Data {
        var d = Data(count: 78)
        d[0] = 0xE3; d[1] = 0x10                       // magic
        func putBE32(_ v: UInt32, _ at: Int) {
            d[at] = UInt8(v >> 24); d[at+1] = UInt8((v >> 16) & 0xFF)
            d[at+2] = UInt8((v >> 8) & 0xFF); d[at+3] = UInt8(v & 0xFF)
        }
        putBE32(0x64, 0x16)                            // GadgetRender present
        d[0x30] = 2                                    // type = drawer
        if !toolTypes.isEmpty { putBE32(0x64, 0x36) }
        putBE32(0x64, 0x42)                            // do_DrawerData present

        d += Data(count: 56)                           // DrawerData, FIRST

        var img = Data(count: 20)                      // 8x8x1
        img[4] = 0; img[5] = 8
        img[6] = 0; img[7] = 8
        img[8] = 0; img[9] = 1
        d += img
        d += Data(repeating: 0xAA, count: 2 * 8)

        if !toolTypes.isEmpty {
            let n = UInt32((toolTypes.count + 1) * 4)
            d += Data([UInt8(n >> 24), UInt8((n >> 16) & 0xFF),
                       UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            for tt in toolTypes {
                let bytes = Array(tt.utf8) + [0]
                d += Data([UInt8(bytes.count >> 24), UInt8((bytes.count >> 16) & 0xFF),
                           UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)])
                d += Data(bytes)
            }
        }
        return d
    }

    private func tmp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawericon-\(UUID().uuidString).info")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDrawerDataIsFoundAtSeventyEight() throws {
        let d = makeDrawerInfo(toolTypes: [])
        let off = try XCTUnwrap(IconPatcher.walkDiskObject(d))
        XCTAssertEqual(off.drawerDataStart, 78,
                       "DrawerData begins immediately after the 78-byte header")
    }

    func testToolTypesOnADrawerIconAreFoundAfterTheImage() throws {
        // 78 header + 56 DrawerData + 20 image header + 16 pixels = 170.
        let d = makeDrawerInfo(toolTypes: ["A=1", "B=2"])
        let off = try XCTUnwrap(IconPatcher.walkDiskObject(d))
        XCTAssertEqual(off.toolTypesStart, 170,
                       "walking past DrawerData then the image lands on ToolTypes")
        XCTAssertEqual(off.toolTypesEnd, d.count)
    }

    func testToolTypesRoundTripOnADrawerIcon() throws {
        // The failure the offset bug actually produced: an edit on a drawer
        // icon wrote into the wrong place and corrupted the file.
        let url = try tmp(makeDrawerInfo(toolTypes: ["OLD=1"]))
        let listURL = url.deletingLastPathComponent()
            .appendingPathComponent("tt-\(UUID().uuidString).txt")
        try "NEW=2\nEXTRA=3\n".write(to: listURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: listURL) }

        try IconPatcher.importToolTypes(infoPath: url.path, inputPath: listURL.path)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(after[0], 0xE3, "magic survives the edit")
        XCTAssertEqual(after[0x30], 2, "still a drawer")

        let off = try XCTUnwrap(IconPatcher.walkDiskObject(after))
        XCTAssertEqual(off.drawerDataStart, 78)
        XCTAssertEqual(off.toolTypesStart, 170, "the image was not moved or misread")

        let out = url.deletingLastPathComponent()
            .appendingPathComponent("out-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        try IconPatcher.exportToolTypes(infoPath: url.path, outputPath: out.path)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("NEW=2"), "got: \(text)")
        XCTAssertTrue(text.contains("EXTRA=3"), "got: \(text)")
        XCTAssertFalse(text.contains("OLD=1"))
    }

    func testToolIconStillHasNoDrawerData() throws {
        var d = makeDrawerInfo(toolTypes: [])
        d[0x30] = 3                                    // tool
        for i in 0x42..<0x46 { d[i] = 0 }              // no DrawerData pointer
        let off = try XCTUnwrap(IconPatcher.walkDiskObject(d))
        XCTAssertNil(off.drawerDataStart)
    }
}
