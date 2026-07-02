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

    /// Regression: on an OFS volume (DOS\0), raw file data whose block begins
    /// with the longword 0x00000008 (T_DATA) must NOT be mistaken for an OFS data
    /// block and have 24 bytes stripped. This false positive corrupted
    /// DEVS/scsi.device (its 8th block starts 0x00000008) and broke LoadModule
    /// ROMUPDATE on real sub-V47 hardware. assembleFileData now also validates the
    /// OFS header's seq_num + data_size, so the false positive reads through raw.
    /// (The Modules ADF is DOS\1, now correctly classified FFS so it never takes
    /// the OFS path at all — this test keeps coverage of the seq_num guard via an
    /// actually-OFS-typed volume.)
    func testReadFile_ffsBlockStartingWithT_DATA_notStrippedAsOFS() throws {
        let (imgURL, _, _) = try makeFormattedImage(dosType: KnownDosType.dos0)
        // First block begins 0x00000008 but the following longwords are NOT a
        // valid OFS header (seq_num would be 0xFFFFFFFF, data_size huge), and the
        // file spans several blocks so a stripped block shifts everything after.
        var content = Data([0x00, 0x00, 0x00, 0x08, 0xFF, 0xFF, 0xFF, 0xFF,
                            0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34, 0x56, 0x78])
        content.append(Data((0 ..< 4096).map { UInt8($0 & 0xFF) }))
        // Also start a later block boundary with 0x00000008 to mimic scsi.device.
        let blkSize = 512
        if content.count > blkSize {
            content.replaceSubrange((blkSize) ..< (blkSize + 4),
                                    with: [0x00, 0x00, 0x00, 0x08])
        }

        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "scsi.device", data: content, overwrite: true)
        try fs.flush()

        let read = try openFS(imgURL: imgURL).readFile(path: "scsi.device")
        XCTAssertEqual(read, content, "FFS data block starting 0x00000008 was corrupted (OFS false positive)")
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

    // MARK: - DOS6/DOS7 long-filename (LNFS) header layout
    //
    // FFS2 LNFS stores the entry name in the old comment area (block end − 184)
    // and moves the dates to block end − 60; the classic name field at block
    // end − 80 stays empty. Writing classic-layout headers on a DOS\7 volume
    // produced files the real FFS2 handler saw as nameless (the "Work volume
    // shows the default floppy icon" hardware bug). Layout verified
    // byte-for-byte against hst-imager reference volumes.

    func testLNFS_fileHeaderLayout_DOS7() throws {
        let (imgURL, _, _) = try makeFormattedImage(name: "DH0",
                                                    dosType: KnownDosType.dos7, sizeMiB: 32)
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "Disk.info", data: Data(repeating: 0xAB, count: 1332))
        try fs.makeDirectory(path: "TestDir")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let fileBlock = try XCTUnwrap(try fs2.lookup(name: "Disk.info", inDir: fs2.rootFSBlock))
        let dirBlock  = try XCTUnwrap(try fs2.lookup(name: "TestDir",  inDir: fs2.rootFSBlock))

        let fileData = try fs2.readFSBlock(fileBlock)
        let bl = fileData.count / 4
        // LNFS name present in the old comment area, classic name field empty
        XCTAssertEqual(fileData.readBSTR(at: (bl - 46) * 4, maxLength: 112), "Disk.info")
        XCTAssertEqual(Int(fileData[(bl - 20) * 4]), 0, "classic name field must be empty on LNFS")
        // Dates at block end − 60; classic date slots zero
        XCTAssertNotEqual(fileData.readBE32(at: (bl - 15) * 4), 0, "LNFS days must be set")
        XCTAssertEqual(fileData.readBE32(at: (bl - 23) * 4), 0, "classic days slot must be empty on LNFS")
        // first_data points at the first data block (matches reference writer)
        let htSize = bl - 56
        let firstFromTable = fileData.readBE32(at: (6 + htSize - 1) * 4)
        XCTAssertEqual(fileData.readBE32(at: 4 * 4), firstFromTable)
        XCTAssertNotEqual(firstFromTable, 0)

        let dirData = try fs2.readFSBlock(dirBlock)
        XCTAssertEqual(dirData.readBSTR(at: (bl - 46) * 4, maxLength: 112), "TestDir")
        XCTAssertEqual(Int(dirData[(bl - 20) * 4]), 0)
        XCTAssertNotEqual(dirData.readBE32(at: (bl - 15) * 4), 0)
    }

    func testLNFS_listAndExtractRoundTrip_DOS7() throws {
        let (imgURL, _, _) = try makeFormattedImage(name: "DH0",
                                                    dosType: KnownDosType.dos7, sizeMiB: 32)
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "Programs/MyTool")
        try fs.writeFile(path: "Programs/MyTool/MyTool", data: Data(repeating: 0x4D, count: 4096))
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let all = try fs2.listRecursive()
        XCTAssertEqual(Set(all), ["Programs", "Programs/MyTool", "Programs/MyTool/MyTool"])
        XCTAssertEqual(try fs2.readFile(path: "Programs/MyTool/MyTool").count, 4096)
    }

    // MARK: - Entry metadata / volumeInfo (disk browser surface)

    func testListEntriesMetadata_protectionAndDate() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "Script", data: Data("echo\n".utf8), protection: 0x40)
        try fs.flush()

        let volume: AmigaVolumeOperations = try openFS(imgURL: imgURL)
        let entries = try volume.listEntries(path: "")
        let entry = try XCTUnwrap(entries.first { $0.name == "Script" })
        XCTAssertEqual(entry.protection, 0x40)
        XCTAssertEqual(entry.byteSize, 5)
        let modified = try XCTUnwrap(entry.modified)
        // Stamped at write time — must be within the last hour.
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 3600)
    }

    func testVolumeInfo_freeSpaceShrinksAndRecovers() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        let before = try fs.volumeInfo()
        XCTAssertEqual(before.volumeName, "DH0")
        XCTAssertGreaterThan(before.totalBytes, 0)
        XCTAssertGreaterThan(before.freeBytes, 0)
        XCTAssertLessThan(before.freeBytes, before.totalBytes)

        try fs.writeFile(path: "big.bin", data: Data(repeating: 0xAA, count: 256 * 1024))
        try fs.flush()
        let afterWrite = try openFS(imgURL: imgURL).volumeInfo()
        XCTAssertLessThanOrEqual(afterWrite.freeBytes, before.freeBytes - 256 * 1024)

        let fs2 = try openFS(imgURL: imgURL)
        try fs2.delete(path: "big.bin")
        try fs2.flush()
        let afterDelete = try openFS(imgURL: imgURL).volumeInfo()
        XCTAssertEqual(afterDelete.freeBytes, before.freeBytes)
    }

    // MARK: - ADF write support

    /// Format a blank 880 KB ADF with the same synthetic geometry `openADF` uses.
    private func makeADF(volumeName: String = "TestADF") throws -> URL {
        let url = tmpDir.appendingPathComponent("test.adf")
        let sizeBytes: Int64 = 880 * 1024
        try BlockDevice.createBlank(url: url, sizeBytes: sizeBytes)
        let geo = try DiskGeometry(sizeBytes: sizeBytes, heads: 1, sectors: 1)
        let rdb = RigidDiskBlock(geometry: geo)
        let part = PartitionBlock(name: volumeName, dosType: KnownDosType.dos3, lowCyl: 0,
                                  highCyl: UInt32(sizeBytes / 512 - 1), geometry: geo,
                                  sectorsPerFSBlock: 1)
        let device = try BlockDevice(url: url)
        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: volumeName))
        return url
    }

    func testOpenADF_writableRoundTrip() throws {
        let adfURL = try makeADF()
        let payload = Data("ADF write test\n".utf8)

        let fs = try FFSFileSystem.openADF(url: adfURL, readOnly: false)
        try fs.makeDirectory(path: "S")
        try fs.writeFile(path: "S/startup-sequence", data: payload)
        try fs.flush()

        let fs2 = try FFSFileSystem.openADF(url: adfURL)
        XCTAssertEqual(try fs2.readFile(path: "S/startup-sequence"), payload)
    }

    func testOpenADF_defaultIsReadOnly() throws {
        let adfURL = try makeADF()
        let fs = try FFSFileSystem.openADF(url: adfURL)
        XCTAssertThrowsError(try fs.writeFile(path: "nope", data: Data([1])))
    }

    func testClassic_firstDataSet_DOS3() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "file.bin", data: Data(repeating: 1, count: 100))
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let blockNo = try XCTUnwrap(try fs2.lookup(name: "file.bin", inDir: fs2.rootFSBlock))
        let data = try fs2.readFSBlock(blockNo)
        let bl = data.count / 4
        let htSize = bl - 56
        XCTAssertEqual(data.readBE32(at: 4 * 4), data.readBE32(at: (6 + htSize - 1) * 4))
        XCTAssertNotEqual(data.readBE32(at: 4 * 4), 0)
        // Classic layout unchanged: name at block end − 80
        XCTAssertEqual(data.readBSTR(at: (bl - 20) * 4, maxLength: 32), "file.bin")
    }

    // MARK: - Capacity guards (disk full / file too large / self-copy)

    func testWriteFile_diskFull_failsCleanlyAndKeepsPartitionUsable() throws {
        let (imgURL, _, _) = try makeFormattedImage()  // 32 MiB partition
        let fs = try openFS(imgURL: imgURL)
        let freeBefore = try fs.volumeInfo().freeBytes

        // Bigger than the whole partition → must throw diskFull without
        // consuming any bitmap space (regression: a failed oversized copy
        // used to leak every allocated block and brick the partition).
        XCTAssertThrowsError(try fs.writeFile(path: "huge.bin",
                                              data: Data(count: 33 * 1024 * 1024))) { error in
            guard case AmigaDiskError.diskFull = error else {
                return XCTFail("expected diskFull, got \(error)")
            }
        }
        XCTAssertEqual(try fs.volumeInfo().freeBytes, freeBefore)

        // Partition must remain fully usable.
        try fs.writeFile(path: "small.txt", data: Data("still works\n".utf8))
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        XCTAssertEqual(try fs2.listDirectory().map(\.name), ["small.txt"])
        XCTAssertEqual(try fs2.readFile(path: "small.txt"), Data("still works\n".utf8))
    }

    func testWriteFile_fileTooLarge_leavesExistingFileIntact() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        let original = Data("keep me\n".utf8)
        try fs.writeFile(path: "huge.bin", data: original)

        // > UInt32.max bytes cannot be represented in FFS byte_size; the guard
        // must fire before the overwrite-delete (regression: this used to be
        // a Swift overflow trap after writing gigabytes of data blocks).
        let oversized = Data(count: Int(UInt32.max) + 1)
        XCTAssertThrowsError(try fs.writeFile(path: "huge.bin", data: oversized,
                                              overwrite: true)) { error in
            guard case AmigaDiskError.fileTooLarge = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
        XCTAssertEqual(try fs.readFile(path: "huge.bin"), original)
    }

    func testCopyFromHost_skipsTheImageItself() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)

        // Host folder containing the image being written (the tester scenario:
        // a Transfer folder with the output .img inside it). Hardlink rather
        // than same-path so the identity check, not path comparison, is tested.
        let transferDir = tmpDir.appendingPathComponent("transfer")
        try FileManager.default.createDirectory(at: transferDir, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: imgURL, to: transferDir.appendingPathComponent("disk.img"))
        try Data("hello\n".utf8).write(to: transferDir.appendingPathComponent("readme.txt"))

        try fs.copyFromHost(hostURL: transferDir, amigaPath: "Transfer")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        XCTAssertEqual(try fs2.listDirectory(path: "Transfer").map(\.name), ["readme.txt"])
        XCTAssertEqual(try fs2.readFile(path: "Transfer/readme.txt"), Data("hello\n".utf8))
    }

    // MARK: - Latin-1 (non-ASCII) filename round-trip

    /// Amiga filenames are ISO-8859-1. Writing them as UTF-8 (the Swift default)
    /// stored two bytes for accented characters, which the .isoLatin1 read path
    /// then decoded as mojibake (`français` → `franÃ§ais`), and dropped locale
    /// catalogs entirely. Names must survive a write/read round-trip byte-exact.
    func testNonASCIIFilename_roundTrips() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.makeDirectory(path: "Catalogs")
        try fs.makeDirectory(path: "Catalogs/français")
        try fs.writeFile(path: "Catalogs/Español.catalog", data: Data([1, 2, 3]))
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let names = try fs2.listDirectory(path: "Catalogs").map(\.name).sorted()
        XCTAssertEqual(names, ["Español.catalog", "français"])
        XCTAssertEqual(try fs2.listDirectory(path: "Catalogs/français").count, 0)
    }

    /// Pin the on-disk encoding: the accented name byte must be a single Latin-1
    /// byte (ç = 0xE7), not the two-byte UTF-8 sequence (0xC3 0xA7). The Latin-1
    /// directory uses a fresh image so 0xE7 can only come from the filename.
    func testNonASCIIFilename_isLatin1OnDisk() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "ç.txt", data: Data([0]))
        try fs.flush()

        let raw = try Data(contentsOf: imgURL)
        XCTAssertTrue(raw.contains(0xE7),
                      "Latin-1 'ç' (0xE7) must be stored on disk, not UTF-8 0xC3 0xA7")
    }

    /// A decomposed (NFD) host name — `ñ` as `n` + U+0303 combining tilde, as
    /// macOS may hand back — must recompose to the single Latin-1 byte (0xF1),
    /// not store `n` followed by a substitution.
    func testNonASCIIFilename_nfdNameRecomposes() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        let nfdName = "espan\u{0303}ol.txt"          // n + combining tilde
        let nfcName = "español.txt"                   // single ñ (U+00F1)
        XCTAssertNotEqual(Array(nfdName.unicodeScalars), Array(nfcName.unicodeScalars),
                          "test inputs must actually differ in normalization")
        try fs.writeFile(path: nfdName, data: Data([0]))
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let names = try fs2.listDirectory().map(\.name)
        XCTAssertEqual(names, [nfcName])
    }

    // MARK: - rename (in place)

    func testRename_filePreservesContent() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        let content = Data("hello amiga".utf8)
        try fs.makeDirectory(path: "S")
        try fs.writeFile(path: "S/startup-sequence", data: content)
        try fs.flush()

        try fs.rename(path: "S/startup-sequence", to: "startup-sequence.bak")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        let names = try fs2.listDirectory(path: "S").map(\.name)
        XCTAssertEqual(names, ["startup-sequence.bak"])
        XCTAssertEqual(try fs2.readFile(path: "S/startup-sequence.bak"), content)
    }

    func testRename_directoryKeepsChildren() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        let content = Data("payload".utf8)
        try fs.makeDirectory(path: "Old")
        try fs.writeFile(path: "Old/file.txt", data: content)
        try fs.flush()

        try fs.rename(path: "Old", to: "New")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        XCTAssertEqual(try fs2.listDirectory().map(\.name), ["New"])
        XCTAssertEqual(try fs2.listDirectory(path: "New").map(\.name), ["file.txt"])
        XCTAssertEqual(try fs2.readFile(path: "New/file.txt"), content)
    }

    func testRename_caseOnly() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "readme", data: Data([1, 2, 3]))
        try fs.flush()

        try fs.rename(path: "readme", to: "ReadMe")
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        XCTAssertEqual(try fs2.listDirectory().map(\.name), ["ReadMe"])
        XCTAssertEqual(try fs2.readFile(path: "ReadMe"), Data([1, 2, 3]))
    }

    func testRename_collisionThrows() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        try fs.writeFile(path: "a.txt", data: Data([1]))
        try fs.writeFile(path: "b.txt", data: Data([2]))
        try fs.flush()

        XCTAssertThrowsError(try fs.rename(path: "a.txt", to: "b.txt")) { err in
            guard case AmigaDiskError.entryExists = err else {
                return XCTFail("expected entryExists, got \(err)")
            }
        }
        // Both files must survive the rejected rename.
        let fs2 = try openFS(imgURL: imgURL)
        XCTAssertEqual(Set(try fs2.listDirectory().map(\.name)), ["a.txt", "b.txt"])
    }

    func testRename_missingThrows() throws {
        let (imgURL, _, _) = try makeFormattedImage()
        let fs = try openFS(imgURL: imgURL)
        XCTAssertThrowsError(try fs.rename(path: "nope.txt", to: "x.txt")) { err in
            guard case AmigaDiskError.pathNotFound = err else {
                return XCTFail("expected pathNotFound, got \(err)")
            }
        }
    }

    func testRename_longNameFS() throws {
        // DOS\7 = long-name FFS: a >30-char name must round-trip.
        let (imgURL, _, _) = try makeFormattedImage(dosType: KnownDosType.dos7)
        let fs = try openFS(imgURL: imgURL)
        let content = Data("lnfs".utf8)
        try fs.writeFile(path: "short.txt", data: content)
        try fs.flush()

        let longName = "a-considerably-longer-file-name-than-thirty.txt"
        XCTAssertGreaterThan(longName.count, 30)
        try fs.rename(path: "short.txt", to: longName)
        try fs.flush()

        let fs2 = try openFS(imgURL: imgURL)
        XCTAssertEqual(try fs2.listDirectory().map(\.name), [longName])
        XCTAssertEqual(try fs2.readFile(path: longName), content)
    }
}
