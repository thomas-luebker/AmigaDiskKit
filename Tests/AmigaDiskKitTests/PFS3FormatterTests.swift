import XCTest
@testable import AmigaDiskKit

/// PFS3Formatter golden tests against hst-imager 1.5.564 fixtures.
///
/// The fixtures were formatted with: 16 surfaces × 63 blocksPerTrack,
/// 2g: lowCyl 2–3954, 8g: lowCyl 2–16229, numBuffers 30, "Workbench"/"Work".
/// The format machinery is deterministic; with `now` pinned to the fixture's
/// creation datestamp the output must be byte-identical.
final class PFS3FormatterTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("binary").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// Zero the local-wall-clock date fields of every rootblockextension ('EX')
    /// sector, so the golden comparison is timezone-independent:
    ///   - volume_date (bytes 22–27): stamped from the wall clock at each
    ///     UpdateDisk; the fixture can carry a 1-tick skew between creation and
    ///     update stamps that a pinned clock cannot reproduce.
    ///   - dd_creationdate (bytes 136–141): hst-amiga stamps this from LOCAL
    ///     `DateTime.Now` (the rootblock creation date uses UTC). It is rewritten
    ///     as soon as the deldir is used, so its exact value depends on the host
    ///     timezone and is not meaningful to compare byte-for-byte.
    /// Everything else must match.
    private func maskWallClockDates(_ data: Data) -> Data {
        var out = data
        for sector in stride(from: 0, to: data.count, by: 512) {
            if data.readBE16(at: sector) == PFS3.extensionBlockID {
                for i in 22 ..< 28 { out[out.startIndex + sector + i] = 0 }    // volume_date
                for i in 136 ..< 142 { out[out.startIndex + sector + i] = 0 }  // dd_creationdate
            }
        }
        return out
    }

    /// Format a fresh image with fixture geometry and return the partition's
    /// first `sectors` sectors (partition starts at LBA lowCyl × 1008 = 2016).
    private func formatNative(highCyl: UInt32, volumeName: String,
                              creation: AmigaDate, sectors: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-fmt-\(UUID().uuidString).img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let totalBytes = Int64(highCyl + 2) * 1008 * 512
        try BlockDevice.createBlank(url: url, sizeBytes: totalBytes)
        let device = try BlockDevice(url: url)

        try PFS3Formatter.format(device: device, sliceStartLBA: 0,
                                 blocksPerTrack: 63, surfaces: 16,
                                 lowCyl: 2, highCyl: highCyl, numBuffers: 30,
                                 spec: PFS3FormatSpec(volumeName: volumeName, now: creation.date))
        return try device.read(at: 2016 * 512, length: sectors * 512)
    }

    func testCalcNumReserved2G() throws {
        let g = PFS3G(device: try BlockDevice(url: dummyImage()), sliceStartLBA: 0,
                      blocksPerTrack: 63, surfaces: 16, lowCyl: 2, highCyl: 3954, numBuffers: 30)
        XCTAssertEqual(g.totalSectors, 3_984_624)
        XCTAssertEqual(PFS3Formatter.calcNumReserved(g, 1024), 41664)
    }

    private func dummyImage() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfs3-dummy-\(UUID().uuidString).img")
        try? Data(count: 1024).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testGolden2GFormat() throws {
        let goldenRaw = try fixture("pfs3-2g-reserved-area.bin")
        let golden = maskWallClockDates(goldenRaw)
        let goldenRoot = try PFS3RootBlock(data: golden.subdata(in: 2 * 512 ..< 3 * 512))
        let creation = AmigaDate(days: UInt32(goldenRoot.creationDay),
                                 minutes: UInt32(goldenRoot.creationMinute),
                                 ticks: UInt32(goldenRoot.creationTick))

        let native = maskWallClockDates(try formatNative(highCyl: 3954, volumeName: "Workbench",
                                                      creation: creation, sectors: 1024))

        if native != golden {
            // Pinpoint the first differing sector for diagnosis.
            for sector in 0 ..< 1024 {
                let a = native.subdata(in: sector * 512 ..< (sector + 1) * 512)
                let b = golden.subdata(in: sector * 512 ..< (sector + 1) * 512)
                if a != b {
                    let offset = zip(a, b).enumerated().first(where: { $1.0 != $1.1 })!.offset
                    XCTFail("first difference in partition sector \(sector) at byte \(offset): " +
                            "native \(String(format: "%02x", a[a.startIndex + offset])) vs " +
                            "golden \(String(format: "%02x", b[b.startIndex + offset]))")
                    break
                }
            }
        }
        XCTAssertEqual(native, golden, "2 GB PFS3 format must be byte-identical to hst-imager")
    }

    func testGolden8GSupermodeFormat() throws {
        let goldenRaw = try fixture("pfs3-8g-reserved-area.bin")
        let golden = maskWallClockDates(goldenRaw)
        let goldenRoot = try PFS3RootBlock(data: golden.subdata(in: 2 * 512 ..< 3 * 512))
        XCTAssertTrue(goldenRoot.options.contains(.superIndex))
        let creation = AmigaDate(days: UInt32(goldenRoot.creationDay),
                                 minutes: UInt32(goldenRoot.creationMinute),
                                 ticks: UInt32(goldenRoot.creationTick))

        let native = maskWallClockDates(try formatNative(highCyl: 16229, volumeName: "Work",
                                                      creation: creation, sectors: 4096))

        if native != golden {
            for sector in 0 ..< 4096 {
                let a = native.subdata(in: sector * 512 ..< (sector + 1) * 512)
                let b = golden.subdata(in: sector * 512 ..< (sector + 1) * 512)
                if a != b {
                    let offset = zip(a, b).enumerated().first(where: { $1.0 != $1.1 })!.offset
                    XCTFail("first difference in partition sector \(sector) at byte \(offset): " +
                            "native \(String(format: "%02x", a[a.startIndex + offset])) vs " +
                            "golden \(String(format: "%02x", b[b.startIndex + offset]))")
                    break
                }
            }
        }
        XCTAssertEqual(native, golden, "8 GB supermode PFS3 format must be byte-identical to hst-imager")
    }
}
