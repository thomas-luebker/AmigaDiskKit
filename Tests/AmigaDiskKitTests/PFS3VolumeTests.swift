import XCTest
@testable import AmigaDiskKit

/// PFS3Volume file-I/O round trips on a natively built + formatted volume.
final class PFS3VolumeTests: XCTestCase {

    /// ~100 MB pure-RDB image with one PDS3 partition, PFS3-formatted.
    private func makeVolumeImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-vol-\(UUID().uuidString).img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try DiskBuilder.build(url: url, sizeBytes: 100 * 1024 * 1024, layout: .pureRDB(partitions: [
            PartitionSpec(name: "DH0", dosType: KnownDosType.pds3, isBootable: true,
                          sectorsPerFSBlock: 1),
        ]))
        let device = try BlockDevice(url: url)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        try PFS3Formatter.format(device: device, sliceStartLBA: 0,
                                 partition: rdb.partitionBlocks[0], rdb: rdb,
                                 spec: PFS3FormatSpec(volumeName: "Test"))
        return url
    }

    private func open(_ url: URL) throws -> PFS3Volume {
        try PFS3Volume.open(imageURL: url, partitionName: "DH0")
    }

    func testEmptyRootListing() throws {
        let url = try makeVolumeImage()
        XCTAssertEqual(try open(url).listDirectory(path: "").count, 0)
    }

    func testFileRoundTrip() throws {
        let url = try makeVolumeImage()
        let payload = Data((0 ..< 300_000).map { UInt8(($0 &* 7) & 0xFF) })

        let volume = try open(url)
        try volume.writeFile(path: "test.bin", data: payload)

        // same-mount read
        XCTAssertEqual(try volume.readFile(path: "test.bin"), payload)

        // fresh-mount read (everything from disk)
        let volume2 = try open(url)
        let listing = try volume2.listDirectory(path: "")
        XCTAssertEqual(listing.map(\.name), ["test.bin"])
        XCTAssertEqual(listing[0].byteSize, payload.count)
        XCTAssertFalse(listing[0].isDirectory)
        XCTAssertEqual(try volume2.readFile(path: "test.bin"), payload)
    }

    func testDirectoryTreeAndRecursiveListing() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        try volume.makeDirectory(path: "S/Sub/Deeper")
        try volume.writeFile(path: "S/Startup-Sequence", data: Data("echo hello\n".utf8))
        try volume.writeFile(path: "S/Sub/Deeper/file.txt", data: Data("x".utf8))

        let volume2 = try open(url)
        let recursive = Set(try volume2.listRecursive(path: ""))
        XCTAssertEqual(recursive, ["S", "S/Startup-Sequence", "S/Sub", "S/Sub/Deeper",
                                   "S/Sub/Deeper/file.txt"])
        XCTAssertEqual(try volume2.readFile(path: "S/Startup-Sequence"), Data("echo hello\n".utf8))
    }

    func testManyEntriesSpanMultipleDirBlocks() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        // ~40 bytes per entry → 60 entries exceed one 1004-byte entry area.
        for i in 0 ..< 60 {
            try volume.writeFile(path: "File-Number-\(String(format: "%03d", i)).dat",
                                 data: Data("content \(i)".utf8))
        }
        let volume2 = try open(url)
        let names = try volume2.listDirectory(path: "").map(\.name)
        XCTAssertEqual(names.count, 60)
        XCTAssertEqual(Set(names).count, 60)
        XCTAssertEqual(try volume2.readFile(path: "File-Number-042.dat"), Data("content 42".utf8))
    }

    func testOverwriteAndDelete() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        try volume.writeFile(path: "a.txt", data: Data("first".utf8))
        try volume.writeFile(path: "a.txt", data: Data("second version".utf8))
        XCTAssertEqual(try volume.readFile(path: "a.txt"), Data("second version".utf8))

        try volume.delete(path: "a.txt")
        let volume2 = try open(url)
        XCTAssertEqual(try volume2.listDirectory(path: "").count, 0)
        XCTAssertThrowsError(try volume2.readFile(path: "a.txt"))
    }

    func testDeleteFreesSpace() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        let payload = Data(count: 1_000_000)
        let freeBefore = volume.g.rootBlock.blocksFree
        try volume.writeFile(path: "big.bin", data: payload)
        try volume.delete(path: "big.bin")
        let volume2 = try open(url)
        XCTAssertEqual(volume2.g.rootBlock.blocksFree, freeBefore,
                       "all data blocks must return to the free pool after delete")
    }

    func testScriptBitNotSetOnBinaries() throws {
        // Foreign binaries (PPC ELF aget.os4 etc.) shipped with the executable
        // bit must NOT get the Amiga script bit: the shell would "execute"
        // them as scripts when LoadSeg fails, spraying volume requesters.
        let url = try makeVolumeImage()
        let hostDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-sbit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: hostDir) }
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        func writeExecutable(_ name: String, _ data: Data) throws {
            let file = hostDir.appendingPathComponent(name)
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try writeExecutable("script", Data("ECHO hello\n".utf8))
        try writeExecutable("aget.os4", Data([0x7F, 0x45, 0x4C, 0x46]) + Data(count: 64))
        try writeExecutable("tool68k", Data([0x00, 0x00, 0x03, 0xF3]) + Data(count: 64))

        let volume = try open(url)
        try volume.copyFromHost(hostURL: hostDir, amigaPath: "T")

        let entries = Dictionary(uniqueKeysWithValues:
            try open(url).listDirectory(path: "T").map { ($0.name, $0.protection) })
        XCTAssertEqual(entries["script"]! & 0x40, 0x40, "text script keeps the script bit")
        XCTAssertEqual(entries["aget.os4"]! & 0x40, 0, "ELF binary must not get the script bit")
        XCTAssertEqual(entries["tool68k"]! & 0x40, 0, "hunk binary must not get the script bit")
    }

    func testListEntriesMetadata_protectionAndDate() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        try volume.writeFile(path: "Script", data: Data("echo\n".utf8), protection: 0x40)

        let ops: AmigaVolumeOperations = try open(url)
        let entry = try XCTUnwrap(try ops.listEntries(path: "").first { $0.name == "Script" })
        XCTAssertEqual(entry.protection, 0x40)
        XCTAssertEqual(entry.byteSize, 5)
        let modified = try XCTUnwrap(entry.modified)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 3600)
    }

    func testVolumeInfo() throws {
        let url = try makeVolumeImage()
        let before = try open(url).volumeInfo()
        XCTAssertEqual(before.volumeName, "Test")
        XCTAssertGreaterThan(before.totalBytes, 0)
        XCTAssertGreaterThan(before.freeBytes, 0)
        XCTAssertLessThan(before.freeBytes, before.totalBytes)

        let volume = try open(url)
        try volume.writeFile(path: "big.bin", data: Data(count: 1_000_000))
        let after = try open(url).volumeInfo()
        XCTAssertLessThanOrEqual(after.freeBytes, before.freeBytes - 1_000_000)
    }

    func testHostTreeCopyAndExtract() throws {
        let url = try makeVolumeImage()
        let hostDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-host-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: hostDir) }
        try FileManager.default.createDirectory(at: hostDir.appendingPathComponent("inner"),
                                                withIntermediateDirectories: true)
        try Data("root file".utf8).write(to: hostDir.appendingPathComponent("root.txt"))
        try Data("inner file".utf8).write(to: hostDir.appendingPathComponent("inner/leaf.txt"))

        let volume = try open(url)
        try volume.copyFromHost(hostURL: hostDir, amigaPath: "Stuff")

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-out-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: outDir) }
        let volume2 = try open(url)
        try volume2.extractToHost(amigaPath: "Stuff", hostURL: outDir)

        XCTAssertEqual(try Data(contentsOf: outDir.appendingPathComponent("root.txt")),
                       Data("root file".utf8))
        XCTAssertEqual(try Data(contentsOf: outDir.appendingPathComponent("inner/leaf.txt")),
                       Data("inner file".utf8))
    }

    // MARK: - Capacity guards (disk full / file too large / self-copy)

    func testWriteFile_diskFull_rollsBackDirEntry() throws {
        let url = try makeVolumeImage()  // ~100 MB volume
        let volume = try open(url)

        // Bigger than the whole volume → diskFull, and the direntry added
        // before block allocation must be rolled back (no 0-byte orphan).
        XCTAssertThrowsError(try volume.writeFile(path: "huge.bin",
                                                  data: Data(count: 110 * 1024 * 1024))) { error in
            guard case AmigaDiskError.diskFull = error else {
                return XCTFail("expected diskFull, got \(error)")
            }
        }
        XCTAssertEqual(try volume.listDirectory(path: "").count, 0)

        // Volume must remain fully usable.
        try volume.writeFile(path: "small.txt", data: Data("still works\n".utf8))
        let volume2 = try open(url)
        XCTAssertEqual(try volume2.listDirectory(path: "").map(\.name), ["small.txt"])
        XCTAssertEqual(try volume2.readFile(path: "small.txt"), Data("still works\n".utf8))
    }

    func testWriteFile_fileTooLarge_leavesExistingFileIntact() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        let original = Data("keep me\n".utf8)
        try volume.writeFile(path: "huge.bin", data: original)

        // > UInt32.max bytes cannot be represented in fsize; the guard must
        // fire before the overwrite-delete.
        let oversized = Data(count: Int(UInt32.max) + 1)
        XCTAssertThrowsError(try volume.writeFile(path: "huge.bin", data: oversized)) { error in
            guard case AmigaDiskError.fileTooLarge = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
        XCTAssertEqual(try volume.readFile(path: "huge.bin"), original)
    }

    func testCopyFromHost_skipsTheImageItself() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)

        // Host folder containing the image being written; hardlinked so the
        // identity check, not path comparison, is what's tested.
        let transferDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-transfer-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: transferDir) }
        try FileManager.default.createDirectory(at: transferDir, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: url, to: transferDir.appendingPathComponent("disk.img"))
        try Data("hello\n".utf8).write(to: transferDir.appendingPathComponent("readme.txt"))

        try volume.copyFromHost(hostURL: transferDir, amigaPath: "Transfer")

        let volume2 = try open(url)
        XCTAssertEqual(try volume2.listDirectory(path: "Transfer").map(\.name), ["readme.txt"])
        XCTAssertEqual(try volume2.readFile(path: "Transfer/readme.txt"), Data("hello\n".utf8))
    }

    // MARK: - rename (in place)

    func testRenameFilePreservesContent() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        let payload = Data("pfs3 rename".utf8)
        try volume.makeDirectory(path: "S")
        try volume.writeFile(path: "S/Startup-Sequence", data: payload)
        try volume.rename(path: "S/Startup-Sequence", to: "Startup-Sequence.old")

        let volume2 = try open(url)
        XCTAssertEqual(try volume2.listDirectory(path: "S").map(\.name), ["Startup-Sequence.old"])
        XCTAssertEqual(try volume2.readFile(path: "S/Startup-Sequence.old"), payload)
    }

    func testRenameDirectoryKeepsChildren() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        let payload = Data("child".utf8)
        try volume.makeDirectory(path: "Old/Sub")
        try volume.writeFile(path: "Old/Sub/file.txt", data: payload)
        try volume.rename(path: "Old", to: "New")

        let volume2 = try open(url)
        XCTAssertEqual(try volume2.listDirectory(path: "").map(\.name), ["New"])
        XCTAssertEqual(try volume2.readFile(path: "New/Sub/file.txt"), payload)
    }

    func testRenameCaseOnly() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        try volume.writeFile(path: "readme", data: Data([7, 8, 9]))
        try volume.rename(path: "readme", to: "ReadMe")

        let volume2 = try open(url)
        XCTAssertEqual(try volume2.listDirectory(path: "").map(\.name), ["ReadMe"])
        XCTAssertEqual(try volume2.readFile(path: "ReadMe"), Data([7, 8, 9]))
    }

    func testRenameCollisionThrows() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        try volume.writeFile(path: "a.txt", data: Data([1]))
        try volume.writeFile(path: "b.txt", data: Data([2]))

        XCTAssertThrowsError(try volume.rename(path: "a.txt", to: "b.txt")) { err in
            guard case AmigaDiskError.entryExists = err else {
                return XCTFail("expected entryExists, got \(err)")
            }
        }
        let volume2 = try open(url)
        XCTAssertEqual(Set(try volume2.listDirectory(path: "").map(\.name)), ["a.txt", "b.txt"])
    }

    func testRenameMissingThrows() throws {
        let url = try makeVolumeImage()
        let volume = try open(url)
        XCTAssertThrowsError(try volume.rename(path: "nope", to: "x")) { err in
            guard case AmigaDiskError.pathNotFound = err else {
                return XCTFail("expected pathNotFound, got \(err)")
            }
        }
    }
}
