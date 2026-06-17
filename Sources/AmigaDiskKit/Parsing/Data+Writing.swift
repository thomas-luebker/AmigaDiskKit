import Foundation

public extension String {

    /// Encode as ISO-8859-1 (Latin-1) bytes — the AmigaOS filesystem character
    /// set. Amiga filenames, comments and BSTRs are Latin-1, and the parsing
    /// side decodes them with `.isoLatin1`; writing them as UTF-8 (the Swift
    /// default) corrupts every non-ASCII name (e.g. `français` → `franÃ§ais` on
    /// the Amiga). ASCII is identical under both encodings, so this is a no-op
    /// for the common case and only fixes accented/locale names.
    ///
    /// Scalars outside Latin-1 (emoji, CJK, …) cannot appear in a real Amiga
    /// name; they are substituted with `?` (0x3F) so the result is always
    /// representable, matching classic archiver behaviour.
    var amigaLatin1Bytes: [UInt8] {
        // NFC-normalise first: a host filename read back from APFS may be in
        // decomposed (NFD) form — `ñ` as `n` + combining tilde — which would
        // otherwise encode as two scalars (`n` + an unrepresentable mark → `n?`).
        // Recomposing yields the single Latin-1 scalar (U+00F1 → 0xF1).
        let nfc = precomposedStringWithCanonicalMapping
        if let data = nfc.data(using: .isoLatin1) { return Array(data) }
        return nfc.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x3F }
    }
}

public extension Data {

    // MARK: - Big-endian writes (Amiga native byte order)

    mutating func writeBE32(_ value: UInt32, at offset: Int) {
        self[startIndex + offset + 0] = UInt8((value >> 24) & 0xFF)
        self[startIndex + offset + 1] = UInt8((value >> 16) & 0xFF)
        self[startIndex + offset + 2] = UInt8((value >>  8) & 0xFF)
        self[startIndex + offset + 3] = UInt8( value        & 0xFF)
    }

    mutating func writeBE32(_ value: Int32, at offset: Int) {
        writeBE32(UInt32(bitPattern: value), at: offset)
    }

    mutating func writeBE16(_ value: UInt16, at offset: Int) {
        self[startIndex + offset + 0] = UInt8((value >> 8) & 0xFF)
        self[startIndex + offset + 1] = UInt8( value       & 0xFF)
    }

    mutating func writeBE8(_ value: UInt8, at offset: Int) {
        self[startIndex + offset] = value
    }

    // MARK: - Little-endian writes (MBR / FAT byte order)

    mutating func writeLE32(_ value: UInt32, at offset: Int) {
        self[startIndex + offset + 0] = UInt8( value        & 0xFF)
        self[startIndex + offset + 1] = UInt8((value >>  8) & 0xFF)
        self[startIndex + offset + 2] = UInt8((value >> 16) & 0xFF)
        self[startIndex + offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func writeLE16(_ value: UInt16, at offset: Int) {
        self[startIndex + offset + 0] = UInt8( value       & 0xFF)
        self[startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    // MARK: - String writes

    /// Write a fixed-length Latin-1 string, zero-padding to `length` bytes.
    mutating func writeAmigaString(_ str: String, at offset: Int, length: Int) {
        let bytes = Array(str.amigaLatin1Bytes.prefix(length))
        for (i, b) in bytes.enumerated() {
            self[startIndex + offset + i] = b
        }
        // Trailing bytes remain 0 (Data is zero-initialised at construction)
    }

    /// Write an Amiga BSTR (first byte = char count, followed by Latin-1 chars),
    /// zero-padding the remainder up to `maxLength` bytes.
    mutating func writeBSTR(_ str: String, at offset: Int, maxLength: Int) {
        let bytes = Array(str.amigaLatin1Bytes.prefix(maxLength - 1))
        self[startIndex + offset] = UInt8(bytes.count)
        for (i, b) in bytes.enumerated() {
            self[startIndex + offset + 1 + i] = b
        }
    }
}
