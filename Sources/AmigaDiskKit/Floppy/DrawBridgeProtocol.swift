import Foundation

// MARK: - DrawBridge (Arduino Amiga Floppy Reader/Writer) host protocol
//
// Pure-Swift driver for Robert Smith's DrawBridge firmware (the
// ArduinoFloppyReader / waffle family). DrawBridge speaks a different serial
// protocol from the Greaseweazle, but it drives the same 3.5" Amiga drive, so
// it conforms to the shared `FloppyDevice` and reuses the same codec stack:
// `AmigaMFM` (sector <-> MFM cells), `ADFFloppyImage` (whole-disk assembly).
//
// Wire protocol (ArduinoInterface.cpp / FloppyDriveController.ino, 2M baud):
//   '?'  version    -> "1V<major><sep><minor>"  (sep ',' = full-control mod;
//                       V1.9+ appends deviceFlags1/2 + build)
//   '.'  rewind to track 0          -> '1' ok / '#' fail
//   '='  seek to absolute track     -> [cmd][2 ASCII digits][dir flag];
//                                       '1' moved / '2' already there / '0' err
//   '['  select head 0 (upper)      -> '1'
//   ']'  select head 1 (lower)      -> '1'
//   '+'  motor on (wait to spin up) -> '1'
//   '-'  motor off                  -> '1'
//   '^'  disk present?              -> '1' present / '#' none
//   '<'  read track (DD)            -> 2-bit-packed MFM cells, 0x00 terminator
//   '{'  read track stream (flux/HD)
//   '>'  write track                -> 'Y' ready / 'N' write-protected, then
//                                       [len hi][len lo][index flag], '!' go,
//                                       <data>, '1' ok / 'X','Y','Z' errors
//
// IMPORTANT (hardware bring-up): the exact command bytes above and the 2-bit
// cell packing in `DrawBridgeMFM` are pinned to the firmware reference but have
// NOT yet been validated against real DrawBridge hardware (the Greaseweazle
// path was likewise mock-built first, then hardware-validated). Re-verify the
// command set and `DrawBridgeMFM.unpack`/`pack` against the firmware's
// `unpack()`/`pack()` before relying on a physical read/write.

public enum DBCmd {
    public static let version: UInt8 = 0x3F        // '?'
    public static let rewind: UInt8 = 0x2E         // '.'
    public static let seek: UInt8 = 0x3D           // '='
    public static let headUpper: UInt8 = 0x5B      // '['  head 0
    public static let headLower: UInt8 = 0x5D      // ']'  head 1
    public static let motorOn: UInt8 = 0x2B        // '+'
    public static let motorOff: UInt8 = 0x2D       // '-'
    public static let diskPresent: UInt8 = 0x5E    // '^'
    public static let readTrack: UInt8 = 0x3C      // '<'
    public static let readTrackStream: UInt8 = 0x7B // '{'
    public static let writeTrack: UInt8 = 0x3E     // '>'
}

public enum DBStatus {
    public static let ok: UInt8 = 0x31             // '1'
    public static let alreadyThere: UInt8 = 0x32   // '2'
    public static let error: UInt8 = 0x30          // '0'
    public static let noDisk: UInt8 = 0x23         // '#'
    public static let writeReady: UInt8 = 0x59     // 'Y'
    public static let writeProtected: UInt8 = 0x4E // 'N'
    public static let writeGo: UInt8 = 0x21        // '!'
}

public struct DBFirmware: Sendable {
    public let major: Int
    public let minor: Int
    /// The "full control" hardware mod (comma separator in the version string).
    public let fullControlMod: Bool
    /// Firmware streams raw flux (V1.8+ flux/stream commands present).
    public let supportsFlux: Bool

    public var description: String {
        "DrawBridge v\(major).\(minor)\(fullControlMod ? " (full-control)" : "")"
    }
}

public enum DBError: LocalizedError {
    case notConnected
    case badVersionResponse([UInt8])
    case unexpectedStatus(cmd: UInt8, got: UInt8)
    case seekFailed(track: Int)
    case writeProtected
    case writeFailed(UInt8)
    case fluxNotSupported

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "DrawBridge not connected"
        case .badVersionResponse(let b): return "DrawBridge: bad version reply \(b)"
        case .unexpectedStatus(let c, let g):
            return "DrawBridge command \(Character(UnicodeScalar(c))) returned \(g)"
        case .seekFailed(let t): return "DrawBridge: seek to track \(t) failed"
        case .writeProtected: return "The floppy is write-protected"
        case .writeFailed(let s): return "DrawBridge write failed (status \(s))"
        case .fluxNotSupported:
            return "Raw flux/SCP imaging is not yet supported on DrawBridge"
        }
    }
}

/// User-tunable drive behavior (DrawBridge is single-drive, so no unit field).
public struct DrawBridgeConfig: Sendable {
    /// Extra whole-track re-reads when sectors are still missing.
    public var trackRetries: Int = 2
    /// Wait after motor-on before the first access (ms). DrawBridge's '+'
    /// already blocks for spin-up, so this is a small safety margin.
    public var motorSpinUpMs: Int = 100
    /// Wait after a seek / head change before reading (ms).
    public var settleMs: Int = 15
    public var verifyWrites: Bool = true

    public init() {}
}

public final class DrawBridgeController: FloppyDevice {
    private let transport: SerialByteTransport
    public private(set) var firmware: DBFirmware?
    public var config = DrawBridgeConfig()

    public init(transport: SerialByteTransport, config: DrawBridgeConfig = .init()) {
        self.transport = transport
        self.config = config
    }

    // MARK: - FloppyDevice

    public var deviceDescription: String { firmware?.description ?? "DrawBridge" }
    public var supportsFlux: Bool { firmware?.supportsFlux ?? false }

    public func connectDevice() throws { _ = try connect() }

    // MARK: - Command plumbing

    /// Send a single command byte and read back one status byte.
    @discardableResult
    private func command(_ cmd: UInt8) throws -> UInt8 {
        try transport.write([cmd])
        return try transport.readExactly(1)[0]
    }

    /// Send a command and require it to ack with `expected` (default '1').
    private func commandExpect(_ cmd: UInt8, _ expected: UInt8 = DBStatus.ok) throws {
        let got = try command(cmd)
        guard got == expected else { throw DBError.unexpectedStatus(cmd: cmd, got: got) }
    }

    private func sleepMs(_ ms: Int) {
        if ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000.0) }
    }

    // MARK: - Session

    @discardableResult
    public func connect() throws -> DBFirmware {
        try transport.resetComms()
        let fw = try readVersion()
        self.firmware = fw
        return fw
    }

    public func readVersion() throws -> DBFirmware {
        try transport.write([DBCmd.version])
        // "1V<major><sep><minor>" — five bytes.
        let r = try transport.readExactly(5)
        guard r[0] == 0x31, r[1] == 0x56 else { throw DBError.badVersionResponse(r) }
        let major = Int(r[2]) - 0x30
        let minor = Int(r[4]) - 0x30
        let fullControl = r[3] == 0x2C            // ','
        // V1.9+ advertises flux/stream support and appends 3 flag bytes; drain
        // them so they don't desync the next command.
        var supportsFlux = (major > 1) || (major == 1 && minor >= 8)
        if (major > 1) || (major == 1 && minor >= 9) {
            let flags = try transport.readExactly(3)
            // deviceFlags1 bit 0 conventionally marks the flux-capable build.
            supportsFlux = supportsFlux && (flags[0] & 0x01) != 0
        }
        return DBFirmware(major: major, minor: minor,
                          fullControlMod: fullControl, supportsFlux: supportsFlux)
    }

    // MARK: - Mechanics

    public func rewind() throws {
        let got = try command(DBCmd.rewind)
        guard got == DBStatus.ok else { throw DBError.seekFailed(track: 0) }
    }

    /// Seek to an absolute cylinder (DrawBridge seeks the whole head assembly;
    /// head selection is separate).
    public func seek(track: Int) throws {
        // [cmd][2 ASCII digits][direction flag '0']
        let hi = UInt8(0x30 + (track / 10) % 10)
        let lo = UInt8(0x30 + track % 10)
        try transport.write([DBCmd.seek, hi, lo, 0x30])
        let got = try transport.readExactly(1)[0]
        guard got == DBStatus.ok || got == DBStatus.alreadyThere else {
            throw DBError.seekFailed(track: track)
        }
    }

    public func selectHead(_ head: Int) throws {
        try commandExpect(head == 0 ? DBCmd.headUpper : DBCmd.headLower)
    }

    public func motor(on: Bool) throws {
        try commandExpect(on ? DBCmd.motorOn : DBCmd.motorOff)
    }

    /// True if a disk is in the drive.
    public func diskPresent() throws -> Bool {
        try command(DBCmd.diskPresent) == DBStatus.ok
    }

    // MARK: - Track read/write

    /// Read the current cylinder/head and return on-disk MFM cell bytes
    /// (MSB-first), ready for `AmigaMFM.decodeTrack`.
    public func readTrackCells() throws -> [UInt8] {
        // No leading status byte for the read command in DD mode; the firmware
        // streams packed bytes until a 0x00 terminator.
        try transport.write([DBCmd.readTrack, 0x00])  // index-sync flag off
        var packed: [UInt8] = []
        while true {
            let chunk = try transport.readAvailable()
            if chunk.isEmpty {
                packed.append(contentsOf: try transport.readExactly(1))
            } else {
                packed.append(contentsOf: chunk)
            }
            if packed.last == 0x00 { break }
        }
        return DrawBridgeMFM.unpack(packed)
    }

    /// Write a full track of MFM cell bytes (MSB-first) to the current
    /// cylinder/head.
    public func writeTrackCells(_ cells: [UInt8]) throws {
        let ready = try command(DBCmd.writeTrack)
        if ready == DBStatus.writeProtected { throw DBError.writeProtected }
        guard ready == DBStatus.writeReady else {
            throw DBError.unexpectedStatus(cmd: DBCmd.writeTrack, got: ready)
        }
        let count = cells.count
        try transport.write([UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF), 0x00])
        let go = try transport.readExactly(1)[0]
        guard go == DBStatus.writeGo else {
            throw DBError.unexpectedStatus(cmd: DBCmd.writeTrack, got: go)
        }
        try transport.write(cells)
        let result = try transport.readExactly(1)[0]
        guard result == DBStatus.ok else { throw DBError.writeFailed(result) }
    }

    // MARK: - Whole-disk operations

    private func withMotor<T>(_ body: () throws -> T) throws -> T {
        try motor(on: true)
        sleepMs(config.motorSpinUpMs)
        defer { try? motor(on: false) }
        return try body()
    }

    /// Read a whole disk to an ADF, with per-track retry that merges any newly
    /// recovered sectors (mirrors `GreaseweazleController.readDisk`).
    public func readDisk(geometry: AmigaFloppyGeometry,
                         progress: ((DiskProgress) -> Void)? = nil,
                         isCancelled: () -> Bool = { false }) throws
        -> (adf: Data, results: [TrackReadResult]) {
        guard firmware != nil else { throw DBError.notConnected }
        return try withMotor {
            let spt = geometry.format.sectorsPerTrack
            var tracks: [Int: [Int: AmigaMFM.DecodedSector]] = [:]
            for cyl in 0 ..< geometry.cylinders {
                if isCancelled() { break }
                try seek(track: cyl)
                for h in 0 ..< geometry.heads {
                    if isCancelled() { break }
                    let track = cyl * geometry.heads + h
                    try selectHead(h)
                    sleepMs(config.settleMs)

                    var sectors: [Int: AmigaMFM.DecodedSector] = [:]
                    var attempt = 0
                    repeat {
                        let cells = try readTrackCells()
                        let decoded = AmigaMFM.decodeTrack(cells, format: geometry.format)
                        for (num, sec) in decoded where sectors[num] == nil { sectors[num] = sec }
                        attempt += 1
                    } while sectors.count < spt && attempt <= config.trackRetries && !isCancelled()

                    tracks[track] = sectors
                    progress?(DiskProgress(track: track, totalTracks: geometry.tracks,
                                           sectorsFound: sectors.count, sectorsExpected: spt))
                }
            }
            return ADFFloppyImage.assembleADF(tracks: tracks, geometry: geometry)
        }
    }

    /// Write an ADF to a disk, optionally verifying each track by read-back.
    public func writeDisk(adf: Data, geometry: AmigaFloppyGeometry,
                          progress: ((DiskProgress) -> Void)? = nil,
                          isCancelled: () -> Bool = { false }) throws {
        guard firmware != nil else { throw DBError.notConnected }
        try withMotor {
            for cyl in 0 ..< geometry.cylinders {
                if isCancelled() { break }
                try seek(track: cyl)
                for h in 0 ..< geometry.heads {
                    if isCancelled() { break }
                    let track = cyl * geometry.heads + h
                    try selectHead(h)
                    sleepMs(config.settleMs)

                    let sectors = ADFFloppyImage.trackSectors(adf: adf, trackNumber: track,
                                                              geometry: geometry)
                    let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: track,
                                                     format: geometry.format)
                    try writeTrackCells(cells)

                    var found = geometry.format.sectorsPerTrack
                    if config.verifyWrites {
                        let readback = try readTrackCells()
                        found = AmigaMFM.decodeTrack(readback, format: geometry.format).count
                    }
                    progress?(DiskProgress(track: track, totalTracks: geometry.tracks,
                                           sectorsFound: found,
                                           sectorsExpected: geometry.format.sectorsPerTrack))
                }
            }
        }
    }

    // MARK: - SCP raw flux (deferred)
    //
    // DrawBridge's raw-flux streaming ('{' COMMAND_READTRACKSTREAM) and flux
    // write use the firmware's RotationExtractor sample format, which has not
    // yet been ported. Until then SCP imaging is unsupported on DrawBridge;
    // the app hides the action when `supportsFlux` is false. (A future option
    // is MFM-reconstructed SCP via FluxMFM.encode over the cells we already
    // read, which needs no new firmware format.)

    public func readSCP(cylinders: Int = 80, heads: Int = 2,
                        diskType: UInt8 = SCPImage.amigaDiskType,
                        progress: ((DiskProgress) -> Void)? = nil,
                        isCancelled: () -> Bool = { false }) throws -> Data {
        throw DBError.fluxNotSupported
    }

    public func writeSCP(_ data: Data, heads: Int = 2,
                         progress: ((DiskProgress) -> Void)? = nil,
                         isCancelled: () -> Bool = { false }) throws {
        throw DBError.fluxNotSupported
    }
}

// MARK: - DrawBridge 2-bit MFM cell packing
//
// DrawBridge's DD read returns the MFM cell stream packed 4 codes per byte,
// 2 bits per code (MSB pair first): 0b01 = a 0 cell, 0b10 = a 1 cell,
// 0b00 = end-of-data. `unpack` rebuilds the MSB-first MFM cell bytes that
// `AmigaMFM.decodeTrack` consumes; `pack` is the exact inverse (used by the
// test mock and by write framing if the firmware ever wants packed input).
//
// NOTE: this models the cell stream losslessly so the whole-disk orchestration
// is testable end to end. The real firmware encodes flux *timing buckets*;
// pin this mapping to the firmware `unpack()`/`pack()` during hardware bring-up.

public enum DrawBridgeMFM {
    private static let cellZero: UInt8 = 0b01
    private static let cellOne: UInt8 = 0b10
    private static let endCode: UInt8 = 0b00

    public static func unpack(_ packed: [UInt8]) -> [UInt8] {
        var bits = BitWriter()
        outer: for byte in packed {
            for pair in 0 ..< 4 {
                let code = (byte >> UInt8((3 - pair) * 2)) & 0b11
                switch code {
                case cellZero: bits.append(0)
                case cellOne: bits.append(1)
                default: break outer   // endCode (or padding) terminates
                }
            }
        }
        return bits.bytes()
    }

    public static func pack(_ cells: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var acc: UInt8 = 0
        var filled = 0
        func emit(_ code: UInt8) {
            acc = (acc << 2) | code
            filled += 1
            if filled == 4 { out.append(acc); acc = 0; filled = 0 }
        }
        let totalBits = cells.count * 8
        for i in 0 ..< totalBits {
            let bit = (cells[i >> 3] >> UInt8(7 - (i & 7))) & 1
            emit(bit == 1 ? cellOne : cellZero)
        }
        emit(endCode)
        // Flush any partial byte left-justified; trailing 00 codes read as end.
        if filled > 0 { out.append(acc << UInt8((4 - filled) * 2)) }
        return out
    }
}
