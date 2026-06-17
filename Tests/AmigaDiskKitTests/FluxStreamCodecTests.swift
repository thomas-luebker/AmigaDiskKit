import XCTest
@testable import AmigaDiskKit

final class FluxStreamCodecTests: XCTestCase {

    /// Direct (1–249) and two-byte (250–1524) ranges must round-trip exactly.
    func testEncodeDecodeRoundTrip_directAndTwoByte() {
        let values = Array(1...249) + Array(stride(from: 250, through: 1524, by: 7))
        let stream = FluxStreamCodec.encode(values)
        XCTAssertEqual(stream.last, 0, "stream must be 0-terminated")
        let decoded = FluxStreamCodec.decode(stream)
        XCTAssertEqual(decoded.flux, values)
        XCTAssertTrue(decoded.indexTicks.isEmpty)
    }

    /// Boundary values around the 249/250 and 254/255 transitions.
    func testBoundaryValues() {
        let values = [1, 249, 250, 251, 504, 505, 1524]
        let decoded = FluxStreamCodec.decode(FluxStreamCodec.encode(values))
        XCTAssertEqual(decoded.flux, values)
    }

    /// A crafted stream with an index opcode: the index position is the
    /// running tick total at the point the opcode appears.
    func testIndexOpcodeDecoded() {
        // two 100-tick samples, then an Index opcode with 28-bit value 0,
        // then one more 100-tick sample.
        var stream: [UInt8] = [100, 100]
        stream += [255, FluxOp.index, 1, 1, 1, 1]   // 28-bit value 0
        stream += [100, 0]
        let decoded = FluxStreamCodec.decode(stream)
        XCTAssertEqual(decoded.flux, [100, 100, 100])
        XCTAssertEqual(decoded.indexTicks, [200], "index recorded at 200 ticks")
    }

    /// 28-bit pack/unpack via Space carries large gaps.
    func testSpaceOpcodeRoundTrip() {
        // Space adds to the running interval before the next flush.
        var stream: [UInt8] = [255, FluxOp.space]
        // 28-bit value 5000
        let x = 5000
        stream += [UInt8(1 | (x << 1) & 255), UInt8(1 | (x >> 6) & 255),
                   UInt8(1 | (x >> 13) & 255), UInt8(1 | (x >> 20) & 255)]
        stream += [10, 0]   // flush 10 → total interval 5010
        let decoded = FluxStreamCodec.decode(stream)
        XCTAssertEqual(decoded.flux, [5010])
    }
}
