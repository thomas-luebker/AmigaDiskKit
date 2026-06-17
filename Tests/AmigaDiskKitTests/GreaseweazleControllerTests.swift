import XCTest
@testable import AmigaDiskKit

/// Simulates Greaseweazle firmware: parses command packets, tracks the
/// selected cylinder/head, and serves ReadFlux from a reference ADF so the
/// controller + readDisk path can be exercised with no hardware.
final class MockGreaseweazleTransport: GreaseweazleTransport {
    private let referenceADF: Data
    private let geometry: AmigaFloppyGeometry
    let sampleFreq = 72_000_000.0

    private var out: [UInt8] = []           // bytes pending for the host to read
    private var cyl = 0, head = 0
    private var expectingFluxStream = false
    private var fluxStreamBuffer: [UInt8] = []
    private(set) var writtenTracks: [Int: [Int]] = [:]   // track -> flux ticks

    init(referenceADF: Data, geometry: AmigaFloppyGeometry) {
        self.referenceADF = referenceADF
        self.geometry = geometry
    }

    func resetComms() throws { out.removeAll() }

    func write(_ bytes: [UInt8]) throws {
        if expectingFluxStream {
            fluxStreamBuffer.append(contentsOf: bytes)
            if fluxStreamBuffer.last == 0 {
                let decoded = FluxStreamCodec.decode(fluxStreamBuffer)
                writtenTracks[cyl * geometry.heads + head] = decoded.flux
                expectingFluxStream = false
                fluxStreamBuffer.removeAll()
                out.append(0)  // firmware sync byte after the stream
            }
            return
        }
        handleCommand(bytes)
    }

    func readExactly(_ count: Int) throws -> [UInt8] {
        guard out.count >= count else { throw GWError.shortRead(expected: count, got: out.count) }
        let slice = Array(out.prefix(count))
        out.removeFirst(count)
        return slice
    }

    func readAvailable() throws -> [UInt8] {
        let all = out; out.removeAll(); return all
    }

    private func ack(_ cmd: UInt8) { out.append(cmd); out.append(GWAck.okay.rawValue) }

    private func handleCommand(_ p: [UInt8]) {
        guard let cmd = GWCmd(rawValue: p[0]) else { return }
        switch cmd {
        case .getInfo:
            ack(p[0])
            var info = [UInt8](repeating: 0, count: 32)
            info[0] = 1; info[1] = 30           // fw 1.30
            info[2] = 1; info[3] = 22           // is_main, max_cmd
            let f = UInt32(sampleFreq)
            info[4] = UInt8(f & 0xFF); info[5] = UInt8(f >> 8 & 0xFF)
            info[6] = UInt8(f >> 16 & 0xFF); info[7] = UInt8(f >> 24 & 0xFF)
            info[8] = 1                          // hw_model F1
            out.append(contentsOf: info)
        case .seek:
            cyl = Int(Int8(bitPattern: p[2])); ack(p[0])
        case .head:
            head = Int(p[2]); ack(p[0])
        case .readFlux:
            ack(p[0])
            let track = cyl * geometry.heads + head
            let ticks = ADFFloppyImage.encodeTrackFlux(adf: referenceADF, trackNumber: track,
                                                       sampleFreq: sampleFreq, geometry: geometry)
            out.append(contentsOf: FluxStreamCodec.encode(ticks))   // already 0-terminated
        case .writeFlux:
            ack(p[0]); expectingFluxStream = true
        case .setBusType, .select, .deselect, .motor, .getFluxStatus, .reset:
            ack(p[0])
        default:
            ack(p[0])
        }
    }
}

final class GreaseweazleControllerTests: XCTestCase {

    private func smallGeometry() -> AmigaFloppyGeometry {
        // 2 cyl × 2 heads keeps the round-trip fast in Debug.
        AmigaFloppyGeometry(cylinders: 2, heads: 2, format: .dd, timing: .dd)
    }

    private func referenceADF(_ geo: AmigaFloppyGeometry) -> Data {
        var adf = Data(count: geo.totalBytes)
        for i in 0 ..< adf.count { adf[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
        return adf
    }

    func testConnectParsesInfo() throws {
        let geo = smallGeometry()
        let ctrl = GreaseweazleController(transport:
            MockGreaseweazleTransport(referenceADF: referenceADF(geo), geometry: geo))
        let info = try ctrl.connect()
        XCTAssertEqual(info.firmwareMajor, 1)
        XCTAssertEqual(info.firmwareMinor, 30)
        XCTAssertEqual(info.hwModel, 1)
        XCTAssertEqual(info.sampleFreq, 72_000_000)
    }

    func testReadDiskReconstructsADF() throws {
        let geo = smallGeometry()
        let adf = referenceADF(geo)
        let ctrl = GreaseweazleController(transport:
            MockGreaseweazleTransport(referenceADF: adf, geometry: geo))
        ctrl.config.revolutions = 2
        ctrl.config.motorSpinUpMs = 0
        ctrl.config.settleMs = 0
        try ctrl.connect()
        var seen = 0
        let (read, results) = try ctrl.readDisk(geometry: geo) { _ in seen += 1 }
        XCTAssertEqual(read, adf, "read-back ADF must match the reference disk")
        XCTAssertTrue(results.allSatisfy { $0.isComplete })
        XCTAssertEqual(seen, geo.tracks)
    }

    func testWriteDiskEncodesEveryTrack() throws {
        let geo = smallGeometry()
        let adf = referenceADF(geo)
        let mock = MockGreaseweazleTransport(referenceADF: adf, geometry: geo)
        let ctrl = GreaseweazleController(transport: mock)
        ctrl.config.verifyWrites = false
        ctrl.config.motorSpinUpMs = 0
        ctrl.config.settleMs = 0
        try ctrl.connect()
        try ctrl.writeDisk(adf: adf, geometry: geo)
        XCTAssertEqual(mock.writtenTracks.count, geo.tracks)
        // The flux the controller wrote must decode back to that track's sectors.
        let decoded = ADFFloppyImage.decodeTrack(
            fluxTicks: mock.writtenTracks[0]!, sampleFreq: 72_000_000,
            format: geo.format, timing: geo.timing)
        XCTAssertEqual(decoded.count, geo.format.sectorsPerTrack)
    }

    func testAckErrorSurfaces() throws {
        final class FailingTransport: GreaseweazleTransport {
            func resetComms() throws {}
            func write(_ bytes: [UInt8]) throws {}
            func readExactly(_ count: Int) throws -> [UInt8] {
                // Echo GetInfo cmd but report write-protect.
                [GWCmd.getInfo.rawValue, GWAck.wrprot.rawValue]
            }
            func readAvailable() throws -> [UInt8] { [] }
        }
        let ctrl = GreaseweazleController(transport: FailingTransport())
        XCTAssertThrowsError(try ctrl.getInfo()) { error in
            guard case GWError.ack(_, .wrprot) = error else {
                return XCTFail("expected ack(.wrprot), got \(error)")
            }
        }
    }
}
