//
//  ColorIconTests.swift
//  AmigaDiskKitTests
//
//  OS 3.5+ icons ("GlowIcons", and everything OS 3.2 ships) put their real
//  artwork in an appended IFF "FORM ICON" and often leave the classic planar
//  image as a tiny placeholder. HDToolBox.info on a stock OS 3.2 install
//  carries an 8x8 depth-1 stub — which is exactly what the Disk Browser was
//  drawing: a black blob, magnified.
//
//  Set AMIGADISKKIT_COLOR_ICON to a real .info to check against the genuine
//  article; the synthetic case always runs.
//

import XCTest
@testable import AmigaDiskKit

final class ColorIconTests: XCTestCase {

    /// Build a minimal but REAL colour icon: an 8x8 DiskObject stub (the thing
    /// that used to win) plus a FORM ICON carrying a 2x2 uncompressed image.
    private func makeColorIcon(width: Int, height: Int,
                               indices: [UInt8],
                               palette: [(UInt8, UInt8, UInt8)],
                               transparent: UInt8?) -> Data {
        var d = [UInt8](repeating: 0, count: 78)
        d[0] = 0xE3; d[1] = 0x10
        d[0x30] = 3                                   // WBTOOL
        d[0x16] = 0; d[0x17] = 0; d[0x18] = 0; d[0x19] = 1  // GadgetRender != 0

        // the placeholder classic image (8x8, 1 plane) that must NOT be used
        var stub = be16(0) + be16(0) + be16(8) + be16(8) + be16(1)
        stub += [0, 0, 0, 0] + [0, 0] + [0, 0, 0, 0]
        stub += [UInt8](repeating: 0xFF, count: 2 * 8)

        // FACE: width-1, height-1, flags, aspect, maxpal-1
        let face: [UInt8] = [UInt8(width - 1), UInt8(height - 1), 1, 0,
                             0, UInt8(palette.count - 1)]
        // IMAG: transparent, numcolors-1, flags, imgcompr, palcompr, depth,
        //       imagesize-1 (u16), palettesize-1 (u16), pixels…, palette…
        var pal = [UInt8]()
        for c in palette { pal += [c.0, c.1, c.2] }
        let flags: UInt8 = transparent != nil ? 0x03 : 0x02
        var imag: [UInt8] = [transparent ?? 0, UInt8(palette.count - 1), flags, 0, 0, 8]
        imag += be16(UInt16(indices.count - 1))
        imag += be16(UInt16(pal.count - 1))
        imag += indices
        imag += pal

        var form = [UInt8]()
        form += Array("ICON".utf8)
        form += Array("FACE".utf8) + be32(UInt32(face.count)) + face
        form += Array("IMAG".utf8) + be32(UInt32(imag.count)) + imag
        if form.count % 2 == 1 { form.append(0) }

        var out = Data(d + stub)
        out.append(contentsOf: Array("FORM".utf8))
        out.append(contentsOf: be32(UInt32(form.count)))
        out.append(contentsOf: form)
        return out
    }

    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    func testColorIconWinsOverThePlaceholder() throws {
        // 2x2: red, green / blue, transparent
        let data = makeColorIcon(
            width: 2, height: 2,
            indices: [0, 1, 2, 3],
            palette: [(255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 0, 0)],
            transparent: 3)
        let bmp = try XCTUnwrap(IconImageDecoder.decode(data))

        XCTAssertEqual(bmp.width, 2, "geometry must come from FACE, not the 8x8 stub")
        XCTAssertEqual(bmp.height, 2)
        XCTAssertEqual(Array(bmp.rgba[0..<4]), [255, 0, 0, 255], "index 0 -> red")
        XCTAssertEqual(Array(bmp.rgba[4..<8]), [0, 255, 0, 255], "index 1 -> green")
        XCTAssertEqual(Array(bmp.rgba[8..<12]), [0, 0, 255, 255], "index 2 -> blue")
        XCTAssertEqual(bmp.rgba[15], 0, "the transparent index must be alpha 0")
    }

    /// A classic icon with no FORM ICON must still decode the old way.
    func testClassicIconStillDecodesWhenThereIsNoColourIcon() throws {
        var d = [UInt8](repeating: 0, count: 78)
        d[0] = 0xE3; d[1] = 0x10
        d[0x19] = 1
        var img = be16(0) + be16(0) + be16(8) + be16(1) + be16(1)
        img += [0, 0, 0, 0] + [0, 0] + [0, 0, 0, 0]
        let bmp = try XCTUnwrap(IconImageDecoder.decode(Data(d + img + [0xF0, 0x00])))
        XCTAssertEqual(bmp.width, 8)
        XCTAssertEqual(bmp.height, 1)
    }

    /// The genuine article, when one is pointed at.
    func testRealColourIcon() throws {
        guard let path = ProcessInfo.processInfo.environment["AMIGADISKKIT_COLOR_ICON"] else {
            throw XCTSkip("set AMIGADISKKIT_COLOR_ICON to a real OS 3.5+ .info")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bmp = try XCTUnwrap(IconImageDecoder.decode(data))
        // Anything from that era is far bigger than the 8x8 placeholder.
        XCTAssertGreaterThan(bmp.width, 16, "should be the colour icon, not the stub")
        XCTAssertGreaterThan(bmp.height, 16)
        // and it must not be a single flat colour
        var distinct = Set<UInt32>()
        for i in stride(from: 0, to: bmp.rgba.count, by: 4) {
            distinct.insert(UInt32(bmp.rgba[i]) << 16 | UInt32(bmp.rgba[i+1]) << 8 | UInt32(bmp.rgba[i+2]))
        }
        XCTAssertGreaterThan(distinct.count, 2, "a real icon has more than two colours")

        if let out = ProcessInfo.processInfo.environment["AMIGADISKKIT_COLOR_ICON_PNG"] {
            dumpPNG(bmp, to: out)
        }
    }

    private func dumpPNG(_ bmp: PreviewBitmap, to path: String) {
        #if canImport(AppKit)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bmp.width, pixelsHigh: bmp.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: bmp.width * 4, bitsPerPixel: 32)
        else { return }
        bmp.rgba.withUnsafeBufferPointer { src in
            rep.bitmapData?.update(from: src.baseAddress!, count: bmp.rgba.count)
        }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
