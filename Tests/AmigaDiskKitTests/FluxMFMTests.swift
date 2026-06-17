import XCTest
@testable import AmigaDiskKit

final class FluxMFMTests: XCTestCase {

    private func makeSectors(_ count: Int) -> [[UInt8]] {
        (0 ..< count).map { s in
            (0 ..< AmigaMFM.sectorBytes).map { UInt8((s &* 13 &+ $0) & 0xFF) }
        }
    }

    /// cells -> flux -> cells must be lossless (ignoring trailing zero pad).
    func testFluxRoundTrip_noJitter_DD() {
        let cells = AmigaMFM.encodeTrack(sectors: makeSectors(11), trackNumber: 7, format: .dd)
        let flux = FluxMFM.encode(cells: cells, timing: .dd)
        let back = FluxMFM.decode(fluxSeconds: flux, timing: .dd)
        // Decoded stream must contain every sector intact.
        let decoded = AmigaMFM.decodeTrack(back, format: .dd)
        XCTAssertEqual(decoded.count, 11)
    }

    /// The whole pipeline with realistic timing wobble: a Greaseweazle read
    /// never returns nominal intervals. ±8% per-interval jitter must still
    /// decode every sector through the tracking PLL.
    func testFullPipeline_withJitter_DD() {
        let sectors = makeSectors(11)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 12, format: .dd)
        var rng = SystemRandomNumberGenerator()
        let flux = FluxMFM.encode(cells: cells, timing: .dd).map { interval -> Double in
            let jitter = Double.random(in: -0.08 ... 0.08, using: &rng)
            return interval * (1 + jitter)
        }
        let back = FluxMFM.decode(fluxSeconds: flux, timing: .dd)
        let decoded = AmigaMFM.decodeTrack(back, format: .dd)
        XCTAssertEqual(decoded.count, 11, "all sectors must survive ±8% jitter")
        for s in 0 ..< 11 {
            XCTAssertEqual(decoded[s]?.data, sectors[s])
        }
    }

    func testFullPipeline_withJitter_HD() {
        let sectors = makeSectors(22)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 30, format: .hd)
        var rng = SystemRandomNumberGenerator()
        let flux = FluxMFM.encode(cells: cells, timing: .hd).map { interval -> Double in
            interval * (1 + Double.random(in: -0.06 ... 0.06, using: &rng))
        }
        let back = FluxMFM.decode(fluxSeconds: flux, timing: .hd)
        let decoded = AmigaMFM.decodeTrack(back, format: .hd)
        XCTAssertEqual(decoded.count, 22)
    }

    /// A slow drive (constant +5% slower than nominal) must be tracked.
    func testFullPipeline_constantSpeedOffset() {
        let sectors = makeSectors(11)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 0, format: .dd)
        let flux = FluxMFM.encode(cells: cells, timing: .dd).map { $0 * 1.05 }
        let back = FluxMFM.decode(fluxSeconds: flux, timing: .dd)
        XCTAssertEqual(AmigaMFM.decodeTrack(back, format: .dd).count, 11)
    }
}
