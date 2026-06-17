import XCTest
@testable import AmigaDiskKit

final class AmigaMFMTests: XCTestCase {

    // MARK: - odd/even split

    func testEncodeDecodeRoundTrip() {
        let data = (0 ..< 256).map { UInt8($0 & 0xFF) }
        let enc = AmigaMFM.encode(data)
        XCTAssertEqual(enc.count, data.count * 2)
        // Encoded bytes only ever use the 0x55 data-bit positions.
        XCTAssertTrue(enc.allSatisfy { $0 & 0xAA == 0 })
        XCTAssertEqual(AmigaMFM.decode(enc[...]), data)
    }

    func testChecksumIsInDataBitSpace() {
        let enc = AmigaMFM.encode([UInt8](repeating: 0xA5, count: 64))
        let csum = AmigaMFM.checksum(enc)
        XCTAssertEqual(csum & 0xAAAAAAAA, 0, "checksum must lie in the 0x55555555 space")
    }

    // MARK: - track round trips

    private func makeSectors(_ count: Int, seed: UInt8) -> [[UInt8]] {
        (0 ..< count).map { s in
            (0 ..< AmigaMFM.sectorBytes).map { UInt8((s &* 7 &+ $0 &+ Int(seed)) & 0xFF) }
        }
    }

    func testTrackRoundTrip_DD() {
        let sectors = makeSectors(11, seed: 3)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 4, format: .dd)
        let decoded = AmigaMFM.decodeTrack(cells, format: .dd)
        XCTAssertEqual(decoded.count, 11)
        for s in 0 ..< 11 {
            XCTAssertEqual(decoded[s]?.data, sectors[s], "sector \(s) mismatch")
            XCTAssertEqual(decoded[s]?.trackNumber, 4)
            XCTAssertEqual(decoded[s]?.sectorNumber, s)
        }
    }

    func testTrackRoundTrip_HD() {
        let sectors = makeSectors(22, seed: 9)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 159, format: .hd)
        let decoded = AmigaMFM.decodeTrack(cells, format: .hd)
        XCTAssertEqual(decoded.count, 22)
        for s in 0 ..< 22 {
            XCTAssertEqual(decoded[s]?.data, sectors[s])
        }
    }

    /// A track found at an arbitrary rotational position (sync not at the
    /// stream start, wrapped) must still decode every sector.
    func testTrackRoundTrip_RotatedStart() {
        let sectors = makeSectors(11, seed: 1)
        var cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 0, format: .dd)
        // Prepend junk + rotate so the first sync is partway in.
        let junk = [UInt8](repeating: 0x00, count: 37) + [UInt8](repeating: 0x2A, count: 11)
        cells = junk + cells
        let decoded = AmigaMFM.decodeTrack(cells, format: .dd)
        XCTAssertEqual(decoded.count, 11)
        XCTAssertEqual(decoded[5]?.data, sectors[5])
    }

    /// Corrupting a sector's data must fail its data checksum and drop only
    /// that sector, leaving the rest intact.
    func testCorruptedSectorRejected() {
        let sectors = makeSectors(11, seed: 5)
        var cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: 2, format: .dd)
        // Flip a bit deep inside the stream (within some sector's data).
        cells[5000] ^= 0x01
        let decoded = AmigaMFM.decodeTrack(cells, format: .dd)
        XCTAssertLessThan(decoded.count, 11, "the corrupted sector must be dropped")
        XCTAssertGreaterThan(decoded.count, 0, "other sectors must survive")
    }
}
