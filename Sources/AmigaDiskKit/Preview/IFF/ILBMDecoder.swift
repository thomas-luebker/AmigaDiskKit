//
//  ILBMDecoder.swift
//  AmigaDiskKit
//
//  Decodes IFF ILBM (Amiga InterLeaved BitMap) images into 32-bit RGBA so the
//  Disk Browser preview pane and the Quick Look extension can render them.
//
//  Supports: uncompressed + ByteRun1 (PackBits) BODY, optional mask plane,
//  CMAP palettes (with 4-bit-gun nibble replication), EHB (Extra-HalfBrite),
//  and HAM6 / HAM8. Deep (24-bit) ILBM is out of scope for now.
//
//  Pure Foundation — returns a `PreviewBitmap`; the UI wraps it into NSImage.
//

import Foundation

public enum ILBMDecoder {

    /// Decode an ILBM FORM. Returns nil if `data` is not an ILBM or is malformed.
    public static func decode(_ data: Data) -> PreviewBitmap? {
        guard let form = IFFParser.parse(data), form.formType == "ILBM",
              let bmhd = form.chunk("BMHD"), bmhd.data.count >= 20 else { return nil }

        let h = bmhd.data
        let width   = Int(toolingReadBE16(h, at: 0))
        let height  = Int(toolingReadBE16(h, at: 2))
        let nPlanes = Int(h[8])
        let masking = Int(h[9])
        let compression = Int(h[10])
        guard width > 0, height > 0, nPlanes > 0, nPlanes <= 8 else { return nil }

        let camg = form.chunk("CAMG").map { Int(toolingReadBE32($0.data, at: 0)) } ?? 0
        let isHAM = (camg & 0x0800) != 0
        let isEHB = (camg & 0x0080) != 0

        let palette = parseCMAP(form.chunk("CMAP")?.data)
        guard let body = form.chunk("BODY")?.data else { return nil }

        // Bitplane geometry: each plane row is word-aligned.
        let rowBytes = ((width + 15) / 16) * 2
        let planesPerRow = nPlanes + (masking == 1 ? 1 : 0)

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var cursor = 0

        for y in 0..<height {
            // Gather this scanline's bitplanes (mask plane decoded but ignored).
            var planeRows = [[UInt8]]()
            planeRows.reserveCapacity(nPlanes)
            for p in 0..<planesPerRow {
                let row: [UInt8]
                if compression == 1 {
                    guard let r = IFFParser.unpackByteRun1(body, cursor: &cursor, count: rowBytes) else {
                        return finishedEnough(rgba, width, height, upTo: y)
                    }
                    row = r
                } else {
                    guard cursor + rowBytes <= body.count else {
                        return finishedEnough(rgba, width, height, upTo: y)
                    }
                    row = [UInt8](body.subdata(in: cursor..<cursor + rowBytes)); cursor += rowBytes
                }
                if p < nPlanes { planeRows.append(row) }
            }

            decodeScanline(planeRows: planeRows, width: width, nPlanes: nPlanes,
                           palette: palette, isHAM: isHAM, isEHB: isEHB,
                           into: &rgba, row: y)
        }

        return PreviewBitmap(width: width, height: height, rgba: rgba)
    }

    // MARK: - Scanline

    private static func decodeScanline(planeRows: [[UInt8]], width: Int, nPlanes: Int,
                                       palette: [(UInt8, UInt8, UInt8)],
                                       isHAM: Bool, isEHB: Bool,
                                       into rgba: inout [UInt8], row y: Int) {
        // HAM carries colour state across the scanline, starting from palette[0].
        var r: UInt8 = palette.first?.0 ?? 0
        var g: UInt8 = palette.first?.1 ?? 0
        var b: UInt8 = palette.first?.2 ?? 0

        for x in 0..<width {
            // Assemble the colour index by sampling one bit from each plane.
            var index = 0
            let byteIndex = x >> 3
            let bit = UInt8(7 - (x & 7))
            for p in 0..<nPlanes {
                let prow = planeRows[p]
                if byteIndex < prow.count, (prow[byteIndex] >> bit) & 1 == 1 {
                    index |= (1 << p)
                }
            }

            let out = (y * width + x) * 4
            if isHAM {
                let dataBits = nPlanes - 2
                let valShift = UInt8(8 - dataBits)             // map data bits to high bits
                let control = (index >> dataBits) & 0x3
                let value = index & ((1 << dataBits) - 1)
                let scaled = UInt8((value << Int(valShift)) | (value >> max(0, dataBits - Int(valShift))))
                switch control {
                case 0:                                        // set: index into palette
                    let c = paletteColor(palette, index: value, isEHB: false)
                    r = c.0; g = c.1; b = c.2
                case 1: b = scaled                             // modify blue
                case 2: r = scaled                             // modify red
                default: g = scaled                            // modify green
                }
                rgba[out] = r; rgba[out + 1] = g; rgba[out + 2] = b; rgba[out + 3] = 255
            } else {
                let c = paletteColor(palette, index: index, isEHB: isEHB)
                rgba[out] = c.0; rgba[out + 1] = c.1; rgba[out + 2] = c.2; rgba[out + 3] = 255
            }
        }
    }

    /// Resolve a palette index to RGB, honouring EHB (indices ≥ 32 are the first
    /// 32 colours at half brightness).
    private static func paletteColor(_ palette: [(UInt8, UInt8, UInt8)], index: Int,
                                     isEHB: Bool) -> (UInt8, UInt8, UInt8) {
        if isEHB && index >= 32 {
            let base = index - 32
            if base < palette.count {
                let c = palette[base]
                return (c.0 >> 1, c.1 >> 1, c.2 >> 1)
            }
            return (0, 0, 0)
        }
        if index < palette.count { return palette[index] }
        // No/short palette: fall back to a grey ramp so something is visible.
        let v = UInt8(truncatingIfNeeded: index * 16)
        return (v, v, v)
    }

    // MARK: - CMAP

    /// Parse a CMAP chunk (3 bytes/colour). If every gun uses only the high
    /// nibble (classic OCS/ECS 4-bit DACs) the nibble is replicated to 8 bits.
    private static func parseCMAP(_ data: Data?) -> [(UInt8, UInt8, UInt8)] {
        guard let data, data.count >= 3 else { return [] }
        let n = data.count / 3
        var colors = [(UInt8, UInt8, UInt8)]()
        colors.reserveCapacity(n)
        var onlyHighNibble = true
        for i in 0..<n {
            let r = data[i * 3], g = data[i * 3 + 1], b = data[i * 3 + 2]
            if (r & 0x0F) != 0 || (g & 0x0F) != 0 || (b & 0x0F) != 0 { onlyHighNibble = false }
            colors.append((r, g, b))
        }
        if onlyHighNibble {
            colors = colors.map { (($0.0 & 0xF0) | ($0.0 >> 4),
                                   ($0.1 & 0xF0) | ($0.1 >> 4),
                                   ($0.2 & 0xF0) | ($0.2 >> 4)) }
        }
        return colors
    }

    /// Return whatever rows decoded before a truncated BODY ran out (rows past
    /// `upTo` stay transparent). Keeps a partial image visible instead of nil.
    private static func finishedEnough(_ rgba: [UInt8], _ width: Int, _ height: Int,
                                       upTo: Int) -> PreviewBitmap? {
        guard upTo > 0 else { return nil }
        return PreviewBitmap(width: width, height: height, rgba: rgba)
    }
}
