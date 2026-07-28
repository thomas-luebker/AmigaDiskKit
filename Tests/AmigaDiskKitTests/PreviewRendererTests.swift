//
//  PreviewRendererTests.swift
//  AmigaDiskKitTests
//
//  Covers the file-content preview core: IFF ILBM decoding, Workbench icon
//  rendering, and the AmigaPreviewRenderer classifier. Fixtures are synthesized
//  inline so the suite carries no binary blobs.
//

import XCTest
@testable import AmigaDiskKit

final class PreviewRendererTests: XCTestCase {

    // MARK: - Helpers

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        var out = Array(id.utf8)
        out += be32(body.count)
        out += body
        if body.count & 1 == 1 { out.append(0) } // pad to even
        return out
    }

    /// Build an 8x2, 1-bitplane, uncompressed ILBM: row0 = 0xAA (pixels
    /// 1,0,1,0,1,0,1,0), row1 = 0x55. Palette: 0=black, 1=white.
    private func makeILBM() -> Data {
        var bmhdBody: [UInt8] = []
        bmhdBody += be16(8) + be16(2) + be16(0) + be16(0)  // w,h,x,y
        bmhdBody += [1, 0, 0, 0]                           // planes,mask,compress,pad
        bmhdBody += be16(0) + [1, 1]                       // transparent,xAsp,yAsp
        bmhdBody += be16(8) + be16(2)                      // pageW,pageH
        let bmhd = chunk("BMHD", bmhdBody)
        let cmap = chunk("CMAP", [0, 0, 0, 0xFF, 0xFF, 0xFF])
        let body = chunk("BODY", [0xAA, 0x00, 0x55, 0x00])
        var inner = Array("ILBM".utf8)
        inner += bmhd + cmap + body
        var form = Array("FORM".utf8)
        form += be32(inner.count) + inner
        return Data(form)
    }

    /// Build a minimal DiskObject with one 8x1, depth-1 GadgetRender image whose
    /// single row is 0xF0 (left 4 pixels set).
    private func makeIcon() -> Data {
        var d = [UInt8](repeating: 0, count: 78)
        d[0] = 0xE3; d[1] = 0x10                          // DiskObject magic
        d[0x16] = 0; d[0x17] = 0; d[0x18] = 0; d[0x19] = 1 // GadgetRender != 0
        // Image struct (20 bytes): left,top,width,height,depth,...
        var img = be16(0) + be16(0) + be16(8) + be16(1) + be16(1)
        img += [0, 0, 0, 0] + [0, 0] + [0, 0, 0, 0]      // ImageData, planePick/onOff, NextImage
        let plane: [UInt8] = [0xF0, 0x00]                // 8px row, word-aligned
        return Data(d + img + plane)
    }

    // MARK: - ILBM

    func testILBMDecode() throws {
        let bmp = try XCTUnwrap(ILBMDecoder.decode(makeILBM()))
        XCTAssertEqual(bmp.width, 8)
        XCTAssertEqual(bmp.height, 2)
        XCTAssertEqual(bmp.rgba.count, 8 * 2 * 4)

        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (y * 8 + x) * 4
            return (bmp.rgba[o], bmp.rgba[o + 1], bmp.rgba[o + 2])
        }
        // Row 0 = 0xAA -> pixel 0 set (white), pixel 1 clear (black).
        XCTAssertEqual(px(0, 0).0, 0xFF)
        XCTAssertEqual(px(1, 0).0, 0x00)
        // Row 1 = 0x55 -> pixel 0 clear, pixel 1 set.
        XCTAssertEqual(px(0, 1).0, 0x00)
        XCTAssertEqual(px(1, 1).0, 0xFF)
        // Alpha always opaque.
        XCTAssertEqual(bmp.rgba[3], 255)
    }

    func testILBMRejectsNonILBM() {
        XCTAssertNil(ILBMDecoder.decode(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(ILBMDecoder.decode(makeIcon())) // a DiskObject is not ILBM
    }

    // MARK: - Icon

    func testIconDecode() throws {
        let bmp = try XCTUnwrap(IconImageDecoder.decode(makeIcon()))
        XCTAssertEqual(bmp.width, 8)
        XCTAssertEqual(bmp.height, 1)
        // Left 4 pixels set (index 1 -> black), right 4 clear (index 0 -> grey).
        XCTAssertEqual(bmp.rgba[0], 0x00)            // pixel 0 R
        XCTAssertEqual(bmp.rgba[4 * 4], 0x95)        // pixel 4 R (grey background)
    }

    /// A DRAWER icon puts a 56-byte DrawerData between the header and the first
    /// Image. Decoding at a fixed offset 78 read the NewWindow as an Image and
    /// silently dropped the artwork of every drawer on a volume.
    func testDrawerIconSkipsDrawerData() throws {
        let bmp = try XCTUnwrap(IconImageDecoder.decode(makeDrawerIcon()))
        XCTAssertEqual(bmp.width, 8, "drawer image geometry must come from the real Image struct")
        XCTAssertEqual(bmp.height, 1)
        XCTAssertEqual(bmp.rgba[0], 0x00)            // pixel 0 set -> black
        XCTAssertEqual(bmp.rgba[4 * 4], 0x95)        // pixel 4 clear -> grey
    }

    /// Same imagery as `makeIcon`, but typed as a drawer with a non-NULL
    /// DrawerData pointer and the 56-byte struct actually present.
    private func makeDrawerIcon() -> Data {
        var d = [UInt8](repeating: 0, count: 78)
        d[0] = 0xE3; d[1] = 0x10
        d[0x16] = 0; d[0x17] = 0; d[0x18] = 0; d[0x19] = 1   // GadgetRender != 0
        d[0x30] = 2                                          // do_Type = WBDRAWER
        d[0x42] = 0; d[0x43] = 0; d[0x44] = 0; d[0x45] = 1   // do_DrawerData != 0

        // 56-byte DrawerData, byte-filled so that misreading it as an Image
        // yields an obviously wrong geometry rather than accidentally matching.
        let drawerData = [UInt8](repeating: 0x7F, count: 56)

        var img = be16(0) + be16(0) + be16(8) + be16(1) + be16(1)
        img += [0, 0, 0, 0] + [0, 0] + [0, 0, 0, 0]
        let plane: [UInt8] = [0xF0, 0x00]
        return Data(d + drawerData + img + plane)
    }

    // MARK: - Classifier

    func testRendererClassifiesImage() {
        if case .bitmap = AmigaPreviewRenderer.render(name: "pic.iff", data: makeILBM()) {} else {
            XCTFail("ILBM should classify as bitmap")
        }
        if case .bitmap = AmigaPreviewRenderer.render(name: "disk.info", data: makeIcon()) {} else {
            XCTFail("icon should classify as bitmap")
        }
    }

    func testRendererClassifiesText() {
        let data = Data("Startup-Sequence\nC:SetPatch\n".utf8)
        if case .text(let s) = AmigaPreviewRenderer.render(name: "S", data: data) {
            XCTAssertTrue(s.contains("SetPatch"))
        } else {
            XCTFail("script should classify as text")
        }
    }

    func testRendererClassifiesBinaryAsHex() {
        // Mostly NULs and control bytes -> not textual.
        let data = Data((0..<256).map { UInt8($0 & 0x07) })
        if case .hex = AmigaPreviewRenderer.render(name: "blob", data: data) {} else {
            XCTFail("binary should fall back to hex")
        }
    }
}
