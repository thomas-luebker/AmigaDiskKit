import XCTest
@testable import AmigaDiskKit

/// FAT32Formatter golden test against hst-imager 1.5.564.
///
/// Fixture: `hst-fat32-system-area.bin` — FAT system area (32 reserved +
/// 2×2042 FAT + 8 root-cluster sectors = 4124 sectors) of the PiStorm boot
/// partition from `hst-imager blank 8000000000` + `format PiStorm Dos3`
/// (partition at LBA 2048, 2,095,105 sectors, label "EMPTY").
final class FAT32FormatTests: XCTestCase {

    private let partitionSectors = 2_095_105
    private let fatSizeSectors = 2042

    /// Wall-clock/heuristic fields that legitimately differ:
    /// boot-sector CHS (DiscUtils geometry heuristic) + volume id, in both
    /// boot copies, and the volume-label entry timestamp.
    private func normalize(_ data: Data) -> Data {
        var out = data
        for bootCopy in [0, 6] {
            let base = out.startIndex + bootCopy * 512
            for i in 0x18 ... 0x1B { out[base + i] = 0 }   // CHS
            for i in 0x43 ... 0x46 { out[base + i] = 0 }   // volume id
        }
        let rootDir = out.startIndex + (32 + 2 * fatSizeSectors) * 512
        for i in 0x16 ... 0x19 { out[rootDir + i] = 0 }    // label entry date/time
        return out
    }

    func testGoldenMatchesHstImager() throws {
        let fixtureURL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("binary/hst-fat32-system-area.bin")
        let golden = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(golden.count, 4124 * 512)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fat32-fmt-\(UUID().uuidString).img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // image only needs to cover the system area
        try BlockDevice.createBlank(url: url, sizeBytes: Int64(2048 + 4200) * 512)
        let device = try BlockDevice(url: url)

        try FAT32Formatter.format(device: device,
                                  partitionOffset: 2048 * 512,
                                  sizeBytes: Int64(partitionSectors) * 512,
                                  volumeLabel: "EMPTY")
        let native = try device.read(at: 2048 * 512, length: 4124 * 512)

        let a = normalize(native), b = normalize(golden)
        if a != b {
            for sector in 0 ..< 4124 {
                let x = a.subdata(in: sector * 512 ..< (sector + 1) * 512)
                let y = b.subdata(in: sector * 512 ..< (sector + 1) * 512)
                if x != y {
                    let off = zip(x, y).enumerated().first(where: { $1.0 != $1.1 })!.offset
                    XCTFail("first difference at sector \(sector) byte \(off): " +
                            "native \(String(format: "%02x", x[x.startIndex + off])) vs " +
                            "golden \(String(format: "%02x", y[y.startIndex + off]))")
                    break
                }
            }
        }
        XCTAssertEqual(a, b, "FAT32 system area must match hst-imager output")
    }

    func testFormattedVolumeMountsWithFAT32Volume() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fat32-mnt-\(UUID().uuidString).img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // small full image: MBR + 64 MiB FAT partition
        let fatSectors: UInt32 = 131072   // 64 MiB
        try DiskBuilder.build(url: url, sizeBytes: Int64(2048 + 131072 + 4096) * 512,
                              layout: .mbrPlusRDB(fatStartLBA: 2048, fatSectorCount: fatSectors,
                                                  rdbStartLBA: 2048 + fatSectors,
                                                  partitions: [PartitionSpec(name: "DH0",
                                                                             dosType: KnownDosType.dos3)]))
        let device = try BlockDevice(url: url)
        // 64 MiB needs small clusters to reach FAT32's 65536-cluster minimum
        try FAT32Formatter.format(device: device, partitionOffset: 2048 * 512,
                                  sizeBytes: Int64(fatSectors) * 512,
                                  volumeLabel: "EMU68BOOT", clusterSize: 512)

        let volume = try FAT32Volume(imageURL: url, mbrIndex: 0)
        try volume.makeDirectory("/Test")
        try volume.copyFromHost(source: writeTempFile("hello fat32"), destination: "/Test/file.txt")
        let volume2 = try FAT32Volume(imageURL: url, mbrIndex: 0, readOnly: true)
        XCTAssertTrue(try volume2.exists("/Test/file.txt"))
    }

    private func writeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fat32-src-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(contents.utf8).write(to: url)
        return url
    }
}
