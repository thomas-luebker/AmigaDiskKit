import Foundation

// MARK: - Whole-disk ADF <-> flux orchestration
//
// Ties the codec stack together: a Greaseweazle read gives flux ticks per
// track (usually several revolutions), which decode to sectors and assemble
// into an ADF; writing reverses it. Multi-revolution flux gives free retry —
// `AmigaMFM.decodeTrack` keeps the first checksum-valid copy of each sector,
// so a sector damaged in one revolution can be recovered from another.

public struct AmigaFloppyGeometry: Sendable {
    public let cylinders: Int
    public let heads: Int
    public let format: AmigaTrackFormat
    public let timing: FluxTiming

    public var tracks: Int { cylinders * heads }
    public var bytesPerTrack: Int { format.sectorsPerTrack * AmigaMFM.sectorBytes }
    public var totalBytes: Int { tracks * bytesPerTrack }

    public static let dd = AmigaFloppyGeometry(cylinders: 80, heads: 2,
                                               format: .dd, timing: .dd)   // 880 KB
    public static let hd = AmigaFloppyGeometry(cylinders: 80, heads: 2,
                                               format: .hd, timing: .hd)   // 1760 KB

    public init(cylinders: Int, heads: Int, format: AmigaTrackFormat, timing: FluxTiming) {
        self.cylinders = cylinders
        self.heads = heads
        self.format = format
        self.timing = timing
    }
}

public struct TrackReadResult: Sendable {
    public let trackNumber: Int
    public let sectorsFound: Int
    public let sectorsExpected: Int
    public var isComplete: Bool { sectorsFound == sectorsExpected }
}

public enum ADFFloppyImage {

    /// Decode one track's flux (ticks, possibly multi-revolution) into sectors.
    public static func decodeTrack(fluxTicks: [Int], sampleFreq: Double,
                                   format: AmigaTrackFormat,
                                   timing: FluxTiming) -> [Int: AmigaMFM.DecodedSector] {
        let seconds = fluxTicks.map { Double($0) / sampleFreq }
        let cells = FluxMFM.decode(fluxSeconds: seconds, timing: timing)
        return AmigaMFM.decodeTrack(cells, format: format)
    }

    /// Assemble an ADF from per-track decoded sectors. Missing sectors are
    /// zero-filled; the per-track results report completeness.
    public static func assembleADF(
        tracks: [Int: [Int: AmigaMFM.DecodedSector]],
        geometry: AmigaFloppyGeometry
    ) -> (adf: Data, results: [TrackReadResult]) {
        var adf = Data(capacity: geometry.totalBytes)
        var results: [TrackReadResult] = []
        let spt = geometry.format.sectorsPerTrack

        for track in 0 ..< geometry.tracks {
            let sectors = tracks[track] ?? [:]
            var found = 0
            for s in 0 ..< spt {
                if let sector = sectors[s] {
                    adf.append(contentsOf: sector.data)
                    found += 1
                } else {
                    adf.append(Data(count: AmigaMFM.sectorBytes))
                }
            }
            results.append(TrackReadResult(trackNumber: track, sectorsFound: found,
                                           sectorsExpected: spt))
        }
        return (adf, results)
    }

    /// Split a full ADF into one track's 512-byte payloads.
    public static func trackSectors(adf: Data, trackNumber: Int,
                                    geometry: AmigaFloppyGeometry) -> [[UInt8]] {
        let spt = geometry.format.sectorsPerTrack
        let trackStart = trackNumber * geometry.bytesPerTrack
        var sectors: [[UInt8]] = []
        for s in 0 ..< spt {
            let start = adf.startIndex + trackStart + s * AmigaMFM.sectorBytes
            let end = start + AmigaMFM.sectorBytes
            sectors.append(Array(adf[start ..< end]))
        }
        return sectors
    }

    /// Encode one ADF track to flux ticks for WriteFlux.
    public static func encodeTrackFlux(adf: Data, trackNumber: Int, sampleFreq: Double,
                                       geometry: AmigaFloppyGeometry) -> [Int] {
        let sectors = trackSectors(adf: adf, trackNumber: trackNumber, geometry: geometry)
        let cells = AmigaMFM.encodeTrack(sectors: sectors, trackNumber: trackNumber,
                                         format: geometry.format)
        let seconds = FluxMFM.encode(cells: cells, timing: geometry.timing)
        return seconds.map { Int(($0 * sampleFreq).rounded()) }
    }
}
