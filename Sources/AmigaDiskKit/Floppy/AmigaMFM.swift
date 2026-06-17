import Foundation

// MARK: - Amiga DOS MFM track format
//
// AmigaDOS stores a whole track as N back-to-back sectors (DD = 11, HD = 22),
// each 512 bytes of payload. Encoding (matching the well-tested Greaseweazle
// `codec/amiga/amigados.py`):
//
//   per sector (as on-disk MFM cell bytes):
//     2x sync word 0x4489            (4 bytes, raw — a deliberate MFM violation)
//     info   long  -> encode(4)  =   8 bytes   (0xFF, track, sector, sectorsToGap)
//     label  16B   -> encode(16) =  32 bytes   (OS sector label, normally zero)
//     hdr checksum -> encode(4)  =   8 bytes
//     data checksum-> encode(4)  =   8 bytes
//     data   512B  -> encode(512)= 1024 bytes
//
// `encode` splits each byte into its odd then even data bits (mask 0x55); the
// 0xAA clock-bit positions are filled afterwards by the standard MFM rule
// (a clock bit is set only between two zero data bits). Checksums XOR the
// encoded longs and mask 0x55555555.

public struct AmigaTrackFormat: Equatable, Sendable {
    public let sectorsPerTrack: Int
    public static let dd = AmigaTrackFormat(sectorsPerTrack: 11)
    public static let hd = AmigaTrackFormat(sectorsPerTrack: 22)

    public init(sectorsPerTrack: Int) { self.sectorsPerTrack = sectorsPerTrack }
}

public enum AmigaMFM {

    public static let syncWord: UInt16 = 0x4489
    public static let sectorBytes = 512

    // MARK: - Odd/even data-bit split (no clock bits yet)

    /// Split each byte into [all odd data bits..][all even data bits..],
    /// each masked to the 0x55 data-bit positions. Output is 2× input.
    static func encode(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(data.count * 2)
        for b in data { out.append((b >> 1) & 0x55) }
        for b in data { out.append(b & 0x55) }
        return out
    }

    /// Inverse of `encode`: recombine the odd and even halves.
    static func decode(_ enc: ArraySlice<UInt8>) -> [UInt8] {
        let n = enc.count / 2
        let base = enc.startIndex
        var out = [UInt8](); out.reserveCapacity(n)
        for i in 0 ..< n {
            let odd = enc[base + i]
            let even = enc[base + n + i]
            out.append(((odd << 1) & 0xAA) | (even & 0x55))
        }
        return out
    }

    /// Amiga sector checksum: XOR of the encoded data as big-endian longs,
    /// reduced to the 0x55555555 data-bit space.
    static func checksum(_ enc: [UInt8]) -> UInt32 {
        var csum: UInt32 = 0
        var i = 0
        while i + 4 <= enc.count {
            let long = UInt32(enc[i]) << 24 | UInt32(enc[i + 1]) << 16
                     | UInt32(enc[i + 2]) << 8 | UInt32(enc[i + 3])
            csum ^= long
            i += 4
        }
        return (csum ^ (csum >> 1)) & 0x55555555
    }

    private static func encodeLong(_ v: UInt32) -> [UInt8] {
        encode([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
                UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    // MARK: - Track encode (ADF sectors -> on-disk MFM cell bytes)

    /// Build the MFM cell-byte stream for one track. `sectors` must hold
    /// exactly `format.sectorsPerTrack` payloads of 512 bytes, in order.
    /// `trackNumber` = cyl * 2 + head.
    public static func encodeTrack(sectors: [[UInt8]], trackNumber: Int,
                                   format: AmigaTrackFormat) -> [UInt8] {
        precondition(sectors.count == format.sectorsPerTrack)
        let nsec = format.sectorsPerTrack
        var cells: [UInt8] = []

        for (index, payload) in sectors.enumerated() {
            precondition(payload.count == sectorBytes)
            // sync (raw cell pattern)
            cells.append(contentsOf: [0x44, 0x89, 0x44, 0x89])

            // info long
            let info = UInt32(0xFF) << 24
                     | UInt32(trackNumber & 0xFF) << 16
                     | UInt32(index & 0xFF) << 8
                     | UInt32((nsec - index) & 0xFF)
            let encInfo = encodeLong(info)
            let encLabel = encode([UInt8](repeating: 0, count: 16))
            let hdrChecksum = checksum(encInfo + encLabel)
            let encData = encode(payload)
            let dataChecksum = checksum(encData)

            cells.append(contentsOf: encInfo)
            cells.append(contentsOf: encLabel)
            cells.append(contentsOf: encodeLong(hdrChecksum))
            cells.append(contentsOf: encodeLong(dataChecksum))
            cells.append(contentsOf: encData)
        }

        // Fill clock bits across the whole track (sync words already carry
        // their own pattern; reclocking them would corrupt the markers, so
        // clock only the non-sync runs). For decode this is irrelevant — the
        // 0x55 mask drops clock bits — but a written disk must be clean.
        applyMFMClock(&cells)
        return cells
    }

    // MARK: - Track decode (on-disk MFM cell bytes -> sectors)

    public struct DecodedSector {
        public let sectorNumber: Int
        public let trackNumber: Int
        public let data: [UInt8]
    }

    /// Decode every readable sector from a raw MFM cell-byte stream. Returns
    /// sectors that pass both checksums, keyed by sector number. Tolerant of
    /// gaps, partial tracks, and an arbitrary rotational start.
    public static func decodeTrack(_ cells: [UInt8],
                                   format: AmigaTrackFormat) -> [Int: DecodedSector] {
        let bits = BitStream(bytes: cells)
        var result: [Int: DecodedSector] = [:]

        // Sector field byte counts (after the 2 sync words).
        let encInfoLen = 8, encLabelLen = 32, encCsumLen = 8, encDataLen = sectorBytes * 2
        let sectorPayloadLen = encInfoLen + encLabelLen + encCsumLen + encCsumLen + encDataLen

        var searchBit = 0
        while let syncStart = bits.findDoubleSync(from: searchBit) {
            // Aligned byte stream begins right after the two sync words.
            let dataBitStart = syncStart + 32  // two 16-bit sync words
            guard let raw = bits.alignedBytes(fromBit: dataBitStart, count: sectorPayloadLen) else {
                break
            }
            // Strip MFM clock bits (the 0xAA positions): checksums and the
            // odd/even decode operate on the data-bit (0x55) space only, the
            // same form the stored checksum was computed over at encode time.
            let bytes = raw.map { $0 & 0x55 }
            searchBit = dataBitStart  // continue scan past this sync

            var off = 0
            let encInfo = Array(bytes[off ..< off + encInfoLen]); off += encInfoLen
            let encLabel = Array(bytes[off ..< off + encLabelLen]); off += encLabelLen
            let encHdrCsum = Array(bytes[off ..< off + encCsumLen]); off += encCsumLen
            let encDataCsum = Array(bytes[off ..< off + encCsumLen]); off += encCsumLen
            let encData = Array(bytes[off ..< off + encDataLen]); off += encDataLen

            let info = decode(encInfo[...])
            let storedHdrCsum = beLong(decode(encHdrCsum[...]))
            let storedDataCsum = beLong(decode(encDataCsum[...]))

            let computedHdr = checksum(encInfo + encLabel)
            let computedData = checksum(encData)
            guard computedHdr == storedHdrCsum, computedData == storedDataCsum else {
                continue
            }
            let trackNumber = Int(info[1])
            let sectorNumber = Int(info[2])
            guard sectorNumber >= 0, sectorNumber < format.sectorsPerTrack,
                  result[sectorNumber] == nil else { continue }
            result[sectorNumber] = DecodedSector(sectorNumber: sectorNumber,
                                                 trackNumber: trackNumber,
                                                 data: decode(encData[...]))
        }
        return result
    }

    private static func beLong(_ b: [UInt8]) -> UInt32 {
        guard b.count >= 4 else { return 0 }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    // MARK: - MFM clock-bit fill

    /// Set clock bits (the 0xAA positions) per the MFM rule: a clock bit is 1
    /// only when the data bits on either side of it are both 0. Sync words
    /// (0x4489) are left untouched.
    static func applyMFMClock(_ cells: inout [UInt8]) {
        let syncHi: UInt8 = 0x44, syncLo: UInt8 = 0x89
        var prevDataBit = 0
        var i = 0
        while i < cells.count {
            // Skip sync word pairs verbatim.
            if i + 1 < cells.count, cells[i] == syncHi, cells[i + 1] == syncLo {
                prevDataBit = 1  // 0x89 ends in a 1 data bit
                i += 2
                continue
            }
            var byte = cells[i]
            // Cells are MSB-first; data bits live at even cell indices
            // (0x55 → bit positions 6,4,2,0), clocks at odd (0xAA → 7,5,3,1).
            for pair in 0 ..< 4 {
                let dataPos = 6 - pair * 2          // 6,4,2,0
                let clockPos = 7 - pair * 2         // 7,5,3,1
                let dataBit = Int((byte >> UInt8(dataPos)) & 1)
                if prevDataBit == 0 && dataBit == 0 {
                    byte |= (1 << UInt8(clockPos))
                } else {
                    byte &= ~(UInt8(1) << UInt8(clockPos))
                }
                prevDataBit = dataBit
            }
            cells[i] = byte
            i += 1
        }
    }
}

// MARK: - Bit-level helpers

/// MSB-first view over a byte buffer for sync search and aligned extraction.
struct BitStream {
    let bytes: [UInt8]
    let bitCount: Int

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.bitCount = bytes.count * 8
    }

    func bit(_ index: Int) -> Int {
        let byte = bytes[index >> 3]
        return Int((byte >> UInt8(7 - (index & 7))) & 1)
    }

    /// Find the bit index just past two consecutive 0x4489 sync words
    /// (32 bits), returning the index of the first sync bit. Scans from
    /// `from` (a bit index).
    func findDoubleSync(from: Int) -> Int? {
        let pattern: UInt32 = 0x4489_4489
        guard bitCount >= 32 else { return nil }
        var acc: UInt32 = 0
        // Prime with the 31 bits before `from` so the first full window ends
        // at `from+...`; simplest correct approach: slide a 32-bit window.
        var start = max(0, from)
        // Build initial 32-bit window if possible.
        guard start + 32 <= bitCount else { return nil }
        for i in 0 ..< 32 { acc = (acc << 1) | UInt32(bit(start + i)) }
        if acc == pattern { return start }
        var end = start + 32
        while end < bitCount {
            acc = (acc << 1) | UInt32(bit(end))
            end += 1
            start += 1
            if acc == pattern { return start }
        }
        return nil
    }

    /// Extract `count` bytes starting at bit `fromBit`, MSB-first. Returns nil
    /// if the stream is too short.
    func alignedBytes(fromBit: Int, count: Int) -> [UInt8]? {
        guard fromBit >= 0, fromBit + count * 8 <= bitCount else { return nil }
        var out = [UInt8](); out.reserveCapacity(count)
        var bitIndex = fromBit
        for _ in 0 ..< count {
            var b: UInt8 = 0
            for _ in 0 ..< 8 {
                b = (b << 1) | UInt8(bit(bitIndex))
                bitIndex += 1
            }
            out.append(b)
        }
        return out
    }
}
