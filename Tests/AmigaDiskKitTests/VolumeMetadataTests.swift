import XCTest
@testable import AmigaDiskKit

/// In-place protection / comment editing — the Disk Browser's "Information"
/// window write path. Every case re-OPENS the volume so a passing test proves
/// the change reached the media (and the block checksum survived), not just an
/// in-memory struct.
final class VolumeMetadataTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolumeMetadataTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeFFSImage(dosType: UInt32 = KnownDosType.dos3) throws -> URL {
        let imgURL = tmpDir.appendingPathComponent("ffs-\(dosType).img")
        let layout: DiskLayout = .pureRDB(partitions: [
            PartitionSpec(name: "DH0", dosType: dosType, sizeCylinders: 0,
                          isBootable: false, bootPriority: 0,
                          sectorsPerFSBlock: dosType == KnownDosType.dos7 ? 4 : 1)
        ])
        try DiskBuilder.build(url: imgURL, sizeBytes: 32 * 1024 * 1024, layout: layout)
        let device = try BlockDevice(url: imgURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        try FFSFormatter.format(device: device, sliceStartLBA: 0,
                                partition: rdb.partitionBlocks.first!, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: "DH0"))
        return imgURL
    }

    private func entry(_ fs: AmigaVolumeOperations, _ name: String) throws -> AmigaVolumeEntry {
        try XCTUnwrap(try fs.listEntries(path: "").first { $0.name == name })
    }

    // MARK: - FFS

    func testFFSSetProtectionRoundTrip() throws {
        let img = try makeFFSImage()
        let fs = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs.writeFile(path: "Test", data: Data("hello".utf8))
        try fs.flush()

        // hsparwed: set h+s+p+a (active high) and revoke w+d (active low bits set)
        let newProt: UInt32 = 0x80 | 0x40 | 0x20 | 0x10 | 0x04 | 0x01
        let fs2 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs2.setProtection(path: "Test", protection: newProt)
        try fs2.flush()

        let fs3 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        let e = try entry(fs3, "Test")
        XCTAssertEqual(e.protection, newProt)
        XCTAssertEqual(e.byteSize, 5, "file contents/size must be untouched")
        // data still readable → header checksum stayed valid
        let out = tmpDir.appendingPathComponent("out.bin")
        try fs3.extractToHost(amigaPath: "Test", hostURL: out)
        XCTAssertEqual(try Data(contentsOf: out), Data("hello".utf8))
    }

    func testFFSSetCommentRoundTrip() throws {
        let img = try makeFFSImage()
        let fs = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs.writeFile(path: "Doc", data: Data("x".utf8))
        try fs.makeDirectory(path: "Drawer")
        try fs.flush()

        let fs2 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs2.setComment(path: "Doc", comment: "Written by Amiga Imager")
        try fs2.setComment(path: "Drawer", comment: "A drawer comment")
        try fs2.flush()

        let fs3 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        XCTAssertEqual(try entry(fs3, "Doc").comment, "Written by Amiga Imager")
        XCTAssertEqual(try entry(fs3, "Drawer").comment, "A drawer comment",
                       "directories must support comments too")

        // clearing works
        try fs3.setComment(path: "Doc", comment: "")
        try fs3.flush()
        let fs4 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        XCTAssertEqual(try entry(fs4, "Doc").comment, "")
    }

    func testFFSCommentRefusedOnLongNameFS() throws {
        // DOS\7 (LNFS) stores the long name in the comment area — writing a
        // comment there would corrupt the name, so it must be refused.
        let img = try makeFFSImage(dosType: KnownDosType.dos7)
        let fs = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs.writeFile(path: "LongNamedFile", data: Data("y".utf8))
        try fs.flush()

        XCTAssertThrowsError(try fs.setComment(path: "LongNamedFile", comment: "nope"))
        // …and the name survived the refusal
        let fs2 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        XCTAssertEqual(try entry(fs2, "LongNamedFile").name, "LongNamedFile")
    }

    func testFFSProtectionOnLongNameFSStillWorks() throws {
        let img = try makeFFSImage(dosType: KnownDosType.dos7)
        let fs = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs.writeFile(path: "Script", data: Data("echo".utf8))
        try fs.flush()
        try fs.setProtection(path: "Script", protection: 0x40)   // script bit
        try fs.flush()

        let fs2 = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        let e = try entry(fs2, "Script")
        XCTAssertEqual(e.protection & 0x40, 0x40)
        XCTAssertEqual(e.name, "Script")
    }

    func testFFSCommentTooLongRefused() throws {
        let img = try makeFFSImage()
        let fs = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        try fs.writeFile(path: "F", data: Data())
        try fs.flush()
        XCTAssertThrowsError(try fs.setComment(path: "F", comment: String(repeating: "x", count: 80)))
    }

    // MARK: - PFS3

    /// ~100 MB pure-RDB image with one PDS3 partition, PFS3-formatted.
    private func makePFS3Image() throws -> URL {
        let url = tmpDir.appendingPathComponent("pfs3-\(UUID().uuidString).img")
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

    /// PFS3 rewrites metadata by removing + re-adding the directory entry, so
    /// this asserts the ANODE survived: the file's contents must still read
    /// back byte-identical afterwards.
    func testPFS3SetProtectionPreservesData() throws {
        let img = try makePFS3Image()
        let payload = Data("PFS3 payload — must survive".utf8)
        let vol = try PFS3Volume.open(imageURL: img, partitionName: "DH0")
        try vol.writeFile(path: "Data", data: payload)
        try vol.flush()

        let vol2 = try PFS3Volume.open(imageURL: img, partitionName: "DH0")
        try vol2.setProtection(path: "Data", protection: 0x80 | 0x40 | 0x04)

        let vol3 = try PFS3Volume.open(imageURL: img, partitionName: "DH0")
        let e = try entry(vol3, "Data")
        XCTAssertEqual(e.protection & 0xFF, 0x80 | 0x40 | 0x04)
        let out = tmpDir.appendingPathComponent("pfs3-out.bin")
        try vol3.extractToHost(amigaPath: "Data", hostURL: out)
        XCTAssertEqual(try Data(contentsOf: out), payload, "anode/data must survive the entry rewrite")
    }

    func testPFS3SetCommentRoundTrip() throws {
        let img = try makePFS3Image()
        let vol = try PFS3Volume.open(imageURL: img, partitionName: "DH0")
        try vol.writeFile(path: "Note", data: Data("n".utf8))
        try vol.flush()

        let vol2 = try PFS3Volume.open(imageURL: img, partitionName: "DH0")
        try vol2.setComment(path: "Note", comment: "PFS3 comment")

        let vol3 = try PFS3Volume.open(imageURL: img, partitionName: "DH0")
        XCTAssertEqual(try entry(vol3, "Note").comment, "PFS3 comment")
    }

    func testFFSMissingPathThrows() throws {
        let img = try makeFFSImage()
        let fs = try FFSFileSystem.open(imageURL: img, partitionName: "DH0")
        XCTAssertThrowsError(try fs.setProtection(path: "NoSuchFile", protection: 0))
    }
}
