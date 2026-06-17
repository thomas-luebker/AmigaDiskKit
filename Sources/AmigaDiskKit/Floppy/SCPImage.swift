import Foundation

// MARK: - SuperCard Pro (.scp) flux container
//
// Raw flux preservation for copy-protected / non-AmigaDOS disks that won't
// decode to an ADF. SCP stores flux per track per revolution as 16-bit
// big-endian cell times in 25 ns units (× a resolution multiplier); a
// 0x0000 word means "add 65536" to the next value (overflow). IPF is NOT
// supported (closed CAPS/SPS format) — SCP is the open alternative.
//
// Format pinned to the cbmstuff spec: 16-byte header, a 0x10..0x2AF track
// offset table (168 entries × 4 bytes LE), then per-track Track Data Headers
// ("TRK" + track no + per-rev {indexTime, length, dataOffset}) and flux.

public struct SCPTrack: Sendable {
    public let trackNumber: Int
    /// One entry per revolution; each is the flux cell times in 25 ns units.
    public let revolutions: [[Int]]
    /// Index time per revolution (25 ns units) = sum of that rev's cells.
    public let indexTimes: [Int]

    public init(trackNumber: Int, revolutions: [[Int]], indexTimes: [Int]) {
        self.trackNumber = trackNumber
        self.revolutions = revolutions
        self.indexTimes = indexTimes
    }
}

public struct SCPImageData: Sendable {
    public let diskType: UInt8
    public let headsMode: UInt8
    public let resolution: UInt8
    public let tracks: [Int: SCPTrack]
}

public enum SCPImage {
    public static let amigaDiskType: UInt8 = 0x04   // CBM manufacturer, Amiga subtype
    public static let resolution25ns: UInt8 = 0     // 0 => 25 ns base
    static let trackTableEntries = 168
    static let headerSize = 0x10
    static let trackTableSize = trackTableEntries * 4   // 0x10 .. 0x2AF

    // MARK: - Encode

    public static func encode(tracks: [SCPTrack], diskType: UInt8 = amigaDiskType,
                              headsMode: UInt8 = 0, resolution: UInt8 = resolution25ns) -> Data {
        var offsets = [UInt32](repeating: 0, count: trackTableEntries)
        var body = Data()
        let bodyBase = headerSize + trackTableSize

        let sorted = tracks.sorted { $0.trackNumber < $1.trackNumber }
        var minTrack = trackTableEntries - 1, maxTrack = 0
        let revCount = sorted.first?.revolutions.count ?? 1

        for track in sorted {
            guard track.trackNumber < trackTableEntries else { continue }
            offsets[track.trackNumber] = UInt32(bodyBase + body.count)
            minTrack = Swift.min(minTrack, track.trackNumber)
            maxTrack = Swift.max(maxTrack, track.trackNumber)

            var tdh = Data()
            tdh.append(contentsOf: Array("TRK".utf8))
            tdh.append(UInt8(track.trackNumber & 0xFF))

            // Per-rev table, then the flux blocks after it.
            let nrev = track.revolutions.count
            var fluxBlocks: [[UInt8]] = []
            for rev in track.revolutions { fluxBlocks.append(encodeFlux(rev)) }
            let tableSize = 4 + nrev * 12          // "TRK"+no + 12 bytes/rev
            var fluxOffset = tableSize
            for (i, rev) in track.revolutions.enumerated() {
                appendLE32(&tdh, UInt32(track.indexTimes[i]))
                appendLE32(&tdh, UInt32(rev.count))           // length in bitcells
                appendLE32(&tdh, UInt32(fluxOffset))          // offset from TDH start
                fluxOffset += fluxBlocks[i].count
            }
            for block in fluxBlocks { tdh.append(contentsOf: block) }
            body.append(tdh)
        }

        var out = Data()
        out.append(contentsOf: Array("SCP".utf8))
        out.append(0x39)                                       // version 3.9
        out.append(diskType)
        out.append(UInt8(revCount & 0xFF))
        out.append(UInt8(minTrack <= maxTrack ? minTrack : 0)) // start track
        out.append(UInt8(minTrack <= maxTrack ? maxTrack : 0)) // end track
        out.append(0x00)                                       // flags
        out.append(0x00)                                       // bit cell width (0 = 16)
        out.append(headsMode)
        out.append(resolution)
        var checksum: UInt32 = 0                               // filled after body
        appendLE32(&out, checksum)
        for off in offsets { appendLE32(&out, off) }
        out.append(body)

        // Checksum = sum of bytes from 0x10 to EOF, little-endian at 0x0C.
        checksum = out[(headerSize)...].reduce(UInt32(0)) { $0 &+ UInt32($1) }
        out.replaceSubrange(0x0C ..< 0x10, with: le32(checksum))
        return out
    }

    /// 16-bit big-endian flux with 0x0000 overflow words.
    static func encodeFlux(_ cells: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(cells.count * 2)
        for cell in cells {
            var v = max(1, cell)
            while v >= 0x1_0000 { out.append(0); out.append(0); v -= 0x1_0000 }
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    // MARK: - Decode

    public static func decode(_ data: Data) -> SCPImageData? {
        guard data.count >= headerSize + trackTableSize,
              data[0] == 0x53, data[1] == 0x43, data[2] == 0x50 else { return nil }   // "SCP"
        let diskType = data[4]
        let headsMode = data[0x0A]
        let resolution = data[0x0B]

        var tracks: [Int: SCPTrack] = [:]
        for t in 0 ..< trackTableEntries {
            let entryOff = headerSize + t * 4
            let tdhOff = Int(readLE32(data, data.startIndex + entryOff))
            guard tdhOff != 0, data.startIndex + tdhOff + 4 <= data.endIndex else { continue }
            let base = data.startIndex + tdhOff
            guard data[base] == 0x54, data[base + 1] == 0x52, data[base + 2] == 0x4B else { continue } // "TRK"
            let trackNumber = Int(data[base + 3])

            var revolutions: [[Int]] = []
            var indexTimes: [Int] = []
            var rev = 0
            while true {
                let entryBase = base + 4 + rev * 12
                guard entryBase + 12 <= data.endIndex else { break }
                let indexTime = Int(readLE32(data, entryBase))
                let length = Int(readLE32(data, entryBase + 4))
                let dataOff = Int(readLE32(data, entryBase + 8))
                // Heuristic stop: a plausible rev entry has a non-zero length
                // and an in-range data offset; otherwise we've run past the
                // per-rev table into flux bytes.
                guard length > 0, base + dataOff + length * 2 <= data.endIndex else { break }
                let flux = decodeFlux(data, start: base + dataOff, count: length)
                revolutions.append(flux)
                indexTimes.append(indexTime)
                rev += 1
                if rev > 5 { break }   // SCP max 5 revolutions
            }
            if !revolutions.isEmpty {
                tracks[trackNumber] = SCPTrack(trackNumber: trackNumber,
                                               revolutions: revolutions, indexTimes: indexTimes)
            }
        }
        return SCPImageData(diskType: diskType, headsMode: headsMode,
                            resolution: resolution, tracks: tracks)
    }

    /// `count` is the number of flux cells; overflow (0x0000) words add extra
    /// 16-bit words that are not themselves cells, so read until `count` cells
    /// are produced rather than by byte length.
    static func decodeFlux(_ data: Data, start: Int, count: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(count)
        var acc = 0
        var i = start
        while out.count < count, i + 1 < data.endIndex {
            let word = Int(data[i]) << 8 | Int(data[i + 1])
            i += 2
            if word == 0 { acc += 0x1_0000 } else { out.append(acc + word); acc = 0 }
        }
        return out
    }

    // MARK: - Conversions to/from device-tick flux

    /// SCP cell time (25 ns × resolution) for a device-tick interval.
    public static func scpTicks(deviceTicks: Int, sampleFreq: Double, resolution: UInt8) -> Int {
        let seconds = Double(deviceTicks) / sampleFreq
        let unit = 25e-9 * Double(Int(resolution) + 1)
        return max(1, Int((seconds / unit).rounded()))
    }

    /// Device-tick interval for an SCP cell time.
    public static func deviceTicks(scpTicks: Int, sampleFreq: Double, resolution: UInt8) -> Int {
        let unit = 25e-9 * Double(Int(resolution) + 1)
        return max(1, Int((Double(scpTicks) * unit * sampleFreq).rounded()))
    }

    // MARK: - Little-endian helpers

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }
    private static func appendLE32(_ d: inout Data, _ v: UInt32) { d.append(contentsOf: le32(v)) }
    private static func readLE32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}
