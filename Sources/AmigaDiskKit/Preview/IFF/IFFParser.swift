//
//  IFFParser.swift
//  AmigaDiskKit
//
//  Minimal generic EA-IFF-85 FORM/chunk walker. Pure Foundation, no AppKit —
//  it returns chunk bodies as fresh 0-based `Data` so the bounds-tolerant
//  tooling helpers (toolingReadBE16/32) can index them directly.
//
//  Used today by the ILBM image decoder; the FORM/chunk model is format-neutral
//  and is intended to be reusable for future 8SVX / ANIM previews.
//

import Foundation

/// One chunk inside an IFF FORM. `data` is the chunk body only (header and the
/// trailing odd-length pad byte are stripped) and always starts at index 0.
public struct IFFChunk {
    public let id: String
    public let data: Data
}

/// A parsed top-level IFF FORM, e.g. `formType == "ILBM"`.
public struct IFFForm {
    public let formType: String
    public let chunks: [IFFChunk]

    /// First chunk with the given 4-character id, if present.
    public func chunk(_ id: String) -> IFFChunk? {
        chunks.first { $0.id == id }
    }
}

public enum IFFParser {

    /// Read a 4-character chunk id starting at `offset`, or nil if out of range
    /// or not printable ASCII.
    static func fourCC(_ data: Data, at offset: Int) -> String? {
        guard offset + 4 <= data.count else { return nil }
        var bytes = [UInt8]()
        for i in 0..<4 {
            let b = data[offset + i]
            // IFF ids are blank-padded printable ASCII (0x20...0x7E).
            guard b >= 0x20, b <= 0x7E else { return nil }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Parse a top-level `FORM` container. Returns nil if the data is not a FORM.
    /// Tolerant of a declared FORM size that runs past the buffer (truncated
    /// files still yield whatever chunks parsed cleanly).
    public static func parse(_ raw: Data) -> IFFForm? {
        // Re-base to a 0-indexed copy so the tooling helpers index correctly even
        // when `raw` arrives as a slice.
        let data = (raw.startIndex == 0) ? raw : Data(raw)
        guard data.count >= 12, fourCC(data, at: 0) == "FORM" else { return nil }

        let declaredEnd = 8 + Int(toolingReadBE32(data, at: 4))
        let end = min(data.count, max(declaredEnd, 12))
        guard let formType = fourCC(data, at: 8) else { return nil }

        var chunks: [IFFChunk] = []
        var off = 12
        while off + 8 <= end {
            guard let id = fourCC(data, at: off) else { break }
            let size = Int(toolingReadBE32(data, at: off + 4))
            let bodyStart = off + 8
            guard size >= 0, bodyStart + size <= data.count else { break }
            chunks.append(IFFChunk(id: id, data: data.subdata(in: bodyStart..<bodyStart + size)))
            // Chunks are padded to an even byte boundary.
            off = bodyStart + size + (size & 1)
        }
        return IFFForm(formType: formType, chunks: chunks)
    }

    /// Decode a PackBits / ByteRun1 stream, producing exactly `count` bytes
    /// starting at `cursor` (advanced in place). Returns nil if the source runs
    /// dry. Used for ILBM BODY decompression (decode is reset per scanline).
    static func unpackByteRun1(_ src: Data, cursor: inout Int, count: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            guard cursor < src.count else { return nil }
            let control = Int8(bitPattern: src[cursor]); cursor += 1
            if control >= 0 {
                let n = Int(control) + 1
                guard cursor + n <= src.count else { return nil }
                for _ in 0..<n { out.append(src[cursor]); cursor += 1 }
            } else if control != -128 {
                let n = Int(-control) + 1
                guard cursor < src.count else { return nil }
                let v = src[cursor]; cursor += 1
                for _ in 0..<n { out.append(v) }
            }
            // control == -128: no-op
        }
        return out
    }
}
