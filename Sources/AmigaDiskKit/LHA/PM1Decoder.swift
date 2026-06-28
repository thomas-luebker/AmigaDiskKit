import Foundation

// Decoder for the PMarc -pm1- method. Ported from lhasa's pm1_decoder.c +
// pma_common.c (Simon Howard). 16 KB ring (zero-initialised), an adaptive
// move-to-front history list for literals, position-thresholded copy ranges, and
// a 5-bit-selected nybble-encoded mini-tree for byte indices.
struct PM1Decoder {
    private static let ringSize = 16384
    private static let maxByteBlock = 216

    private let srcData: Data
    private let originalSize: Int

    // history move-to-front list
    private var hPrev = [Int](repeating: 0, count: 256)
    private var hNext = [Int](repeating: 0, count: 256)
    private var hHead = 0x20

    private var ring = [UInt8](repeating: 0, count: ringSize)   // zero-init (memset 0)
    private var ringPos = 0
    private var outputPos = 0
    private var byteDecodeTree: [UInt8] = []

    init(data: Data, originalSize: Int) { self.srcData = data; self.originalSize = originalSize }

    // (offset, bits)
    private static let copyRanges: [(Int, Int)] = [
        (0,6),(64,8),(0,6),(64,9),(576,11),(2624,13),
        (64,8),(576,8),(576,9),(576,10),(2624,8),(2624,9),(2624,10),(2624,11),(2624,12)]
    private static let byteRanges: [(Int, Int)] = [(0,4),(16,4),(32,5),(64,6),(128,6),(192,6)]
    private static let byteDecodeTrees: [[UInt8]] = [
        [0x12,0x2d,0xef,0x1c,0xab],[0x12,0x23,0xde,0xab,0xcf],[0x12,0x2c,0xd2,0xab,0xef],[0x12,0xa2,0xd2,0xbc,0xef],
        [0x12,0xa2,0xc2,0xbd,0xef],[0x12,0xa2,0xcd,0xb1,0xef],[0x12,0xab,0x12,0xcd,0xef],[0x12,0xab,0x1d,0xc1,0xef],
        [0x12,0xab,0xc1,0xd1,0xef],[0xa1,0x12,0x2c,0xde,0xbf],[0xa1,0x1d,0x1c,0xb1,0xef],[0xa1,0x12,0x2d,0xef,0xbc],
        [0xa1,0x12,0xb2,0xde,0xcf],[0xa1,0x12,0xbc,0xd1,0xef],[0xa1,0x1c,0xb1,0xd1,0xef],[0xa1,0xb1,0x12,0xcd,0xef],
        [0xa1,0xb1,0xc1,0xd1,0xef],[0x12,0x1c,0xde,0xab],[0x12,0xa2,0xcd,0xbe],[0x12,0xab,0xc1,0xde],
        [0xa1,0x1d,0x1c,0xbe],[0xa1,0x12,0xbc,0xde],[0xa1,0x1c,0xb1,0xde],[0xa1,0xb1,0xc1,0xde],
        [0x1d,0x1c,0xab],[0x1c,0xa1,0xbd],[0x12,0xab,0xcd],[0xa1,0x1c,0xbd],
        [0xa1,0xb1,0xcd],[0xa1,0xbc],[0xab],[0x00]]

    // MARK: history (pma_common)
    private mutating func initHistory() {
        for i in 0 ..< 256 { hPrev[i] = (i + 1) & 0xFF; hNext[i] = (i + 255) & 0xFF }
        hHead = 0x20
        hPrev[0x7f] = 0x00; hNext[0x00] = 0x7f
        hPrev[0x1f] = 0xa0; hNext[0xa0] = 0x1f
        hPrev[0xdf] = 0x80; hNext[0x80] = 0xdf
        hPrev[0x9f] = 0xe0; hNext[0xe0] = 0x9f
        hPrev[0xff] = 0x20; hNext[0x20] = 0xff
    }
    private func findInHistory(_ count: Int) -> UInt8 {
        var code = hHead
        if count < 128 { for _ in 0 ..< count { code = hPrev[code] } }
        else { for _ in 0 ..< (256 - count) { code = hNext[code] } }
        return UInt8(code)
    }
    private mutating func updateHistory(_ b: Int) {
        if hHead == b { return }
        let nb = hNext[b], pb = hPrev[b]
        hPrev[nb] = pb; hNext[pb] = nb
        let h = hHead, hn = hNext[h]
        hPrev[b] = h; hNext[b] = hn
        hPrev[hn] = b; hNext[h] = b
        hHead = b
    }
    private func decodeVarLen(_ r: inout BitReader, _ table: [(Int, Int)], _ header: Int) throws -> Int {
        Int(table[header].0) + Int(try r.readBits(table[header].1))
    }

    private mutating func emit(_ b: UInt8, _ out: inout Data) {
        ring[ringPos] = b; ringPos = (ringPos + 1) % Self.ringSize
        out.append(b)
        updateHistory(Int(b)); outputPos += 1
    }

    // MARK: command pieces

    private func readCopyByteCount(_ r: inout BitReader) throws -> Int {
        var x = Int(try r.readBits(2))
        if x < 3 { return x + 3 }
        x = Int(try r.readBits(3))
        if x < 5 { return x + 6 }
        if x == 5 { return Int(try r.readBits(2)) + 11 }
        if x == 6 { return Int(try r.readBits(3)) + 15 }
        x = Int(try r.readBits(6))
        if x < 62 { return x + 23 }
        if x == 62 { return Int(try r.readBits(5)) + 85 }
        return Int(try r.readBits(7)) + 117
    }
    private func readBitAfterThreshold(_ r: inout BitReader, _ threshold: Int, _ def: Int) throws -> Int {
        outputPos >= threshold ? Int(try r.readBits(1)) : def
    }
    private func readCopyTypeRange(_ r: inout BitReader) throws -> Int {
        let x = Int(try r.readBits(1))
        if x == 0 {
            let y = try readBitAfterThreshold(&r, 576, 0)
            if y != 0 { return 4 }
            return try readBitAfterThreshold(&r, 64, 0)   // 0 or 1
        } else {
            let y = try readBitAfterThreshold(&r, 64, 1)
            if y == 0 { return 3 }
            let z = try readBitAfterThreshold(&r, 2624, 1)
            return z != 0 ? 2 : 5
        }
    }
    private func readByteDecodeIndex(_ r: inout BitReader) throws -> Int {
        if byteDecodeTree.first == 0 { return 0 }
        var pos = 0
        while true {
            let bit = Int(try r.readBits(1))
            let node = byteDecodeTree[pos]
            let child = bit == 0 ? Int((node >> 4) & 0x0f) : Int(node & 0x0f)
            if child >= 10 { return child - 10 }
            pos += child
        }
    }
    private func readByte(_ r: inout BitReader) throws -> UInt8 {
        let index = try readByteDecodeIndex(&r)
        let count = try decodeVarLen(&r, Self.byteRanges, index)
        return findInHistory(count)
    }
    private func readByteBlockCount(_ r: inout BitReader) throws -> Int {
        var x = Int(try r.readBits(2))
        if x < 3 { return x + 1 }
        x = Int(try r.readBits(3))
        if x < 7 { return x + 4 }
        x = Int(try r.readBits(4))
        if x < 14 { return x + 11 }
        if x == 14 { return Int(try r.readBits(6)) + 25 }
        return Int(try r.readBits(7)) + 89
    }

    private mutating func readCopyCommand(_ r: inout BitReader, _ out: inout Data) throws {
        var rangeIndex = try readCopyTypeRange(&r)
        let count = rangeIndex < 2 ? 2 : try readCopyByteCount(&r)
        // Early-stream range redirection (fewer history bits available).
        if rangeIndex == 3 {
            if outputPos < 320 { rangeIndex = 6 }
        } else if rangeIndex == 4 {
            if outputPos < 832 { rangeIndex = 7 }
            else if outputPos < 1088 { rangeIndex = 8 }
            else if outputPos < 1600 { rangeIndex = 9 }
        } else if rangeIndex == 5 {
            if outputPos < 2880 { rangeIndex = 10 }
            else if outputPos < 3136 { rangeIndex = 11 }
            else if outputPos < 3648 { rangeIndex = 12 }
            else if outputPos < 4672 { rangeIndex = 13 }
            else if outputPos < 6720 { rangeIndex = 14 }
        }
        let dist = try decodeVarLen(&r, Self.copyRanges, rangeIndex)
        guard dist >= 0, dist < outputPos else { throw LHAError.huffmanError }
        var copyIndex = (ringPos + Self.ringSize - dist - 1) % Self.ringSize
        for _ in 0 ..< count {
            guard out.count < originalSize else { break }
            emit(ring[copyIndex], &out)
            copyIndex = (copyIndex + 1) % Self.ringSize
        }
    }
    private mutating func readByteBlock(_ r: inout BitReader, _ out: inout Data) throws {
        let blockLen = try readByteBlockCount(&r)
        for _ in 0 ..< blockLen {
            guard out.count < originalSize else { return }
            emit(try readByte(&r), &out)
        }
        if blockLen == Self.maxByteBlock { return }
        if out.count < originalSize { try readCopyCommand(&r, &out) }
    }

    // MARK: decode
    mutating func decode() throws -> Data {
        initHistory()
        var r = BitReader(data: srcData)
        var out = Data(); out.reserveCapacity(originalSize)
        // read_start_header: 5-bit index selects the byte-decode tree.
        byteDecodeTree = Self.byteDecodeTrees[Int(try r.readBits(5))]
        while out.count < originalSize {
            if try r.readBits(1) == 0 { try readCopyCommand(&r, &out) }
            else { try readByteBlock(&r, &out) }
        }
        return out
    }
}
