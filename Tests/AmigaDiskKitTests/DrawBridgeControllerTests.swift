import XCTest
@testable import AmigaDiskKit

/// Simulates DrawBridge firmware: answers the version handshake, tracks the
/// selected cylinder/head, serves '<' reads packed from a reference ADF, and
/// drives the '>' write handshake — so the controller + whole-disk paths run
/// with no hardware.
final class MockDrawBridgeTransport: SerialByteTransport {
    private let referenceADF: Data
    private let geometry: AmigaFloppyGeometry
    let major: Int, minor: Int, fullControl: Bool, fluxFlag: Bool

    private var out: [UInt8] = []
    private var cyl = 0, head = 0

    private enum WriteState { case normal, header, data(remaining: Int) }
    private var state: WriteState = .normal
    private var dataBuffer: [UInt8] = []
    private(set) var writtenTracks: [Int: [UInt8]] = [:]   // track -> MFM cells

    init(referenceADF: Data, geometry: AmigaFloppyGeometry,
         major: Int = 1, minor: Int = 9, fullControl: Bool = true, fluxFlag: Bool = true) {
        self.referenceADF = referenceADF
        self.geometry = geometry
        self.major = major; self.minor = minor
        self.fullControl = fullControl; self.fluxFlag = fluxFlag
    }

    func resetComms() throws { out.removeAll(); state = .normal; dataBuffer.removeAll() }

    func readExactly(_ count: Int) throws -> [UInt8] {
        guard out.count >= count else { throw DBError.unexpectedStatus(cmd: 0, got: 0) }
        let slice = Array(out.prefix(count)); out.removeFirst(count); return slice
    }

    func readAvailable() throws -> [UInt8] { let all = out; out.removeAll(); return all }

    func write(_ bytes: [UInt8]) throws {
        switch state {
        case .header:
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            out.append(DBStatus.writeGo)            // '!'
            state = .data(remaining: length)
        case .data(let remaining):
            dataBuffer.append(contentsOf: bytes)
            if dataBuffer.count >= remaining {
                writtenTracks[cyl * geometry.heads + head] = dataBuffer
                dataBuffer.removeAll()
                out.append(DBStatus.ok)             // '1'
                state = .normal
            }
        case .normal:
            handle(bytes)
        }
    }

    private func packedTrack(_ track: Int) -> [UInt8] {
        let sectors = ADFFloppyImage.trackSectors(adf: referenceADF, trackNumber: track,
                                                  geometry: geometry)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: track,
                                         format: geometry.format)
        return DrawBridgeMFM.pack(cells)
    }

    private func handle(_ p: [UInt8]) {
        switch p[0] {
        case DBCmd.version:
            out.append(contentsOf: [0x31, 0x56, UInt8(0x30 + major),
                                    fullControl ? 0x2C : 0x2E, UInt8(0x30 + minor)])
            if major > 1 || (major == 1 && minor >= 9) {
                out.append(contentsOf: [fluxFlag ? 1 : 0, 0, 0])
            }
        case DBCmd.rewind:
            cyl = 0; out.append(DBStatus.ok)
        case DBCmd.seek:
            cyl = Int(p[1] - 0x30) * 10 + Int(p[2] - 0x30); out.append(DBStatus.ok)
        case DBCmd.headUpper: head = 0; out.append(DBStatus.ok)
        case DBCmd.headLower: head = 1; out.append(DBStatus.ok)
        case DBCmd.motorOn, DBCmd.motorOff: out.append(DBStatus.ok)
        case DBCmd.diskPresent: out.append(DBStatus.ok)
        case DBCmd.readTrack:
            out.append(contentsOf: packedTrack(cyl * geometry.heads + head))
        case DBCmd.writeTrack:
            out.append(DBStatus.writeReady); state = .header
        default:
            out.append(DBStatus.ok)
        }
    }
}

final class DrawBridgeControllerTests: XCTestCase {

    private func smallGeometry() -> AmigaFloppyGeometry {
        AmigaFloppyGeometry(cylinders: 2, heads: 2, format: .dd, timing: .dd)
    }

    private func referenceADF(_ geo: AmigaFloppyGeometry) -> Data {
        var adf = Data(count: geo.totalBytes)
        for i in 0 ..< adf.count { adf[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
        return adf
    }

    func testPackUnpackRoundTrip() {
        let cells: [UInt8] = (0 ..< 64).map { UInt8(($0 &* 37 &+ 5) & 0xFF) }
        XCTAssertEqual(DrawBridgeMFM.unpack(DrawBridgeMFM.pack(cells)), cells)
    }

    func testConnectParsesVersion() throws {
        let geo = smallGeometry()
        let ctrl = DrawBridgeController(transport:
            MockDrawBridgeTransport(referenceADF: referenceADF(geo), geometry: geo,
                                    major: 1, minor: 9, fullControl: true, fluxFlag: true))
        let fw = try ctrl.connect()
        XCTAssertEqual(fw.major, 1)
        XCTAssertEqual(fw.minor, 9)
        XCTAssertTrue(fw.fullControlMod)
        XCTAssertTrue(fw.supportsFlux)
        XCTAssertEqual(ctrl.deviceDescription, "DrawBridge v1.9 (full-control)")
    }

    func testOldFirmwareReportsNoFlux() throws {
        let geo = smallGeometry()
        let ctrl = DrawBridgeController(transport:
            MockDrawBridgeTransport(referenceADF: referenceADF(geo), geometry: geo,
                                    major: 1, minor: 7, fullControl: false, fluxFlag: false))
        let fw = try ctrl.connect()
        XCTAssertFalse(fw.supportsFlux)
        XCTAssertFalse(ctrl.supportsFlux)
    }

    func testReadDiskReconstructsADF() throws {
        let geo = smallGeometry()
        let adf = referenceADF(geo)
        let ctrl = DrawBridgeController(transport:
            MockDrawBridgeTransport(referenceADF: adf, geometry: geo))
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
        let mock = MockDrawBridgeTransport(referenceADF: adf, geometry: geo)
        let ctrl = DrawBridgeController(transport: mock)
        ctrl.config.verifyWrites = false
        ctrl.config.motorSpinUpMs = 0
        ctrl.config.settleMs = 0
        try ctrl.connect()
        try ctrl.writeDisk(adf: adf, geometry: geo)
        XCTAssertEqual(mock.writtenTracks.count, geo.tracks)
        // The cells the controller wrote must decode back to that track's sectors.
        let cells = DrawBridgeMFM.unpack(DrawBridgeMFM.pack(mock.writtenTracks[0]!))
        let decoded = AmigaMFM.decodeTrack(cells, format: geo.format)
        XCTAssertEqual(decoded.count, geo.format.sectorsPerTrack)
    }

    func testWriteDiskWithVerify() throws {
        let geo = smallGeometry()
        let adf = referenceADF(geo)
        let ctrl = DrawBridgeController(transport:
            MockDrawBridgeTransport(referenceADF: adf, geometry: geo))
        ctrl.config.verifyWrites = true
        ctrl.config.motorSpinUpMs = 0
        ctrl.config.settleMs = 0
        try ctrl.connect()
        var allVerified = true
        try ctrl.writeDisk(adf: adf, geometry: geo) { p in
            if p.sectorsFound < p.sectorsExpected { allVerified = false }
        }
        XCTAssertTrue(allVerified, "verify read-back should find every sector")
    }

    func testSCPNotSupported() throws {
        let geo = smallGeometry()
        let ctrl = DrawBridgeController(transport:
            MockDrawBridgeTransport(referenceADF: referenceADF(geo), geometry: geo))
        try ctrl.connect()
        XCTAssertThrowsError(try ctrl.readSCP(cylinders: 2, heads: 2)) { error in
            guard case DBError.fluxNotSupported = error else {
                return XCTFail("expected fluxNotSupported, got \(error)")
            }
        }
    }
}
