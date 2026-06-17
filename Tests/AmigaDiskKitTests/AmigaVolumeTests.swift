import XCTest
@testable import AmigaDiskKit

/// `openAmigaVolume` dispatch over an injected device, for both engines.
final class AmigaVolumeTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmigaVolumeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeImage(dosType: UInt32, name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent("vol-\(name).img")
        try DiskBuilder.build(url: url, sizeBytes: 32 * 1024 * 1024, layout: .pureRDB(partitions: [
            PartitionSpec(name: "DH0", dosType: dosType, isBootable: true, sectorsPerFSBlock: 1),
        ]))
        let device = try BlockDevice(url: url)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        if KnownDosType.isPFS3(dosType) {
            try PFS3Formatter.format(device: device, sliceStartLBA: 0,
                                     partition: rdb.partitionBlocks[0], rdb: rdb,
                                     spec: PFS3FormatSpec(volumeName: name))
        } else {
            try FFSFormatter.format(device: device, sliceStartLBA: 0,
                                    partition: rdb.partitionBlocks[0], rdb: rdb,
                                    spec: FFSFormatSpec(volumeName: name))
        }
        return url
    }

    func testOpenWithInjectedDevice_FFS() throws {
        let url = try makeImage(dosType: KnownDosType.dos3, name: "FFSVol")
        let device = try BlockDevice(url: url)
        let volume = try openAmigaVolume(device: device, partitionName: "DH0")
        XCTAssertTrue(volume is FFSFileSystem)

        try volume.makeDirectory(path: "Dir")
        try volume.flush()
        XCTAssertEqual(try volume.listEntries(path: "").map(\.name), ["Dir"])
        XCTAssertEqual(try volume.volumeInfo().volumeName, "FFSVol")
    }

    func testOpenWithInjectedDevice_PFS3() throws {
        let url = try makeImage(dosType: KnownDosType.pds3, name: "PFSVol")
        let device = try BlockDevice(url: url)
        let volume = try openAmigaVolume(device: device, partitionName: "DH0")
        XCTAssertTrue(volume is PFS3Volume)

        try volume.makeDirectory(path: "Dir")
        try volume.flush()
        XCTAssertEqual(try volume.listEntries(path: "").map(\.name), ["Dir"])
        XCTAssertEqual(try volume.volumeInfo().volumeName, "PFSVol")
    }

    func testOpenByURL_readOnlyListsButRejectsWrites() throws {
        let url = try makeImage(dosType: KnownDosType.dos3, name: "ROVol")
        let volume = try openAmigaVolume(imageURL: url, partitionName: "DH0", readOnly: true)
        XCTAssertEqual(try volume.listEntries(path: "").count, 0)
        XCTAssertThrowsError(try volume.makeDirectory(path: "Nope"))
    }
}
