import Foundation

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

    /// Write a fixed-length ASCII string, zero-padding to `length` bytes.
    mutating func writeAmigaString(_ str: String, at offset: Int, length: Int) {
        let bytes = Array(str.utf8.prefix(length))
        for (i, b) in bytes.enumerated() {
            self[startIndex + offset + i] = b
        }
        // Trailing bytes remain 0 (Data is zero-initialised at construction)
    }

    /// Write an Amiga BSTR (first byte = char count, followed by ASCII chars),
    /// zero-padding the remainder up to `maxLength` bytes.
    mutating func writeBSTR(_ str: String, at offset: Int, maxLength: Int) {
        let bytes = Array(str.utf8.prefix(maxLength - 1))
        self[startIndex + offset] = UInt8(bytes.count)
        for (i, b) in bytes.enumerated() {
            self[startIndex + offset + 1 + i] = b
        }
    }
}
