import Foundation

// MARK: - Greaseweazle host protocol
//
// Pure-Swift port of the command layer in `greaseweazle/usb.py`. The
// controller drives an injected `GreaseweazleTransport` so it can be unit
// tested against a scripted mock; the app supplies a real serial transport.
// Command framing and the 32-byte GetInfo layout are pinned to the reference.

public enum GWCmd: UInt8 {
    case getInfo = 0, update = 1, seek = 2, head = 3, setParams = 4, getParams = 5
    case motor = 6, readFlux = 7, writeFlux = 8, getFluxStatus = 9, getIndexTimes = 10
    case switchFwMode = 11, select = 12, deselect = 13, setBusType = 14, setPin = 15
    case reset = 16, eraseFlux = 17, sourceBytes = 18, sinkBytes = 19, getPin = 20
    case testMode = 21, noClickStep = 22
}

public enum GWAck: UInt8 {
    case okay = 0, badCommand = 1, noIndex = 2, noTrk0 = 3, fluxOverflow = 4
    case fluxUnderflow = 5, wrprot = 6, noUnit = 7, noBus = 8, badUnit = 9
    case badPin = 10, badCylinder = 11, outOfSRAM = 12, outOfFlash = 13
}

public enum GWBusType: UInt8 {
    case invalid = 0, ibmpc = 1, shugart = 2
}

public struct GWInfo: Sendable {
    public let firmwareMajor: Int
    public let firmwareMinor: Int
    public let isMainFirmware: Bool
    public let maxCmd: Int
    public let sampleFreq: Double      // Hz; flux ticks -> seconds = ticks / sampleFreq
    public let hwModel: Int
    public let hwSubmodel: Int

    public var description: String {
        "Greaseweazle F\(hwModel) fw \(firmwareMajor).\(firmwareMinor) @ \(Int(sampleFreq / 1e6)) MHz"
    }
}

public enum GWError: LocalizedError {
    case ack(GWCmd, GWAck)
    case unexpectedResponse(expected: UInt8, got: UInt8)
    case shortRead(expected: Int, got: Int)
    case notConnected
    case writeProtected

    public var errorDescription: String? {
        switch self {
        case .ack(let cmd, let ack): return "Greaseweazle \(cmd) failed: \(ack)"
        case .unexpectedResponse(let e, let g): return "Greaseweazle: expected reply \(e), got \(g)"
        case .shortRead(let e, let g): return "Greaseweazle: short read (\(g)/\(e))"
        case .notConnected: return "Greaseweazle not connected"
        case .writeProtected: return "The floppy is write-protected"
        }
    }
}

/// Byte transport to a serial device. The app implements this over a serial
/// port; tests use a scripted mock. Shared by the Greaseweazle and DrawBridge
/// controllers (both are USB-serial), so it is named for the transport, not
/// the device.
public protocol SerialByteTransport: AnyObject {
    func write(_ bytes: [UInt8]) throws
    /// Read exactly `count` bytes, blocking up to an internal timeout.
    func readExactly(_ count: Int) throws -> [UInt8]
    /// Read whatever is currently buffered (may be empty), without blocking.
    func readAvailable() throws -> [UInt8]
    /// Clear-comms reset handshake + flush buffers.
    func resetComms() throws
}

/// Back-compat alias for the original Greaseweazle-specific name.
public typealias GreaseweazleTransport = SerialByteTransport

/// User-tunable drive/read/write behavior.
public struct GreaseweazleConfig: Sendable {
    public var busType: GWBusType = .shugart
    public var unit: Int = 0
    public var revolutions: Int = 3
    /// Extra whole-track re-reads when sectors are still missing.
    public var trackRetries: Int = 2
    /// Wait after the motor starts before the first access (ms).
    public var motorSpinUpMs: Int = 750
    /// Wait after a seek/head change before reading (ms).
    public var settleMs: Int = 15
    public var verifyWrites: Bool = true

    public init() {}
}

public final class GreaseweazleController: FloppyDevice {
    private let transport: SerialByteTransport
    public private(set) var info: GWInfo?
    public var config = GreaseweazleConfig()
    public var sampleFreq: Double { info?.sampleFreq ?? 72_000_000 }

    public init(transport: SerialByteTransport, config: GreaseweazleConfig = .init()) {
        self.transport = transport
        self.config = config
    }

    // MARK: - FloppyDevice

    public var deviceDescription: String { info?.description ?? "Greaseweazle" }
    /// Greaseweazle is a flux device end to end.
    public var supportsFlux: Bool { true }
    public func connectDevice() throws { _ = try connect() }

    // MARK: - Command plumbing

    /// Send a command packet and check the 2-byte ack (echoed cmd + ack code).
    private func sendCmd(_ packet: [UInt8]) throws {
        try transport.write(packet)
        let reply = try transport.readExactly(2)
        guard reply[0] == packet[0] else {
            throw GWError.unexpectedResponse(expected: packet[0], got: reply[0])
        }
        guard let ack = GWAck(rawValue: reply[1]), ack == .okay else {
            let cmd = GWCmd(rawValue: packet[0]) ?? .reset
            throw GWError.ack(cmd, GWAck(rawValue: reply[1]) ?? .badCommand)
        }
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - Session

    @discardableResult
    public func connect() throws -> GWInfo {
        try transport.resetComms()
        let info = try getInfo()
        self.info = info
        try setBusType(config.busType)
        return info
    }

    public func getInfo() throws -> GWInfo {
        try sendCmd([GWCmd.getInfo.rawValue, 3, 0])   // sub-op 0 = Firmware
        let d = try transport.readExactly(32)
        // Layout "<4BI4B3H14x": major, minor, is_main, max_cmd, sampleFreq(u32),
        // hw_model, hw_submodel, usb_speed, mcu_id, 3x u16, 14 pad.
        let sampleFreq = UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24
        return GWInfo(firmwareMajor: Int(d[0]), firmwareMinor: Int(d[1]),
                      isMainFirmware: d[2] != 0, maxCmd: Int(d[3]),
                      sampleFreq: Double(sampleFreq),
                      hwModel: Int(d[8]), hwSubmodel: Int(d[9]))
    }

    public func setBusType(_ type: GWBusType) throws {
        try sendCmd([GWCmd.setBusType.rawValue, 3, type.rawValue])
    }

    public func selectDrive(_ unit: Int) throws {
        try sendCmd([GWCmd.select.rawValue, 3, UInt8(unit & 0xFF)])
    }

    public func deselectDrive() throws {
        try sendCmd([GWCmd.deselect.rawValue, 2])
    }

    public func motor(unit: Int, on: Bool) throws {
        try sendCmd([GWCmd.motor.rawValue, 4, UInt8(unit & 0xFF), on ? 1 : 0])
    }

    public func seek(cylinder: Int) throws {
        // 0..127 fits a signed byte; Amiga cyls are 0..79.
        try sendCmd([GWCmd.seek.rawValue, 3, UInt8(bitPattern: Int8(cylinder))])
    }

    public func head(_ head: Int) throws {
        try sendCmd([GWCmd.head.rawValue, 3, UInt8(head & 0xFF)])
    }

    public func reset() throws {
        try sendCmd([GWCmd.reset.rawValue, 2])
    }

    private func fluxStatus() throws {
        try sendCmd([GWCmd.getFluxStatus.rawValue, 2])
    }

    // MARK: - Flux read/write

    /// Read `revs` revolutions of flux from the current cylinder/head.
    public func readFlux(revolutions revs: Int) throws -> DecodedFlux {
        // "<2BIH": cmd, len=8, ticks=0 (read by index), nr_index = revs+1.
        var packet: [UInt8] = [GWCmd.readFlux.rawValue, 8]
        packet += Self.le32(0)
        packet += Self.le16(revs == 0 ? 0 : revs + 1)
        try sendCmd(packet)

        var stream: [UInt8] = []
        while true {
            let chunk = try transport.readAvailable()
            if chunk.isEmpty {
                stream.append(contentsOf: try transport.readExactly(1))
            } else {
                stream.append(contentsOf: chunk)
            }
            if stream.last == 0 { break }
        }
        try fluxStatus()
        return FluxStreamCodec.decode(stream)
    }

    /// Write one revolution of flux (cued and terminated at the index).
    public func writeFlux(_ flux: [Int]) throws {
        try sendCmd([GWCmd.writeFlux.rawValue, 4, 1, 1])  // cue_at_index, terminate_at_index
        let bytes = FluxStreamCodec.encode(flux)
        try transport.write(bytes)
        _ = try transport.readExactly(1)   // firmware sync byte after the stream
        do {
            try fluxStatus()
        } catch GWError.ack(_, .wrprot) {
            throw GWError.writeProtected
        }
    }

    // MARK: - Whole-disk operations

    /// Shared whole-disk progress type (see `FloppyDevice.swift`). Kept as a
    /// nested name for source compatibility with existing call sites.
    public typealias DiskProgress = AmigaDiskKit.DiskProgress

    private func sleepMs(_ ms: Int) {
        if ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000.0) }
    }

    /// Read a whole disk to an ADF, applying the config's revolution count and
    /// per-track retry (re-reads merge any newly recovered sectors).
    public func readDisk(geometry: AmigaFloppyGeometry,
                         progress: ((DiskProgress) -> Void)? = nil,
                         isCancelled: () -> Bool = { false }) throws
        -> (adf: Data, results: [TrackReadResult]) {
        guard info != nil else { throw GWError.notConnected }
        try selectDrive(config.unit)
        try motor(unit: config.unit, on: true)
        sleepMs(config.motorSpinUpMs)
        defer { try? motor(unit: config.unit, on: false); try? deselectDrive() }

        let spt = geometry.format.sectorsPerTrack
        var tracks: [Int: [Int: AmigaMFM.DecodedSector]] = [:]
        for cyl in 0 ..< geometry.cylinders {
            for h in 0 ..< geometry.heads {
                if isCancelled() { break }
                let track = cyl * geometry.heads + h
                try seek(cylinder: cyl)
                try head(h)
                sleepMs(config.settleMs)

                var sectors: [Int: AmigaMFM.DecodedSector] = [:]
                var attempt = 0
                repeat {
                    let flux = try readFlux(revolutions: config.revolutions)
                    let decoded = ADFFloppyImage.decodeTrack(
                        fluxTicks: flux.flux, sampleFreq: sampleFreq,
                        format: geometry.format, timing: geometry.timing)
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

    /// Image a whole disk to raw SCP flux (no decode) — for copy-protected or
    /// non-AmigaDOS disks. `cylinders`/`heads` define the area to scan.
    public func readSCP(cylinders: Int = 80, heads: Int = 2,
                        diskType: UInt8 = SCPImage.amigaDiskType,
                        progress: ((DiskProgress) -> Void)? = nil,
                        isCancelled: () -> Bool = { false }) throws -> Data {
        guard info != nil else { throw GWError.notConnected }
        try selectDrive(config.unit)
        try motor(unit: config.unit, on: true)
        sleepMs(config.motorSpinUpMs)
        defer { try? motor(unit: config.unit, on: false); try? deselectDrive() }

        var scpTracks: [SCPTrack] = []
        let totalTracks = cylinders * heads
        for cyl in 0 ..< cylinders {
            for h in 0 ..< heads {
                if isCancelled() { break }
                let track = cyl * heads + h
                try seek(cylinder: cyl)
                try head(h)
                sleepMs(config.settleMs)
                let flux = try readFlux(revolutions: config.revolutions)
                // One revolution split by index marks; fall back to the whole
                // stream if no index info came back.
                let revs = Self.splitRevolutions(flux: flux)
                let scpRevs = revs.map { rev in
                    rev.map { SCPImage.scpTicks(deviceTicks: $0, sampleFreq: sampleFreq,
                                                resolution: SCPImage.resolution25ns) }
                }
                let indexTimes = scpRevs.map { $0.reduce(0, +) }
                scpTracks.append(SCPTrack(trackNumber: track, revolutions: scpRevs,
                                          indexTimes: indexTimes))
                progress?(DiskProgress(track: track, totalTracks: totalTracks,
                                       sectorsFound: 1, sectorsExpected: 1))
            }
        }
        return SCPImage.encode(tracks: scpTracks, diskType: diskType,
                               headsMode: heads == 1 ? 1 : 0)
    }

    /// Write a previously imaged SCP back to a disk (best effort; exotic
    /// protections may not reproduce on a stock drive).
    public func writeSCP(_ data: Data, heads: Int = 2,
                         progress: ((DiskProgress) -> Void)? = nil,
                         isCancelled: () -> Bool = { false }) throws {
        guard info != nil else { throw GWError.notConnected }
        guard let scp = SCPImage.decode(data) else {
            throw GWError.unexpectedResponse(expected: 0x53, got: 0)
        }
        try selectDrive(config.unit)
        try motor(unit: config.unit, on: true)
        sleepMs(config.motorSpinUpMs)
        defer { try? motor(unit: config.unit, on: false); try? deselectDrive() }

        let sortedTracks = scp.tracks.keys.sorted()
        for (i, track) in sortedTracks.enumerated() {
            if isCancelled() { break }
            guard let scpTrack = scp.tracks[track], let rev = scpTrack.revolutions.first else { continue }
            try seek(cylinder: track / heads)
            try head(track % heads)
            sleepMs(config.settleMs)
            let deviceFlux = rev.map {
                SCPImage.deviceTicks(scpTicks: $0, sampleFreq: sampleFreq,
                                     resolution: scp.resolution)
            }
            try writeFlux(deviceFlux)
            progress?(DiskProgress(track: track, totalTracks: sortedTracks.count,
                                   sectorsFound: i + 1, sectorsExpected: sortedTracks.count))
        }
    }

    /// Split a flux read into per-revolution slices using the index marks
    /// (cumulative tick positions). Falls back to the whole stream if there
    /// aren't enough index pulses.
    static func splitRevolutions(flux: DecodedFlux) -> [[Int]] {
        let boundaries = flux.indexTicks.sorted()
        guard boundaries.count >= 2 else { return [flux.flux] }
        var revs: [[Int]] = []
        var current: [Int] = []
        var cumulative = 0
        var bIdx = 0
        for sample in flux.flux {
            cumulative += sample
            current.append(sample)
            if bIdx < boundaries.count, cumulative >= boundaries[bIdx] {
                revs.append(current)
                current = []
                bIdx += 1
            }
        }
        if !current.isEmpty { revs.append(current) }
        return revs.isEmpty ? [flux.flux] : revs
    }

    /// Write an ADF to a disk, optionally verifying each track by read-back.
    public func writeDisk(adf: Data, geometry: AmigaFloppyGeometry,
                          progress: ((DiskProgress) -> Void)? = nil,
                          isCancelled: () -> Bool = { false }) throws {
        guard info != nil else { throw GWError.notConnected }
        try selectDrive(config.unit)
        try motor(unit: config.unit, on: true)
        sleepMs(config.motorSpinUpMs)
        defer { try? motor(unit: config.unit, on: false); try? deselectDrive() }

        for cyl in 0 ..< geometry.cylinders {
            for h in 0 ..< geometry.heads {
                if isCancelled() { break }
                let track = cyl * geometry.heads + h
                try seek(cylinder: cyl)
                try head(h)
                sleepMs(config.settleMs)
                let flux = ADFFloppyImage.encodeTrackFlux(
                    adf: adf, trackNumber: track, sampleFreq: sampleFreq, geometry: geometry)
                try writeFlux(flux)

                var found = geometry.format.sectorsPerTrack
                if config.verifyWrites {
                    let readback = try readFlux(revolutions: 2)
                    found = ADFFloppyImage.decodeTrack(
                        fluxTicks: readback.flux, sampleFreq: sampleFreq,
                        format: geometry.format, timing: geometry.timing).count
                }
                progress?(DiskProgress(track: track, totalTracks: geometry.tracks,
                                       sectorsFound: found,
                                       sectorsExpected: geometry.format.sectorsPerTrack))
            }
        }
    }
}
