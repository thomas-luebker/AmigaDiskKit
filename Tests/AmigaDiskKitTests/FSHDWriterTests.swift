import XCTest
@testable import AmigaDiskKit

/// FSHD/LSEG writer and FileSystemRegistrar tests.
///
/// Golden fixtures (captured from hst-imager 1.5.564, same image):
///   hst-rdbinit-rdb-area.bin  — LBAs 0–79 after `blank 100mb` + `rdb init`
///   hst-fsadd-dos7-rdb-area.bin — same area after `rdb fs add <FastFileSystem 47.4> DOS7
///                                 --name FastFileSystem` (FSHD@1, 63 LSEGs@2–64)
final class FSHDWriterTests: XCTestCase {

    private static let fixturesURL =
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesURL
            .appendingPathComponent("binary").appendingPathComponent(name))
    }

    private func tempImage(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fshd-\(UUID().uuidString).img")
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Reassemble the handler binary from a fixture's FSHD/LSEG chain.
    private func extractEmbeddedBinary(area: Data, fshdLBA: Int) -> Data {
        let fshd = area.subdata(in: fshdLBA * 512 ..< (fshdLBA + 1) * 512)
        var lba = Int(fshd.readBE32(at: 0x48))
        var binary = Data()
        while lba != 0xFFFFFFFF {
            let block = area.subdata(in: lba * 512 ..< (lba + 1) * 512)
            guard block.readBE32(at: 0) == LoadSegBlock.identifier else { break }
            let payloadLongs = Int(block.readBE32(at: 0x04)) - 5
            binary.append(block.subdata(in: 0x14 ..< 0x14 + payloadLongs * 4))
            lba = Int(block.readBE32(at: 0x10))
        }
        return binary
    }

    // MARK: - Golden parity

    func testGoldenMatchesHstImager() throws {
        let before = try fixtureData("hst-rdbinit-rdb-area.bin")
        let after  = try fixtureData("hst-fsadd-dos7-rdb-area.bin")
        // hst-imager embedded FastFileSystem 47.4 (30532 bytes) — recover it
        // from the golden fixture so the test carries no extra binary.
        let ffsBinary = extractEmbeddedBinary(area: after, fshdLBA: 1)
        XCTAssertEqual(ffsBinary.count, 30532)

        let url = try tempImage(before)
        let device = try BlockDevice(url: url)
        let result = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: ffsBinary,
            dosType: KnownDosType.dos7, name: "FastFileSystem")

        XCTAssertEqual(result.fshdLBA, 1)
        XCTAssertEqual(result.lsegCount, 63)
        XCTAssertFalse(result.alreadyRegistered)
        XCTAssertEqual(try Data(contentsOf: url), after,
                       "native rdb-fs-add output must be byte-identical to hst-imager")
    }

    func testGoldenVersionParsedFromBinary() throws {
        let after = try fixtureData("hst-fsadd-dos7-rdb-area.bin")
        let ffsBinary = extractEmbeddedBinary(area: after, fshdLBA: 1)
        // FFS 47.4 — hst-imager wrote 0x002F0004 at FSHD offset 0x24.
        XCTAssertEqual(FileSystemRegistrar.parseAmigaVersionString(ffsBinary), 0x002F0004)
    }

    // MARK: - Round trip on a native image

    private func syntheticBinary(_ size: Int, seed: UInt8 = 0xA5) -> Data {
        var binary = Data((0 ..< size).map { UInt8(($0 &* 31) & 0xFF) ^ seed })
        let ver = Data("$VER: TestFS 12.34 (1.1.2026)\0".utf8)
        binary.replaceSubrange(64 ..< 64 + ver.count, with: ver)
        return binary
    }

    func testRoundTripOnNativeImage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fshd-rt-\(UUID().uuidString).img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try DiskBuilder.build(url: url, sizeBytes: 16 * 1024 * 1024, layout: .pureRDB(partitions: [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos7, isBootable: true),
        ]))

        let binary = syntheticBinary(4000)
        let device = try BlockDevice(url: url)
        let result = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: binary,
            dosType: KnownDosType.dos7, name: "TestFS")

        // PART block occupies LBA 3 on native builds — FSHD must land above it.
        XCTAssertEqual(result.fshdLBA, 4)
        XCTAssertEqual(result.lsegCount, 9)  // ceil(4000 / 492)

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        XCTAssertEqual(rdb.fileSysHdrList, 4)
        XCTAssertEqual(rdb.partitionBlocks.count, 1)
        let fshd = try XCTUnwrap(rdb.fileSystemHeaders.first)
        XCTAssertEqual(fshd.dosType, KnownDosType.dos7)
        XCTAssertEqual(fshd.version, (12 << 16) | 34)
        XCTAssertEqual(fshd.name, "TestFS")
        XCTAssertEqual(fshd.segListBlock, 5)
        XCTAssertEqual(fshd.patchFlags, 0x0180)
        XCTAssertEqual(fshd.globalVec, 0xFFFFFFFF)

        // Every FSHD/LSEG block checksums; payload reassembles byte-for-byte.
        let area = try device.read(at: 0, length: 80 * 512)
        for lba in 4 ... 4 + 9 {
            XCTAssertTrue(verifyAmigaBlockChecksum(area.subdata(in: lba * 512 ..< (lba + 1) * 512)),
                          "checksum invalid at LBA \(lba)")
        }
        XCTAssertEqual(extractEmbeddedBinary(area: area, fshdLBA: 4), binary)
        XCTAssertEqual(area.readBE32(at: 0x98), 13)  // highRDSKBlock = last LSEG
    }

    func testIdempotentReRegistration() throws {
        let before = try fixtureData("hst-rdbinit-rdb-area.bin")
        let url = try tempImage(before)
        let device = try BlockDevice(url: url)
        let binary = syntheticBinary(1000)

        let first = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: binary, dosType: KnownDosType.dos7)
        XCTAssertFalse(first.alreadyRegistered)
        let snapshot = try Data(contentsOf: url)

        let second = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: binary, dosType: KnownDosType.dos7)
        XCTAssertTrue(second.alreadyRegistered)
        XCTAssertEqual(second.fshdLBA, first.fshdLBA)
        XCTAssertEqual(try Data(contentsOf: url), snapshot, "second add must not modify the image")
    }

    func testReplaceExistingRewritesSegList() throws {
        let before = try fixtureData("hst-rdbinit-rdb-area.bin")
        let url = try tempImage(before)
        let device = try BlockDevice(url: url)

        _ = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: syntheticBinary(1000),
            dosType: KnownDosType.dos7)
        let replacement = syntheticBinary(2500, seed: 0x3C)
        let result = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: replacement,
            dosType: KnownDosType.dos7, replaceExisting: true)
        XCTAssertFalse(result.alreadyRegistered)
        XCTAssertEqual(result.fshdLBA, 1, "FSHD slot is reused on replace")

        let area = try device.read(at: 0, length: 80 * 512)
        XCTAssertEqual(extractEmbeddedBinary(area: area, fshdLBA: 1), replacement)
    }

    func testSecondFileSystemAppendsToChain() throws {
        let before = try fixtureData("hst-rdbinit-rdb-area.bin")
        let url = try tempImage(before)
        let device = try BlockDevice(url: url)

        let ffs  = syntheticBinary(1000)
        let pfs3 = syntheticBinary(2000, seed: 0x77)
        let first = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: ffs, dosType: KnownDosType.dos7)
        let second = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: pfs3,
            dosType: KnownDosType.pds3, name: "PFS3All")
        XCTAssertFalse(second.alreadyRegistered)
        XCTAssertGreaterThan(second.fshdLBA, first.fshdLBA)

        let rdb = try RigidDiskBlock.scan(device: BlockDevice(url: url), sliceStartLBA: 0)
        XCTAssertEqual(rdb.fileSystemHeaders.count, 2)
        XCTAssertEqual(rdb.fileSystemHeaders.map(\.dosType),
                       [KnownDosType.dos7, KnownDosType.pds3])
        let area = try device.read(at: 0, length: 80 * 512)
        XCTAssertEqual(extractEmbeddedBinary(area: area, fshdLBA: Int(second.fshdLBA)), pfs3)
    }

    func testReinitPartitionsPreservesChain() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fshd-reinit-\(UUID().uuidString).img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try DiskBuilder.build(url: url, sizeBytes: 32 * 1024 * 1024, layout: .pureRDB(partitions: [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos7),
        ]))
        let binary = syntheticBinary(3000)
        let device = try BlockDevice(url: url)
        let added = try FileSystemRegistrar.addFileSystem(
            device: device, sliceStartLBA: 0, binary: binary, dosType: KnownDosType.dos7)

        try DiskBuilder.reinitPartitions(url: url, sliceStartLBA: 0,
                                         sliceSizeBytes: 32 * 1024 * 1024,
                                         partitions: [
            PartitionSpec(name: "DH0", dosType: KnownDosType.dos7, sizeCylinders: 10, isBootable: true),
            PartitionSpec(name: "DH1", dosType: KnownDosType.dos7),
        ])

        let rdb = try RigidDiskBlock.scan(device: BlockDevice(url: url), sliceStartLBA: 0)
        XCTAssertEqual(rdb.partitionBlocks.count, 2)
        XCTAssertEqual(rdb.fileSystemHeaders.count, 1)
        let chainEnd = Int(added.fshdLBA) + added.lsegCount
        let area = try device.read(at: 0, length: 80 * 512)
        let partLBAs = (1 ..< 80).filter {
            area.readBE32(at: $0 * 512) == PartitionBlock.identifier
        }
        XCTAssertEqual(partLBAs.count, 2)
        for lba in partLBAs {
            XCTAssertGreaterThan(lba, chainEnd,
                                 "PART blocks must be placed above the FSHD/LSEG chain")
        }
        XCTAssertEqual(extractEmbeddedBinary(area: area, fshdLBA: Int(added.fshdLBA)), binary)
    }

    // MARK: - $VER parsing

    func testVersionStringParsing() {
        func ver(_ s: String) -> UInt32? {
            FileSystemRegistrar.parseAmigaVersionString(Data(s.utf8))
        }
        XCTAssertEqual(ver("xx$VER: FastFileSystem 47.4 (1.1.2021)"), 0x002F0004)
        XCTAssertEqual(ver("$VER: pfs3aio 19.2 (4.6.2018)"), (19 << 16) | 2)
        XCTAssertNil(ver("no version marker here"))
        XCTAssertNil(ver("$VER: NameOnly"))
        XCTAssertEqual(FileSystemRegistrar.parseAmigaVersionString(Data([0x00, 0x01])), nil)
    }
}
