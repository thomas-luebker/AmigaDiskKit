import XCTest
@testable import AmigaDiskKit

final class FAT32VolumeTests: XCTestCase {

    private var imageURL: URL!
    private var vol: FAT32Volume!

    override func setUpWithError() throws {
        imageURL = try FAT32TestImage.create()
        vol = try FAT32Volume(imageURL: imageURL)
    }

    override func tearDownWithError() throws {
        vol = nil
        try? FileManager.default.removeItem(at: imageURL)
    }

    // MARK: - Basic operations on fresh image

    func testRootDirectoryIsEmpty() throws {
        let entries = try vol.listDirectory("/")
        XCTAssertTrue(entries.isEmpty)
    }

    func testExistsRoot() throws {
        XCTAssertTrue(try vol.exists("/"))
    }

    func testExistsMissingPath() throws {
        XCTAssertFalse(try vol.exists("/ghost.txt"))
    }

    // MARK: - mkdir

    func testMakeDirectory() throws {
        try vol.makeDirectory("/EMU68")
        XCTAssertTrue(try vol.exists("/EMU68"))
        let entries = try vol.listDirectory("/")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "EMU68")
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testMakeDirectoryNestedOneLevel() throws {
        try vol.makeDirectory("/EMU68")
        try vol.makeDirectory("/EMU68/cfg")
        XCTAssertTrue(try vol.exists("/EMU68/cfg"))
        let entries = try vol.listDirectory("/EMU68")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "cfg")
    }

    func testMakeDirectoryIdempotent() throws {
        try vol.makeDirectory("/A")
        try vol.makeDirectory("/A")   // should not throw
        XCTAssertTrue(try vol.exists("/A"))
    }

    func testMakeDirectoryDeep() throws {
        try vol.makeDirectory("/a/b/c")
        XCTAssertTrue(try vol.exists("/a/b/c"))
    }

    // MARK: - File write (copyFromHost)

    func testCopySmallFile() throws {
        let tmp = tmpFile(content: "hello FAT32")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try vol.copyFromHost(source: tmp, destination: "/hello.txt")
        XCTAssertTrue(try vol.exists("/hello.txt"))

        let entries = try vol.listDirectory("/")
        let entry = try XCTUnwrap(entries.first(where: { $0.name == "hello.txt" }))
        XCTAssertEqual(entry.fileSize, UInt32("hello FAT32".utf8.count))
    }

    func testCopyFileIntoSubdirectory() throws {
        try vol.makeDirectory("/sub")
        let tmp = tmpFile(content: "inside sub")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try vol.copyFromHost(source: tmp, destination: "/sub/data.bin")
        XCTAssertTrue(try vol.exists("/sub/data.bin"))
    }

    func testCopyLongFilename() throws {
        let tmp = tmpFile(content: "long")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try vol.copyFromHost(source: tmp, destination: "/startup-sequence")
        let entries = try vol.listDirectory("/")
        XCTAssertTrue(entries.contains(where: { $0.name == "startup-sequence" }))
    }

    func testOverwriteExistingFile() throws {
        let tmp1 = tmpFile(content: "first")
        let tmp2 = tmpFile(content: "second version here")
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }

        try vol.copyFromHost(source: tmp1, destination: "/over.txt")
        try vol.copyFromHost(source: tmp2, destination: "/over.txt")

        let entries = try vol.listDirectory("/")
        let overEntries = entries.filter { $0.name == "over.txt" }
        XCTAssertEqual(overEntries.count, 1)
        XCTAssertEqual(overEntries[0].fileSize, UInt32("second version here".utf8.count))
    }

    // MARK: - copyToHost (extract)

    func testExtractFile() throws {
        let original = "extract me please"
        let src = tmpFile(content: original)
        defer { try? FileManager.default.removeItem(at: src) }

        try vol.copyFromHost(source: src, destination: "/extract.txt")

        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fat32-extracted-\(ProcessInfo.processInfo.processIdentifier).txt")
        defer { try? FileManager.default.removeItem(at: dst) }

        try vol.copyToHost(source: "/extract.txt", destination: dst)

        let readBack = try String(contentsOf: dst, encoding: .utf8)
        XCTAssertEqual(readBack, original)
    }

    func testExtractMissingFileThrows() {
        let dst = URL(fileURLWithPath: "/tmp/nope.txt")
        XCTAssertThrowsError(try vol.copyToHost(source: "/ghost.bin", destination: dst)) { e in
            guard case AmigaDiskError.pathNotFound = e else {
                XCTFail("expected pathNotFound, got \(e)"); return
            }
        }
    }

    // MARK: - delete

    func testDeleteFile() throws {
        let tmp = tmpFile(content: "bye")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try vol.copyFromHost(source: tmp, destination: "/bye.txt")
        XCTAssertTrue(try vol.exists("/bye.txt"))

        try vol.delete("/bye.txt")
        XCTAssertFalse(try vol.exists("/bye.txt"))
    }

    func testDeleteNonExistentIsNoop() throws {
        XCTAssertNoThrow(try vol.delete("/phantom.txt"))
    }

    func testDeleteLFNFile() throws {
        let tmp = tmpFile(content: "data")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try vol.copyFromHost(source: tmp, destination: "/wpa_supplicant.conf")
        try vol.delete("/wpa_supplicant.conf")
        XCTAssertFalse(try vol.exists("/wpa_supplicant.conf"))
    }

    // MARK: - Recursive copy

    func testCopyDirectoryFromHost() throws {
        let srcDir = try tmpDirectory(files: ["a.txt": "aaa", "b.txt": "bbb"])
        defer { try? FileManager.default.removeItem(at: srcDir) }

        try vol.copyDirectoryFromHost(source: srcDir, destination: "/bundle")

        XCTAssertTrue(try vol.exists("/bundle"))
        XCTAssertTrue(try vol.exists("/bundle/a.txt"))
        XCTAssertTrue(try vol.exists("/bundle/b.txt"))
    }

    // MARK: - Case-insensitive lookup

    func testCaseInsensitiveLookup() throws {
        let tmp = tmpFile(content: "x")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try vol.copyFromHost(source: tmp, destination: "/CONFIG.TXT")
        XCTAssertTrue(try vol.exists("/config.txt"))
        XCTAssertTrue(try vol.exists("/CONFIG.TXT"))
    }

    // MARK: - Multiple files in one directory

    func testMultipleFilesInRoot() throws {
        for name in ["kick.rom", "config.txt", "cmdline.txt"] {
            let tmp = tmpFile(content: name)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try vol.copyFromHost(source: tmp, destination: "/\(name)")
        }
        let entries = try vol.listDirectory("/")
        XCTAssertEqual(entries.count, 3)
    }

    // MARK: - Overwrite-in-middle regression (sentinel corruption)

    /// Regression test for the sentinel-corruption bug: when a file is overwritten the
    /// previous entry becomes 0xE5; appendEntries reuses that gap and must NOT write a
    /// 0x00 sentinel into the following live entry's first byte.
    func testOverwriteMiddleEntryDoesNotCorruptFollowingEntries() throws {
        // Write enough files to fill the first directory cluster and extend into a second.
        // Use realistic names matching the PiStorm FAT root (LFN + SFN mix) so the slot
        // counts replicate the production layout that triggered the bug.
        let names = [
            "Emu68-pistorm",       // LFN+SFN = 2 slots
            "bcm2710-rpi-cm3.dtb", // LFN×2+SFN = 3 slots
            "bcm2711-rpi-400.dtb", // LFN×2+SFN = 3 slots
            "config.txt",          // LFN+SFN = 2 slots  (total: 10 so far)
            "start4.elf",          // LFN+SFN = 2 slots  (total: 12)
            "kick.rom",            // LFN+SFN = 2 slots  (total: 14)
            "cmdline.txt",         // LFN+SFN = 2 slots  (total: 16 — cluster 1 full)
            "cmdlineBAK.txt",      // LFN×2+SFN = 3 slots → forces cluster 2 extension
            "emu68imager.cfg",     // LFN×2+SFN = 3 slots
            "wpa_supplicant.conf", // LFN×2+SFN = 3 slots
        ]
        var tmpFiles: [URL] = []
        for name in names {
            let tmp = tmpFile(content: "data-\(name)")
            tmpFiles.append(tmp)
            try vol.copyFromHost(source: tmp, destination: "/\(name)")
        }
        defer { tmpFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Overwrite config.txt (sits in the middle of cluster 1, surrounded by live entries).
        // Before the fix this wrote 0x00 into the first byte of the next live entry.
        let updated = tmpFile(content: "updated-config")
        defer { try? FileManager.default.removeItem(at: updated) }
        try vol.copyFromHost(source: updated, destination: "/config.txt")

        let entries = try vol.listDirectory("/")
        let visible = Set(entries.map(\.name))

        for name in names {
            XCTAssertTrue(visible.contains(name), "'\(name)' missing after overwriting config.txt")
        }
        XCTAssertEqual(entries.count, names.count, "entry count mismatch")
    }

    // MARK: - Helpers

    private func tmpFile(content: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fat32-tmp-\(arc4random()).bin")
        try? content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func tmpDirectory(files: [String: String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fat32-dir-\(arc4random())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    // MARK: - Self-copy guard

    func testCopyDirectoryFromHost_skipsTheImageItself() throws {
        // Host folder containing the image being written; hardlinked so the
        // identity check, not path comparison, is what's tested.
        let dir = try tmpDirectory(files: ["readme.txt": "hello"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.linkItem(at: imageURL, to: dir.appendingPathComponent("disk.img"))

        try vol.copyDirectoryFromHost(source: dir, destination: "/transfer")

        let names = try vol.listDirectory("/transfer").map(\.name).sorted()
        XCTAssertEqual(names, ["readme.txt"])
    }
}
