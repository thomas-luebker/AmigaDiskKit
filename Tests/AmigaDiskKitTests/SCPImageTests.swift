import XCTest
@testable import AmigaDiskKit

final class SCPImageTests: XCTestCase {

    func testFluxWordRoundTrip() {
        // Small typical values + one overflow (> 65535).
        let cells = [80, 160, 240, 320, 65535, 70000, 131072 + 5]
        let bytes = SCPImage.encodeFlux(cells)
        var data = Data([0, 0])              // pad so start index > 0 is exercised
        data.append(contentsOf: bytes)
        let back = SCPImage.decodeFlux(data, start: 2, count: cells.count)
        XCTAssertEqual(back, cells)
    }

    func testImageRoundTrip() {
        let trackA = SCPTrack(trackNumber: 0,
                              revolutions: [[100, 200, 300], [110, 190, 305]],
                              indexTimes: [600, 605])
        let trackB = SCPTrack(trackNumber: 3,
                              revolutions: [[150, 150], [148, 152]],
                              indexTimes: [300, 300])
        let data = SCPImage.encode(tracks: [trackA, trackB])

        // Header sanity.
        XCTAssertEqual(Array(data.prefix(3)), Array("SCP".utf8))
        XCTAssertEqual(data[4], SCPImage.amigaDiskType)
        XCTAssertEqual(data[5], 2)   // revolutions

        let decoded = try! XCTUnwrap(SCPImage.decode(data))
        XCTAssertEqual(decoded.tracks.count, 2)
        XCTAssertEqual(decoded.tracks[0]?.revolutions, trackA.revolutions)
        XCTAssertEqual(decoded.tracks[0]?.indexTimes, trackA.indexTimes)
        XCTAssertEqual(decoded.tracks[3]?.revolutions, trackB.revolutions)
        XCTAssertNil(decoded.tracks[1])
    }

    func testChecksum() {
        let data = SCPImage.encode(tracks: [
            SCPTrack(trackNumber: 0, revolutions: [[100, 200]], indexTimes: [300])
        ])
        let stored = UInt32(data[0x0C]) | UInt32(data[0x0D]) << 8
                   | UInt32(data[0x0E]) << 16 | UInt32(data[0x0F]) << 24
        let computed = data[0x10...].reduce(UInt32(0)) { $0 &+ UInt32($1) }
        XCTAssertEqual(stored, computed)
    }

    func testDeviceTickConversionRoundTrip() {
        let freq = 72_000_000.0
        // 2µs DD cell at 72 MHz ≈ 144 device ticks → ~80 SCP (25ns) ticks.
        let scp = SCPImage.scpTicks(deviceTicks: 144, sampleFreq: freq, resolution: 0)
        XCTAssertEqual(scp, 80)
        let back = SCPImage.deviceTicks(scpTicks: scp, sampleFreq: freq, resolution: 0)
        XCTAssertEqual(back, 144, accuracy: 2)
    }
}
