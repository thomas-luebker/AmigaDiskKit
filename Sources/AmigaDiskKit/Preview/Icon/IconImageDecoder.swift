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

        // OS 3.5+ icons append a "FORM ICON" with the real artwork and often
        // leave the classic planar image as a tiny placeholder - HDToolBox.info
        // on OS 3.2 ships an 8x8 depth-1 stub, which rendered as a black blob.
        // Workbench shows the colour icon, so prefer it here too.
        if let colour = decodeColorIcon(data) { return colour }

        // GadgetRender (normal image) pointer.
        guard toolingReadBE32(data, at: 0x16) != 0 else { return nil }

        // The first Image struct follows the 78-byte header — but a DRAWER icon
        // carries a 56-byte DrawerData (NewWindow + dd_CurrentX/Y) in between.
        // Without this skip the decoder reads the NewWindow as an Image and
        // gets a nonsense geometry, so EVERY drawer icon silently lost its
        // artwork. Same rule IconMetadataParser and IconPatcher already follow.
        var off = 78
        if toolingReadBE32(data, at: 0x42) != 0 { off += 56 }
        return decodeImage(data, at: off)
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

    // MARK: - OS 3.5+ ColorIcon (IFF "FORM ICON")

    /// Decode the appended IFF colour icon: FACE gives the geometry, the FIRST
    /// IMAG is the normal-state image. Both the pixels and the palette are
    /// RLE-packed at an arbitrary bit width, so everything runs through one
    /// bit reader. Returns nil when the file carries no colour icon.
    static func decodeColorIcon(_ data: Data) -> PreviewBitmap? {
        guard let form = findFormICON(data) else { return nil }
        var off = form + 12                       // past "FORM" size "ICON"
        var width = 0, height = 0

        while off + 8 <= data.count {
            let tag = data.subdata(in: off ..< off + 4)
            let size = Int(toolingReadBE32(data, at: off + 4))
            let body = off + 8
            guard size >= 0, body + size <= data.count else { return nil }

            if tag == Data("FACE".utf8), size >= 6 {
                width  = Int(data[body]) + 1      // stored as value-1
                height = Int(data[body + 1]) + 1
            } else if tag == Data("IMAG".utf8), size >= 10, width > 0, height > 0 {
                return decodeIMAG(data, at: body, size: size, width: width, height: height)
            }
            off = body + size + (size & 1)        // IFF chunks are word-aligned
        }
        return nil
    }

    private static func findFormICON(_ data: Data) -> Int? {
        // Search past the DiskObject header; the colour icon always follows it.
        guard data.count > 90 else { return nil }
        let form = Array("FORM".utf8), icon = Array("ICON".utf8)
        var i = 78
        while i + 12 <= data.count {
            if data[i] == form[0], data[i+1] == form[1], data[i+2] == form[2], data[i+3] == form[3],
               data[i+8] == icon[0], data[i+9] == icon[1], data[i+10] == icon[2], data[i+11] == icon[3] {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func decodeIMAG(_ data: Data, at body: Int, size: Int,
                                   width: Int, height: Int) -> PreviewBitmap? {
        let transparentIndex = Int(data[body])
        let numColors        = Int(data[body + 1]) + 1
        let flags            = Int(data[body + 2])
        let imageCompressed  = data[body + 3] != 0
        let paletteCompressed = data[body + 4] != 0
        let depth            = Int(data[body + 5])
        let imageBytes       = Int(toolingReadBE16(data, at: body + 6)) + 1
        let paletteBytes     = Int(toolingReadBE16(data, at: body + 8)) + 1
        let hasTransparency  = (flags & 1) != 0
        let hasPalette       = (flags & 2) != 0

        guard depth > 0, depth <= 8, width <= 1024, height <= 1024,
              body + 10 + imageBytes <= data.count else { return nil }

        let pixelStart = body + 10
        let pixels = unpack(Array(data[pixelStart ..< pixelStart + imageBytes]),
                            itemBits: depth, count: width * height,
                            compressed: imageCompressed)
        guard pixels.count == width * height else { return nil }

        // Palette: RGB triples, packed the same way.
        var palette = [(UInt8, UInt8, UInt8)]()
        if hasPalette, pixelStart + imageBytes + paletteBytes <= data.count {
            let ps = pixelStart + imageBytes
            let raw = unpack(Array(data[ps ..< ps + paletteBytes]),
                             itemBits: 8, count: numColors * 3,
                             compressed: paletteCompressed)
            var i = 0
            while i + 2 < raw.count {
                palette.append((UInt8(raw[i] & 0xFF), UInt8(raw[i+1] & 0xFF), UInt8(raw[i+2] & 0xFF)))
                i += 3
            }
        }
        guard !palette.isEmpty else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height {
            let idx = pixels[i]
            let c = idx < palette.count ? palette[idx] : (UInt8(0), UInt8(0), UInt8(0))
            let o = i * 4
            rgba[o] = c.0; rgba[o+1] = c.1; rgba[o+2] = c.2
            rgba[o+3] = (hasTransparency && idx == transparentIndex) ? 0 : 255
        }
        return PreviewBitmap(width: width, height: height, rgba: rgba)
    }

    /// ByteRun1-style RLE over items of an arbitrary bit width, read from one
    /// continuous bitstream: a control byte n <= 127 means (n+1) literals,
    /// n >= 129 means one item repeated (257-n) times, 128 is a no-op.
    private static func unpack(_ src: [UInt8], itemBits: Int, count: Int,
                               compressed: Bool) -> [Int] {
        var out = [Int](); out.reserveCapacity(count)
        var bitPos = 0
        let totalBits = src.count * 8

        func read(_ bits: Int) -> Int? {
            guard bitPos + bits <= totalBits else { return nil }
            var v = 0
            for _ in 0 ..< bits {
                let byte = src[bitPos >> 3]
                let bit = (byte >> (7 - UInt8(bitPos & 7))) & 1
                v = (v << 1) | Int(bit)
                bitPos += 1
            }
            return v
        }

        if !compressed {
            while out.count < count, let v = read(itemBits) { out.append(v) }
            return out
        }
        while out.count < count {
            guard let n = read(8) else { break }
            if n <= 127 {
                for _ in 0 ... n {
                    guard out.count < count, let v = read(itemBits) else { break }
                    out.append(v)
                }
            } else if n > 128 {
                guard let v = read(itemBits) else { break }
                for _ in 0 ..< (257 - n) {
                    guard out.count < count else { break }
                    out.append(v)
                }
            }
        }
        return out
    }
}
