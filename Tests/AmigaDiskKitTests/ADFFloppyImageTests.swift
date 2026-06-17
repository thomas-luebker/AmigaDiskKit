import XCTest
@testable import AmigaDiskKit

final class ADFFloppyImageTests: XCTestCase {

    private let sampleFreq = 72_000_000.0  // typical Greaseweazle F1 sample rate

    /// Full disk: ADF -> per-track flux -> decode -> reassembled ADF identity.
    /// This is the end-to-end read+write pipeline with no hardware.
    func testWholeDiskRoundTrip_DD() {
        let geo = AmigaFloppyGeometry.dd
        // Deterministic pseudo-random ADF.
        var adf = Data(count: geo.totalBytes)
        for i in 0 ..< adf.count { adf[i] = UInt8((i &* 2654435761 >> 13) & 0xFF) }

        var tracks: [Int: [Int: AmigaMFM.DecodedSector]] = [:]
        for track in 0 ..< geo.tracks {
            let flux = ADFFloppyImage.encodeTrackFlux(adf: adf, trackNumber: track,
                                                      sampleFreq: sampleFreq, geometry: geo)
            tracks[track] = ADFFloppyImage.decodeTrack(fluxTicks: flux, sampleFreq: sampleFreq,
                                                       format: geo.format, timing: geo.timing)
        }
        let (rebuilt, results) = ADFFloppyImage.assembleADF(tracks: tracks, geometry: geo)
        XCTAssertEqual(rebuilt.count, geo.totalBytes)
        XCTAssertEqual(rebuilt, adf, "every track must round-trip byte-identical")
        XCTAssertTrue(results.allSatisfy { $0.isComplete })
    }

    func testGeometry() {
        XCTAssertEqual(AmigaFloppyGeometry.dd.totalBytes, 901_120)   // 880 KB
        XCTAssertEqual(AmigaFloppyGeometry.hd.totalBytes, 1_802_240) // 1760 KB
    }

    /// Multi-revolution flux (the real-read case) recovers a sector that is
    /// corrupt in the first revolution but clean in the second.
    func testMultiRevolutionRetry() {
        let geo = AmigaFloppyGeometry.dd
        var adf = Data(count: geo.totalBytes)
        for i in 0 ..< adf.count { adf[i] = UInt8((i &* 7 &+ 3) & 0xFF) }

        let trackNumber = 10
        var rev = ADFFloppyImage.encodeTrackFlux(adf: adf, trackNumber: trackNumber,
                                                 sampleFreq: sampleFreq, geometry: geo)
        // Build a corrupted first revolution + clean second revolution.
        var corrupted = rev
        corrupted[corrupted.count / 2] += 40  // perturb one interval badly
        let twoRevs = corrupted + rev

        let oneRev = ADFFloppyImage.decodeTrack(fluxTicks: corrupted, sampleFreq: sampleFreq,
                                                format: geo.format, timing: geo.timing)
        let multi = ADFFloppyImage.decodeTrack(fluxTicks: twoRevs, sampleFreq: sampleFreq,
                                               format: geo.format, timing: geo.timing)
        XCTAssertEqual(multi.count, geo.format.sectorsPerTrack,
                       "second revolution recovers any sector lost in the first")
        XCTAssertGreaterThanOrEqual(multi.count, oneRev.count)
        _ = rev
    }
}
