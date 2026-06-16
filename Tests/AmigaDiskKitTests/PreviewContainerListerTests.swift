//
//  PreviewContainerListerTests.swift
//  AmigaDiskKitTests
//
//  Builds a real FFS ADF, writes a small tree, and verifies the container
//  lister enumerates it (and honours the entry budget).
//

import XCTest
@testable import AmigaDiskKit

final class PreviewContainerListerTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Mirrors FFSFileSystemTests.makeADF: a blank 880 KB FFS ADF.
    private func makeADF(volumeName: String = "TestVol") throws -> URL {
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

    func testListsADFTree() throws {
        let url = try makeADF(volumeName: "MyVol")
        let fs = try FFSFileSystem.openADF(url: url, readOnly: false)
        try fs.makeDirectory(path: "S")
        try fs.writeFile(path: "S/Startup-Sequence", data: Data("echo hi\n".utf8))
        try fs.writeFile(path: "ReadMe", data: Data("hello".utf8))
        try fs.flush()

        let listing = try PreviewContainerLister.list(url: url)
        XCTAssertEqual(listing.volumes.count, 1)
        let vol = listing.volumes[0]
        XCTAssertEqual(vol.kind, "ADF")
        XCTAssertEqual(vol.name, "MyVol")

        let names = vol.root.map(\.name)
        XCTAssertTrue(names.contains("S"))
        XCTAssertTrue(names.contains("ReadMe"))

        let sDir = try XCTUnwrap(vol.root.first { $0.name == "S" })
        XCTAssertTrue(sDir.isDirectory)
        XCTAssertTrue(sDir.children.contains { $0.name == "Startup-Sequence" })

        XCTAssertTrue(listing.plainText.contains("Startup-Sequence"))
        XCTAssertFalse(listing.truncated)
    }

    func testIsContainer() {
        XCTAssertTrue(PreviewContainerLister.isContainer(URL(fileURLWithPath: "/x/game.lha")))
        XCTAssertTrue(PreviewContainerLister.isContainer(URL(fileURLWithPath: "/x/disk.ADF")))
        XCTAssertFalse(PreviewContainerLister.isContainer(URL(fileURLWithPath: "/x/pic.iff")))
    }

    func testEntryBudgetTruncates() throws {
        let url = try makeADF()
        let fs = try FFSFileSystem.openADF(url: url, readOnly: false)
        for i in 0..<5 { try fs.writeFile(path: "file\(i)", data: Data([0])) }
        try fs.flush()

        let listing = try PreviewContainerLister.list(url: url, maxEntries: 2)
        XCTAssertTrue(listing.truncated)
        XCTAssertLessThanOrEqual(listing.volumes[0].root.count, 2)
    }
}
