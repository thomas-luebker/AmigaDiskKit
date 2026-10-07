import XCTest
@testable import AmigaDiskKit

/// Extracting several Amiga volumes into one host tree must merge `DEVS` into
/// an existing `Devs` — Amiga names are case-insensitive. On a case-sensitive
/// host (iPadOS) the extractors used to create a second `DEVS` tree (the iOS
/// Simulator failed outright with EIO), so every iPad OS install lost the
/// Modules and Storage disks. The resolver decides that on every host, so it
/// is what these tests pin; macOS's own case-insensitive APFS would hide a
/// regression in an end-to-end test.
final class HostNameMergeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostmerge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReusesAnExistingDrawerWhateverItsCase() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Devs"),
                                                withIntermediateDirectories: true)
        var names = HostNameMerge()
        XCTAssertEqual(names.child(of: dir, named: "DEVS").lastPathComponent, "Devs")
        XCTAssertEqual(names.child(of: dir, named: "devs").lastPathComponent, "Devs")
    }

    func testFirstSpellingWithinOneExtractionWins() {
        var names = HostNameMerge()
        XCTAssertEqual(names.child(of: dir, named: "Libs").lastPathComponent, "Libs")
        XCTAssertEqual(names.child(of: dir, named: "LIBS").lastPathComponent, "Libs")
    }

    func testDistinctNamesStayDistinct() {
        var names = HostNameMerge()
        XCTAssertEqual(names.child(of: dir, named: "C").lastPathComponent, "C")
        XCTAssertEqual(names.child(of: dir, named: "L").lastPathComponent, "L")
        XCTAssertEqual(names.child(of: dir, named: "Libs").lastPathComponent, "Libs")
    }

    func testScopedPerDirectory() throws {
        let sub = dir.appendingPathComponent("Devs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        var names = HostNameMerge()
        // a "devs" inside Devs/ is a different drawer from the top-level one
        XCTAssertEqual(names.child(of: sub, named: "DEVS").lastPathComponent, "DEVS")
        XCTAssertEqual(names.child(of: dir, named: "DEVS").lastPathComponent, "Devs")
    }

    /// Exact install rules (Libs/guigfx.library) must find an archive's
    /// libs/guigfx.library — on iPadOS the literal lookup found nothing and
    /// the package installed nothing.
    func testResolverFindsAPathWhateverItsCase() throws {
        let libs = dir.appendingPathComponent("libs")
        try FileManager.default.createDirectory(at: libs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: libs.appendingPathComponent("guigfx.library"))
        let found = try XCTUnwrap(HostPathResolver.resolve("Libs/guigfx.library", under: dir))
        XCTAssertEqual(try Data(contentsOf: found), Data("x".utf8))
        XCTAssertNil(HostPathResolver.resolve("Libs/missing.library", under: dir))
    }
}

