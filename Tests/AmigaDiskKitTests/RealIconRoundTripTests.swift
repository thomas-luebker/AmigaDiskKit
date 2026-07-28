import XCTest
@testable import AmigaDiskKit

/// Round-trip against a REAL OS 3.2 icon (HDToolBox.info extracted from a
/// built image). Env-gated: set AMIGADISKKIT_REAL_ICON to the file.
final class RealIconRoundTripTests: XCTestCase {
    func testRealIconEditPreservesEverythingElse() throws {
        guard let src = ProcessInfo.processInfo.environment["AMIGADISKKIT_REAL_ICON"],
              FileManager.default.fileExists(atPath: src) else {
            throw XCTSkip("set AMIGADISKKIT_REAL_ICON to a real .info")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("realicon-\(UUID().uuidString).info")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: work)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }

        let before = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: work)))
        let beforeImg = IconImageDecoder.decode(try Data(contentsOf: work))
        print("REAL ICON before: type=\(before.type?.displayName ?? "?") stack=\(before.stackSize) " +
              "defaultTool=\(before.defaultTool ?? "-") tooltypes=\(before.toolTypes)")

        let list = work.deletingLastPathComponent()
            .appendingPathComponent("tt-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: list) }
        let newTT = ["SCSI_DEVICE_NAME=uaehf.device", "UNIT=0", "EDITED_BY=AmigaImager"]
        try (newTT.map { $0 + "\n" }.joined()).write(to: list, atomically: true, encoding: .isoLatin1)

        try IconPatcher.importToolTypes(infoPath: work.path, inputPath: list.path)
        try IconPatcher.setDefaultTool(path: work.path, tool: "SYS:Tools/HDToolBox")
        try IconPatcher.patchStack(path: work.path, size: 32768)

        let after = try XCTUnwrap(IconMetadataParser.parse(try Data(contentsOf: work)))
        print("REAL ICON after:  stack=\(after.stackSize) defaultTool=\(after.defaultTool ?? "-") " +
              "tooltypes=\(after.toolTypes)")
        XCTAssertEqual(after.toolTypes, newTT)
        XCTAssertEqual(after.defaultTool, "SYS:Tools/HDToolBox")
        XCTAssertEqual(after.stackSize, 32768)
        XCTAssertEqual(after.type, before.type, "icon type must not change")

        let afterImg = IconImageDecoder.decode(try Data(contentsOf: work))
        XCTAssertEqual(beforeImg?.width, afterImg?.width)
        XCTAssertEqual(beforeImg?.height, afterImg?.height)
        XCTAssertEqual(beforeImg?.rgba, afterImg?.rgba, "artwork must survive byte-identical")
    }
}
