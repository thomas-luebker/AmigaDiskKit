//
//  AmigaPreviewRenderer.swift
//  AmigaDiskKit
//
//  Classifies the *contents* of a single Amiga file and produces a
//  UI-independent preview. Both the in-app Disk Browser preview pane and the
//  system Quick Look extension call this so behaviour stays identical.
//
//  This layer never imports AppKit/SwiftUI: bitmaps come back as raw RGBA +
//  dimensions, and each caller wraps them into NSImage/CGImage itself.
//
//  Whole-disk-image (container) previews are handled separately by
//  `PreviewContainerLister`; this renderer is for the bytes of one file.
//

import Foundation

/// A decoded 32-bit RGBA image (row-major, 4 bytes/pixel, non-premultiplied).
public struct PreviewBitmap {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// The outcome of classifying one file's bytes.
public enum PreviewResult {
    case bitmap(PreviewBitmap)   // ILBM image or rendered Workbench icon
    case text(String)            // decoded Latin-1 text / script / AmigaGuide
    case hex(Data)               // binary fallback (caller formats the dump)
    case unsupported
}

public enum AmigaPreviewRenderer {

    /// Classify and render a file's bytes. `name` is the Amiga file name, used
    /// only as a weak hint — detection is content-first.
    public static func render(name: String, data: Data) -> PreviewResult {
        // 1. IFF ILBM image.
        if let bmp = ILBMDecoder.decode(data) {
            return .bitmap(bmp)
        }
        // 2. Workbench icon (.info / DiskObject, magic 0xE310).
        if isDiskObject(data), let bmp = IconImageDecoder.decode(data) {
            return .bitmap(bmp)
        }
        // 3. Plain text / script / AmigaGuide source.
        if let text = decodeTextIfTextual(data) {
            return .text(text)
        }
        // 4. Binary fallback.
        return data.isEmpty ? .unsupported : .hex(data)
    }

    static func isDiskObject(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0xE3 && data[data.startIndex + 1] == 0x10
    }

    /// Decode as ISO-8859-1 (Amiga's native encoding) if the byte distribution
    /// looks textual. Returns nil for binary content. Empty files count as text.
    static func decodeTextIfTextual(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        // Cap the scan; preview text is truncated for display anyway.
        let sample = data.prefix(64 * 1024)
        var binaryCount = 0
        for b in sample {
            switch b {
            case 0x09, 0x0A, 0x0C, 0x0D: continue          // tab, LF, FF, CR
            case 0x20...0x7E: continue                     // printable ASCII
            case 0xA0...0xFF: continue                     // Latin-1 high range
            default: binaryCount += 1                      // NUL & other controls
            }
        }
        // Allow a little noise (e.g. stray ESC sequences) but reject binaries.
        guard Double(binaryCount) / Double(sample.count) < 0.05 else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }
}
