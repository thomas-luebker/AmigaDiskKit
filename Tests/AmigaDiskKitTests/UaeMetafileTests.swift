import XCTest
@testable import AmigaDiskKit

final class UaeMetafileTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UaeMetafileTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - mask <-> protection mapping

    func testMaskString_default() {
        // Raw 0 = all RWED allowed, no HSPA → "----rwed"
        XCTAssertEqual(UaeMetafile.maskString(from: 0), "----rwed")
    }

    func testMaskString_pure() {
        // Pure (bit5 = 0x20) set, RWED all allowed.
        XCTAssertEqual(UaeMetafile.maskString(from: 0x20), "--p-rwed")
    }

    func testMaskString_script() {
        // Script (bit6 = 0x40) set.
        XCTAssertEqual(UaeMetafile.maskString(from: 0x40), "-s--rwed")
    }

    func testMaskString_pureReadOnlyDeleteProtected() {
        // The real L/System-startup value observed from the OS 3.2 Modules ADF:
        // Pure + write/exec/delete protected (bits set), read allowed.
        XCTAssertEqual(UaeMetafile.maskString(from: 0x27), "--p-r---")
    }

    func testProtectionFromMask_roundTrip() {
        for raw: UInt32 in [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x27, 0xFF] {
            let mask = UaeMetafile.maskString(from: raw)
            XCTAssertEqual(UaeMetafile.protection(fromMask: mask), raw,
                           "round-trip failed for raw 0x\(String(raw, radix: 16))")
        }
    }

    func testProtectionFromMask_caseInsensitive() {
        XCTAssertEqual(UaeMetafile.protection(fromMask: "--P-R---"), 0x27)
    }

    func testProtectionFromMask_rejectsWrongLength() {
        XCTAssertNil(UaeMetafile.protection(fromMask: "rwed"))
        XCTAssertNil(UaeMetafile.protection(fromMask: "---------"))
    }

    // MARK: - serialize / parse

    func testSerializeParse_roundTrip() {
        let meta = UaeMetafile(protection: 0x27,
                               date: Date(timeIntervalSince1970: 1_000_000),
                               comment: "hello world")
        let line = meta.serialized()
        let parsed = UaeMetafile.parse(line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.protection, 0x27)
        XCTAssertEqual(parsed?.comment, "hello world")
    }

    func testParse_matchesScriptGeneratedFormat() {
        // The shape build-classic.sh wrote for hst: "<mask> <date> " (+newline).
        let parsed = UaeMetafile.parse("--p-r--- 2021-04-13 02:42:50.92 \n")
        XCTAssertEqual(parsed?.protection, 0x27)
    }

    // MARK: - end-to-end FFS copy/extract

    private func makeFFSImage() throws -> URL {
        let imgURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).img")
        let layout: DiskLayout = .pureRDB(partitions: [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos3, sizeCylinders: 0,
                          isBootable: false, bootPriority: 0, sectorsPerFSBlock: 1)
        ])
        try DiskBuilder.build(url: imgURL, sizeBytes: Int64(32 * 1024 * 1024), layout: layout)
        let device = try BlockDevice(url: imgURL)
        let rdb    = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        let part   = rdb.partitionBlocks.first!
        try FFSFormatter.format(device: device, sliceStartLBA: 0, partition: part, rdb: rdb,
                                spec: FFSFormatSpec(volumeName: "DH0"))
        return imgURL
    }

    private func protectionOf(_ imgURL: URL, _ amigaPath: String) throws -> UInt32 {
        let fs = try FFSFileSystem.open(imageURL: imgURL, partitionName: "DH0")
        let parent = amigaPath.contains("/")
            ? String(amigaPath[..<amigaPath.lastIndex(of: "/")!]) : ""
        let name = amigaPath.contains("/")
            ? String(amigaPath[amigaPath.index(after: amigaPath.lastIndex(of: "/")!)...]) : amigaPath
        let entry = try fs.listEntries(path: parent).first { $0.name == name }
        return try XCTUnwrap(entry).protection
    }

    func testCopyFromHost_appliesSidecarProtection() throws {
        let imgURL = try makeFFSImage()
        let hostFile = tmpDir.appendingPathComponent("System-startup")
        try Data("script".utf8).write(to: hostFile)
        try Data("--p-r--- 2021-04-13 02:42:50.92 \n".utf8)
            .write(to: hostFile.appendingPathExtension("uaem"))

        let fs = try FFSFileSystem.open(imageURL: imgURL, partitionName: "DH0")
        try fs.makeDirectory(path: "L")
        try fs.copyFromHost(hostURL: hostFile, amigaPath: "L/System-startup", applyUaeMetadata: true)
        try fs.flush()

        XCTAssertEqual(try protectionOf(imgURL, "L/System-startup"), 0x27)
    }

    func testCopyFromHost_withoutFlag_ignoresSidecar() throws {
        let imgURL = try makeFFSImage()
        let hostFile = tmpDir.appendingPathComponent("plain")
        try Data("x".utf8).write(to: hostFile)
        try Data("--p-r--- 2021-04-13 02:42:50.92 \n".utf8)
            .write(to: hostFile.appendingPathExtension("uaem"))

        let fs = try FFSFileSystem.open(imageURL: imgURL, partitionName: "DH0")
        try fs.copyFromHost(hostURL: hostFile, amigaPath: "plain") // 2-arg = no metadata
        try fs.flush()

        // Non-executable host file → default protection 0.
        XCTAssertEqual(try protectionOf(imgURL, "plain"), 0)
    }

    func testCopyFromHost_directory_skipsSidecarFiles() throws {
        let imgURL = try makeFFSImage()
        let dir = tmpDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: dir.appendingPathComponent("Tool"))
        try Data("--p-rwed 2021-01-01 00:00:00.00 \n".utf8)
            .write(to: dir.appendingPathComponent("Tool.uaem"))

        let fs = try FFSFileSystem.open(imageURL: imgURL, partitionName: "DH0")
        try fs.copyFromHost(hostURL: dir, amigaPath: "payload", applyUaeMetadata: true)
        try fs.flush()

        let fs2 = try FFSFileSystem.open(imageURL: imgURL, partitionName: "DH0")
        let names = try fs2.listEntries(path: "payload").map(\.name).sorted()
        XCTAssertEqual(names, ["Tool"])                      // .uaem not copied
        XCTAssertEqual(try protectionOf(imgURL, "payload/Tool"), 0x20) // Pure applied
    }

    func testExtractThenCopy_preservesProtection() throws {
        // Write a file with a non-trivial protection, extract with sidecars,
        // copy into a fresh image with --uaemetadata, and confirm the bits survive.
        let src = try makeFFSImage()
        let srcFS = try FFSFileSystem.open(imageURL: src, partitionName: "DH0")
        try srcFS.makeDirectory(path: "L")
        try srcFS.writeFile(path: "L/System-startup", data: Data("s".utf8),
                            overwrite: true, protection: 0x27)
        try srcFS.flush()

        let hostOut = tmpDir.appendingPathComponent("extract")
        let srcFS2 = try FFSFileSystem.open(imageURL: src, partitionName: "DH0")
        try srcFS2.extractToHost(amigaPath: "", hostURL: hostOut, writeUaeMetadata: true)

        let sidecar = hostOut.appendingPathComponent("L/System-startup.uaem")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        let dst = try makeFFSImage()
        let dstFS = try FFSFileSystem.open(imageURL: dst, partitionName: "DH0")
        try dstFS.copyFromHost(hostURL: hostOut, amigaPath: "", applyUaeMetadata: true)
        try dstFS.flush()

        XCTAssertEqual(try protectionOf(dst, "L/System-startup"), 0x27)
    }

    // MARK: - PFS3 parity

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

    private func pfs3ProtectionOf(_ url: URL, _ amigaPath: String) throws -> UInt32 {
        let vol = try PFS3Volume.open(imageURL: url, partitionName: "DH0")
        let parent = amigaPath.contains("/")
            ? String(amigaPath[..<amigaPath.lastIndex(of: "/")!]) : ""
        let name = amigaPath.contains("/")
            ? String(amigaPath[amigaPath.index(after: amigaPath.lastIndex(of: "/")!)...]) : amigaPath
        let entry = try vol.listEntries(path: parent).first { $0.name == name }
        return try XCTUnwrap(entry).protection
    }

    func testPFS3_extractThenCopy_preservesProtection() throws {
        let src = try makePFS3Image()
        let srcVol = try PFS3Volume.open(imageURL: src, partitionName: "DH0")
        try srcVol.makeDirectory(path: "L")
        try srcVol.writeFile(path: "L/System-startup", data: Data("s".utf8), protection: 0x27)
        try srcVol.flush()

        let hostOut = tmpDir.appendingPathComponent("pfs3-extract")
        let srcVol2 = try PFS3Volume.open(imageURL: src, partitionName: "DH0")
        try srcVol2.extractToHost(amigaPath: "", hostURL: hostOut, writeUaeMetadata: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: hostOut.appendingPathComponent("L/System-startup.uaem").path))

        let dst = try makePFS3Image()
        let dstVol = try PFS3Volume.open(imageURL: dst, partitionName: "DH0")
        try dstVol.copyFromHost(hostURL: hostOut, amigaPath: "", applyUaeMetadata: true)
        try dstVol.flush()

        XCTAssertEqual(try pfs3ProtectionOf(dst, "L/System-startup") & 0xFF, 0x27)
    }
}
