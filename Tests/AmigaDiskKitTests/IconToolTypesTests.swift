import XCTest
@testable import AmigaDiskKit

/// The icon-editing path the Disk Browser exposes: read metadata, rewrite
/// tool types / default tool / stack, read it back. Writes go through the
/// SAME IconPatcher the build engine uses, so a regression here would also
/// break HDToolBox's SCSI_DEVICE_NAME patching.
final class IconToolTypesTests: XCTestCase {

    /// Minimal but structurally real DiskObject: header + one 8x8x1 image +
    /// DefaultTool + two ToolTypes.
    private func makeInfo(defaultTool: String?, toolTypes: [String]) -> Data {
        var d = Data(count: 78)
        d[0] = 0xE3; d[1] = 0x10                       // magic
        func putBE32(_ v: UInt32, _ at: Int) {
            d[at] = UInt8(v >> 24); d[at+1] = UInt8((v >> 16) & 0xFF)
            d[at+2] = UInt8((v >> 8) & 0xFF); d[at+3] = UInt8(v & 0xFF)
        }
        putBE32(0x64, 0x16)                            // GadgetRender present
        d[0x30] = 3                                    // type = tool
        if defaultTool != nil { putBE32(0x64, 0x32) }
        if !toolTypes.isEmpty { putBE32(0x64, 0x36) }
        putBE32(4096, 0x4A)                            // stack

        // Image: 20-byte header, 8x8x1 → 2 bytes/row * 8 rows
        var img = Data(count: 20)
        img[4] = 0; img[5] = 8                         // width 8
        img[6] = 0; img[7] = 8                         // height 8
        img[8] = 0; img[9] = 1                         // depth 1
        d += img
        d += Data(repeating: 0xAA, count: 2 * 8)

        if let t = defaultTool {
            let bytes = Array(t.utf8) + [0]
            var s = Data(); s += Data([UInt8(bytes.count >> 24), UInt8((bytes.count >> 16) & 0xFF),
                                       UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)])
            s += Data(bytes); d += s
        }
        if !toolTypes.isEmpty {
            let n = UInt32((toolTypes.count + 1) * 4)
            d += Data([UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            for tt in toolTypes {
                let bytes = Array(tt.utf8) + [0]
                d += Data([UInt8(bytes.count >> 24), UInt8((bytes.count >> 16) & 0xFF),
                           UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)])
                d += Data(bytes)
            }
        }
        return d
    }

    private func tmp(_ data: Data, _ name: String = "test.info") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icontt-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testParsesMetadata() throws {
        let url = try tmp(makeInfo(defaultTool: "SYS:Utilities/MultiView",
                                   toolTypes: ["CX_POPUP=YES", "DONOTWAIT"]))
        let meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertEqual(meta.type, .tool)
        XCTAssertEqual(meta.defaultTool, "SYS:Utilities/MultiView")
        XCTAssertEqual(meta.toolTypes, ["CX_POPUP=YES", "DONOTWAIT"])
        XCTAssertEqual(meta.stackSize, 4096)
    }

    func testRewriteToolTypesGrowAndShrink() throws {
        let url = try tmp(makeInfo(defaultTool: "C:Foo", toolTypes: ["A=1"]))
        let list = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: list) }

        // grow
        try "SCSI_DEVICE_NAME=scsi.device\nUNIT=0\nLONGER=value-here\n"
            .write(to: list, atomically: true, encoding: .isoLatin1)
        try IconPatcher.importToolTypes(infoPath: url.path, inputPath: list.path)
        var meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertEqual(meta.toolTypes, ["SCSI_DEVICE_NAME=scsi.device", "UNIT=0", "LONGER=value-here"])
        XCTAssertEqual(meta.defaultTool, "C:Foo", "default tool must survive a tooltype rewrite")

        // shrink
        try "ONLY=one\n".write(to: list, atomically: true, encoding: .isoLatin1)
        try IconPatcher.importToolTypes(infoPath: url.path, inputPath: list.path)
        meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertEqual(meta.toolTypes, ["ONLY=one"])
        XCTAssertEqual(meta.stackSize, 4096)
    }

    func testSetDefaultToolReplaceAddRemove() throws {
        let url = try tmp(makeInfo(defaultTool: "C:Old", toolTypes: ["KEEP=me"]))

        try IconPatcher.setDefaultTool(path: url.path, tool: "SYS:Tools/IconEdit")
        var meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertEqual(meta.defaultTool, "SYS:Tools/IconEdit")
        XCTAssertEqual(meta.toolTypes, ["KEEP=me"], "tool types must survive a default-tool rewrite")

        try IconPatcher.setDefaultTool(path: url.path, tool: nil)
        meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertNil(meta.defaultTool)
        XCTAssertEqual(meta.toolTypes, ["KEEP=me"])

        try IconPatcher.setDefaultTool(path: url.path, tool: "C:New")
        meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertEqual(meta.defaultTool, "C:New")
        XCTAssertEqual(meta.toolTypes, ["KEEP=me"])
    }

    func testImageStillDecodesAfterEdits() throws {
        let url = try tmp(makeInfo(defaultTool: nil, toolTypes: ["X=1"]))
        let before = try XCTUnwrap(IconImageDecoder.decode(try Data(contentsOf: url)))
        try IconPatcher.setDefaultTool(path: url.path, tool: "C:Tool")
        let after = try XCTUnwrap(IconImageDecoder.decode(try Data(contentsOf: url)))
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)
        XCTAssertEqual(before.rgba, after.rgba, "imagery must be byte-identical after metadata edits")
    }

    func testStackPatch() throws {
        let url = try tmp(makeInfo(defaultTool: nil, toolTypes: []))
        try IconPatcher.patchStack(path: url.path, size: 65536)
        let meta = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: url)))
        XCTAssertEqual(meta.stackSize, 65536)
    }
}
