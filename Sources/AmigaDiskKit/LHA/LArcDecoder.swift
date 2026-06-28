import Foundation

// Decoders for the old LArc methods -lzs- and -lz5- (LZSS over a ring buffer, no
// Huffman). Ported from lhasa's lzs_decoder.c / lz5_decoder.c (Simon Howard).
enum LArcDecoder {

    /// -lzs-: bit-stream (MSB-first). 2 KB ring (init ' '), pos = size-17.
    /// Each command: 1 bit — 1 ⇒ literal (8 bits); 0 ⇒ copy (11-bit pos + 4-bit
    /// len, length = len+2) from the ring.
    static func decodeLZS(data: Data, originalSize: Int) throws -> Data {
        let ringSize = 2048
        var ring = [UInt8](repeating: 0x20, count: ringSize)
        var ringPos = ringSize - 17
        var reader = BitReader(data: data)
        var out = Data(); out.reserveCapacity(originalSize)

        func emit(_ b: UInt8) {
            out.append(b); ring[ringPos] = b; ringPos = (ringPos + 1) % ringSize
        }
        while out.count < originalSize {
            if try reader.readBits(1) == 1 {
                emit(UInt8(try reader.readBits(8)))
            } else {
                let pos = Int(try reader.readBits(11))
                let len = Int(try reader.readBits(4)) + 2
                for i in 0 ..< len {
                    guard out.count < originalSize else { break }
                    emit(ring[(pos + i) % ringSize])
                }
            }
        }
        return out
    }

    /// -lz5-: byte-stream. 4 KB ring (fixed init pattern), pos = size-18. Reads a
    /// bitmap byte then 8 commands; bitmap bit set (LSB-first) ⇒ literal byte;
    /// clear ⇒ 2-byte copy cmd: start = ((c1&0xF0)<<4)|c0, len = (c1&0x0F)+3.
    static func decodeLZ5(data: Data, originalSize: Int) throws -> Data {
        let ringSize = 4096
        var ring = [UInt8](repeating: 0, count: ringSize)
        // fill_initial: 256×13 runs, then 0..255, then 255..0, then 128 zeros,
        // 110 spaces, 18 zeros.
        var p = 0
        for v in 0 ..< 256 { for _ in 0 ..< 13 { ring[p] = UInt8(v); p += 1 } }
        for v in 0 ..< 256 { ring[p] = UInt8(v); p += 1 }
        for v in 0 ..< 256 { ring[p] = UInt8(255 - v); p += 1 }
        for _ in 0 ..< 128 { ring[p] = 0; p += 1 }
        for _ in 0 ..< 110 { ring[p] = 0x20; p += 1 }
        for _ in 0 ..< 18 { ring[p] = 0; p += 1 }
        var ringPos = ringSize - 18

        let bytes = [UInt8](data)
        var ip = 0
        var out = Data(); out.reserveCapacity(originalSize)
        func emit(_ b: UInt8) {
            out.append(b); ring[ringPos] = b; ringPos = (ringPos + 1) % ringSize
        }
        while out.count < originalSize, ip < bytes.count {
            let bitmap = bytes[ip]; ip += 1
            for bit in 0 ..< 8 {
                guard out.count < originalSize else { break }
                if (bitmap & (1 << bit)) != 0 {
                    guard ip < bytes.count else { break }
                    emit(bytes[ip]); ip += 1
                } else {
                    guard ip + 1 < bytes.count else { break }
                    let c0 = Int(bytes[ip]); let c1 = Int(bytes[ip + 1]); ip += 2
                    let start = ((c1 & 0xF0) << 4) | c0
                    let len = (c1 & 0x0F) + 3
                    for i in 0 ..< len {
                        guard out.count < originalSize else { break }
                        emit(ring[(start + i) % ringSize])
                    }
                }
            }
        }
        return out
    }
}
