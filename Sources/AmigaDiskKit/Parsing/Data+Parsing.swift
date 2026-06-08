import Foundation

public extension Data {

    // MARK: - Big-endian reads (Amiga native byte order)

    func readBE32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readBE16(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1])
        return (b0 << 8) | b1
    }

    func readBE8(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    // MARK: - Little-endian reads (MBR / FAT byte order)

    func readLE32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1])
        let b2 = UInt32(self[startIndex + offset + 2])
        let b3 = UInt32(self[startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    func readLE16(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    // MARK: - String reads

    /// Read a null/space-terminated ASCII string of fixed byte length, trimming trailing
    /// spaces and NULs.  Used for RDSK vendor/product/revision identification strings.
    func readAmigaString(at offset: Int, length: Int) -> String {
        let bytes = self[(startIndex + offset) ..< (startIndex + offset + length)]
        let trimmed = bytes.prefix(while: { $0 != 0 })
        let str = String(bytes: trimmed, encoding: .isoLatin1) ?? ""
        return str.trimmingCharacters(in: .init(charactersIn: " \0"))
    }

    /// Read an Amiga BSTR (Pascal-style string): first byte is the length, followed by
    /// that many ASCII characters.  `maxLength` is the total byte budget including the
    /// length byte.
    func readBSTR(at offset: Int, maxLength: Int) -> String {
        let lengthByte = Int(self[startIndex + offset])
        let charCount  = Swift.min(lengthByte, maxLength - 1)
        guard charCount > 0 else { return "" }
        let bytes = self[(startIndex + offset + 1) ..< (startIndex + offset + 1 + charCount)]
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}
