//
//  IconImageDecoder.swift
//  AmigaDiskKit
//
//  Renders the imagery of a classic Amiga Workbench icon (.info / DiskObject)
//  into RGBA for preview. Reuses IconPatcher's hardened DiskObject layout
//  knowledge (header size, Image struct geometry) and maps the planar bitmap
//  through the standard Workbench / MagicWB palette.
//
//  Scope: classic planar ("OldIcons", up to 8 colours). NewIcons / GlowIcons
//  (chunky imagery smuggled in ToolTypes / IFF) are a deliberate follow-up.
//

import Foundation

public enum IconImageDecoder {

    /// The standard 8-colour Workbench palette (MagicWB ordering). Indices 0–3
    /// match the OS 4-colour default closely enough for monochrome/4-colour
    /// icons; 4–7 cover MagicWB-style icons.
    private static let palette: [(UInt8, UInt8, UInt8)] = [
        (0x95, 0x95, 0x95), // 0 grey (background)
        (0x00, 0x00, 0x00), // 1 black
        (0xFF, 0xFF, 0xFF), // 2 white
        (0x3B, 0x67, 0xA2), // 3 blue
        (0x7B, 0x7B, 0x7B), // 4 dark grey
        (0xAF, 0xAF, 0xAF), // 5 light grey
        (0xAA, 0x90, 0x7C), // 6 tan
        (0xFF, 0xA9, 0x97), // 7 salmon
    ]

    /// Decode the normal-state image (GadgetRender) of a DiskObject. Returns nil
    /// if it is not a DiskObject or carries no image.
    public static func decode(_ raw: Data) -> PreviewBitmap? {
        let data = (raw.startIndex == 0) ? raw : Data(raw)
        guard data.count >= 78, data[0] == 0xE3, data[1] == 0x10 else { return nil }

        // GadgetRender (normal image) pointer; the first Image struct, if any,
        // immediately follows the 78-byte header.
        guard toolingReadBE32(data, at: 0x16) != 0 else { return nil }
        return decodeImage(data, at: 78)
    }

    /// Decode a 20-byte Image struct + planar data at `off`.
    private static func decodeImage(_ data: Data, at off: Int) -> PreviewBitmap? {
        guard off + 20 <= data.count else { return nil }
        let width  = Int(toolingReadBE16(data, at: off + 4))
        let height = Int(toolingReadBE16(data, at: off + 6))
        let depth  = Int(toolingReadBE16(data, at: off + 8))
        guard width > 0, height > 0, depth > 0, depth <= 8,
              width <= 4096, height <= 4096 else { return nil }

        let rowBytes = ((width + 15) / 16) * 2
        let planeSize = rowBytes * height
        let pixelStart = off + 20
        guard pixelStart + planeSize * depth <= data.count else { return nil }

        // Icon planes are stored consecutively (plane 0 in full, then plane 1…),
        // unlike ILBM's interleaved scanlines.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var index = 0
                let byteInRow = y * rowBytes + (x >> 3)
                let bit = UInt8(7 - (x & 7))
                for p in 0..<depth {
                    let b = data[pixelStart + p * planeSize + byteInRow]
                    if (b >> bit) & 1 == 1 { index |= (1 << p) }
                }
                let c = index < palette.count ? palette[index]
                                              : (UInt8(truncatingIfNeeded: index * 16),
                                                 UInt8(truncatingIfNeeded: index * 16),
                                                 UInt8(truncatingIfNeeded: index * 16))
                let o = (y * width + x) * 4
                rgba[o] = c.0; rgba[o + 1] = c.1; rgba[o + 2] = c.2; rgba[o + 3] = 255
            }
        }
        return PreviewBitmap(width: width, height: height, rgba: rgba)
    }
}
