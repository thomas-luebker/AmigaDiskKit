import XCTest
@testable import AmigaDiskKit

final class FFSFileSystemTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFSFileSystemTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Test helpers

    /// Create a blank 32 MiB pure-RDB image with one DOS\3 partition named "DH0".
    private func makeFormattedImage(name: String = "DH0", dosType: UInt32 = KnownDosType.dos3,
                                    sizeMiB: Int = 32) throws -> (URL, PartitionBlock, RigidDiskBlock) {
        let imgURL = tmpDir.appendingPathComponent("test.img")
        let sizeBytes = Int64(sizeMiB * 1024 * 1024)
        let layout: DiskLayout = .pureRDB(partitions: [
            PartitionSpec(name: name, dosType: dosType, sizeCylinders: 0,
                          isBootable: false, bootPriority: 0, sectorsPerFSBlock: dosType == KnownDosType.dos7 ? 4 : 1)
        ])
        try DiskBuilder.build(url: imgURL, sizeBytes: sizeBytes, layout: layout)

        let device = try BlockDevice(url: imgURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks.first!

        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: name))
        return (imgURL, part, rdb)
    }

    private func openFS(imgURL: URL, name: String = "DH0") throws -> FFSFileSystem {
        try FFSFileSystem.open(imageURL: imgURL, partitionName: name)
    }

    // MARK: - mkdir

    func testMakeDirectory_single() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "System")
        try fs.flush()

        // Re-open and verify
        let fs2 = try openFS(imgURL: imgURL)
        let entries = try fs2.listDirectory()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "System")
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testMakeDirectory_nested() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "System/Prefs/Env-Archive")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let root = try fs2.listDirectory()
        XCTAssertEqual(root.count, 1)
        XCTAssertEqual(root[0].name, "System")

        let system = try fs2.listDirectory(path: "System")
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0].name, "Prefs")

        let prefs = try fs2.listDirectory(path: "System/Prefs")
        XCTAssertEqual(prefs.count, 1)
        XCTAssertEqual(prefs[0].name, "Env-Archive")
    }

    func testMakeDirectory_idempotent() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "System/Prefs")
        try fs.makeDirectory(path: "System/Prefs")  // should not throw
        try fs.makeDirectory(path: "System")         // should not throw
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let system = try fs2.listDirectory(path: "System")
        XCTAssertEqual(system.count, 1, "Idempotent mkdir must not create duplicates")
    }

    // MARK: - writeFile / readFile

    func testWriteAndReadFile_small() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "S")
        let content = "Hello, Amiga!".data(using: .utf8)!
        try fs.writeFile(path: "S/startup-sequence", data: content)
        try fs.flush()

        let fs2   = try openFS(imgURL: imgURL)
        let read  = try fs2.readFile(path: "S/startup-sequence")
        XCTAssertEqual(read, content)
    }

    func testWriteAndReadFile_emptyFile() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "empty.txt", data: Data())
        try fs.flush()

        let fs2  = try openFS(imgURL: imgURL)
        let read = try fs2.readFile(path: "empty.txt")
        XCTAssertEqual(read.count, 0)
    }

    func testWriteFile_exactlyOneBlock() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        let content = Data(repeating: 0xAB, count: 512) // exactly one FS block
        try fs.writeFile(path: "block.bin", data: content)
        try fs.flush()

        let fs2  = try openFS(imgURL: imgURL)
        let read = try fs2.readFile(path: "block.bin")
        XCTAssertEqual(read, content)
    }

    func testWriteFile_multiBlock_noExtension() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        // 72 blocks × 512 = 36,864 bytes — fills one file header exactly
        let content = Data((0 ..< 36_864).map { UInt8($0 & 0xFF) })
        try fs.writeFile(path: "big.bin", data: content)
        try fs.flush()

        let fs2  = try openFS(imgURL: imgURL)
        let read = try fs2.readFile(path: "big.bin")
        XCTAssertEqual(read, content)
    }

    func testWriteFile_requiresExtensionBlock() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        // 73 blocks × 512 = 37,376 bytes — needs 1 extension block
        let content = Data((0 ..< 37_376).map { UInt8($0 & 0xFF) })
        try fs.writeFile(path: "ext.bin", data: content)
        try fs.flush()

        let fs2  = try openFS(imgURL: imgURL)
        let read = try fs2.readFile(path: "ext.bin")
        XCTAssertEqual(read, content)
    }

    func testWriteFile_entryExistsThrows() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "file.txt", data: Data([1, 2, 3]))
        XCTAssertThrowsError(try fs.writeFile(path: "file.txt", data: Data([4, 5, 6]))) { error in
            guard case AmigaDiskError.entryExists = error else {
                XCTFail("Expected entryExists, got \(error)"); return
            }
        }
    }

    // MARK: - Copy from host

    func testCopyFromHost_singleFile() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let hostFile = tmpDir.appendingPathComponent("test.txt")
        let content = "Amiga Forever!".data(using: .utf8)!
        try content.write(to: hostFile)

        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "C")
        try fs.copyFromHost(hostURL: hostFile, amigaPath: "C/test.txt")
        try fs.flush()

        let fs2  = try openFS(imgURL: imgURL)
        let read = try fs2.readFile(path: "C/test.txt")
        XCTAssertEqual(read, content)
    }

    func testCopyFromHost_directory() throws {
        let (imgURL, _, _) = try makeFormattedImage()

        // Create host tree: hostDir/a.txt, hostDir/sub/b.txt
        let hostDir = tmpDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        let sub = hostDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "A".data(using: .utf8)!.write(to: hostDir.appendingPathComponent("a.txt"))
        try "B".data(using: .utf8)!.write(to: sub.appendingPathComponent("b.txt"))

        let fs = try openFS(imgURL: imgURL)
        try fs.copyFromHost(hostURL: hostDir, amigaPath: "payload")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let readA = try fs2.readFile(path: "payload/a.txt")
        XCTAssertEqual(String(data: readA, encoding: .utf8), "A")
        let readB = try fs2.readFile(path: "payload/sub/b.txt")
        XCTAssertEqual(String(data: readB, encoding: .utf8), "B")
    }

    // MARK: - Extract to host

    func testExtractToHost_file() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let content = "Extract me!".data(using: .utf8)!
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "readme.txt", data: content)
        try fs.flush()

        let dest = tmpDir.appendingPathComponent("extracted.txt")
        let fs2 = try openFS(imgURL: imgURL)
        try fs2.extractToHost(amigaPath: "readme.txt", hostURL: dest)
        let read = try Data(contentsOf: dest)
        XCTAssertEqual(read, content)
    }

    func testExtractToHost_directory() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "S")
        try fs.writeFile(path: "S/a", data: Data([1]))
        try fs.writeFile(path: "S/b", data: Data([2]))
        try fs.flush()

        let dest = tmpDir.appendingPathComponent("extracted")
        let fs2 = try openFS(imgURL: imgURL)
        try fs2.extractToHost(amigaPath: "S", hostURL: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("b").path))
    }

    // MARK: - Hash function

    func testFfsHash_knownValues() {
        // FFS hash for "Prefs" with htSize=72: expected slot
        let htSize = 72
        let h1 = ffsHashName("Prefs", htSize: htSize)
        XCTAssertGreaterThanOrEqual(h1, 0)
        XCTAssertLessThan(h1, htSize)
        // Case-insensitive: hash("Prefs") == hash("prefs") == hash("PREFS")
        XCTAssertEqual(ffsHashName("prefs",  htSize: htSize), h1)
        XCTAssertEqual(ffsHashName("PREFS",  htSize: htSize), h1)
    }

    // MARK: - DOS7

    func testWriteAndReadFile_DOS7() throws {
        let (imgURL, _, _) = try makeFormattedImage(name: "DH0",
                                                    dosType: KnownDosType.dos7, sizeMiB: 32)
        let fs = try openFS(imgURL: imgURL)
        let content = Data(repeating: 0xCC, count: 8192)
        try fs.writeFile(path: "test.bin", data: content)
        try fs.flush()

        let fs2  = try openFS(imgURL: imgURL)
        let read = try fs2.readFile(path: "test.bin")
        XCTAssertEqual(read, content)
    }
}
