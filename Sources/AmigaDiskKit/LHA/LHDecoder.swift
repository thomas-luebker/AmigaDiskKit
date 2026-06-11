import Foundation

// LZH decoder for LHA methods -lh5-, -lh6-, -lh7-.
//
// Algorithm: sliding-window LZ77 + canonical Huffman coding.
// Two Huffman trees per block:
//   C-tree: encodes literals (0-255) and match lengths (256+ → length = token-256+THRESHOLD)
//   P-tree: encodes match positions (high bits of sliding-window offset)
//
// Parameters per method:
//   lh5: dictBits=13, maxMatch=256, NC=510, NP=14
//   lh6: dictBits=15, maxMatch=256, NC=510, NP=16
//   lh7: dictBits=16, maxMatch=256, NC=512, NP=17

struct LHDecoder {
    private static let NT        = 19   // number of T codes (for length-length tree)
    private static let TBIT      = 5    // bits for T code count in header
    private static let CBIT      = 9    // bits for C code count in header
    private static let THRESHOLD = 3    // minimum match length

    private let srcData: Data
    private let originalSize: Int
    private let dictBits: Int
    private let maxMatch: Int
    private let nc: Int
    private let np: Int

    init(data: Data, originalSize: Int, dictBits: Int, maxMatch: Int, nc: Int, np: Int) {
        self.srcData      = data
        self.originalSize = originalSize
        self.dictBits     = dictBits
        self.maxMatch     = maxMatch
        self.nc           = nc
        self.np           = np
    }

    // MARK: - Decode entry point

    func decode() throws -> Data {
        var reader   = BitReader(data: srcData)
        let dictSize = 1 << dictBits
        var dict     = [UInt8](repeating: 0x20, count: dictSize)
        var dictPos  = 0
        var out      = Data()
        out.reserveCapacity(originalSize)

        var blockRemain = 0
        var cTree = [UInt16](); var cTS = 0
        var pTree = [UInt16](); var pTS = 0

        while out.count < originalSize {
            if blockRemain == 0 {
                blockRemain = Int(try reader.readBits(16))
                if blockRemain == 0 { break }
                (cTree, cTS) = try readTree(reader: &reader, n: nc, tableSize: 12, bitCount: Self.CBIT)
                (pTree, pTS) = try readTree(reader: &reader, n: np, tableSize: dictBits, bitCount: 4)
            }
            blockRemain -= 1

            let c = Int(try huffmanDecode(tree: cTree, tableSize: cTS, reader: &reader))
            if c < 256 {
                out.append(UInt8(c))
                dict[dictPos] = UInt8(c)
                dictPos = (dictPos + 1) & (dictSize - 1)
            } else {
                let matchLen = c - 256 + Self.THRESHOLD
                let posHigh  = Int(try huffmanDecode(tree: pTree, tableSize: pTS, reader: &reader))
                // Position encoding: symbol j → back-offset = (1<<(j-1)) + GetBits(j-1)
                // (lha.c: if (j != 0) j = (1 << (j-1)) + GetBits(j-1))
                let pos: Int
                if posHigh == 0 {
                    pos = 0
                } else {
                    let extra = posHigh - 1
                    let low   = extra > 0 ? Int(try reader.readBits(extra)) : 0
                    pos = (1 << (posHigh - 1)) + low
                }
                var src = (dictPos - pos - 1 + dictSize) & (dictSize - 1)
                for _ in 0..<matchLen {
                    guard out.count < originalSize else { break }
                    let b = dict[src]
                    out.append(b)
                    dict[dictPos] = b
                    dictPos = (dictPos + 1) & (dictSize - 1)
                    src     = (src + 1) & (dictSize - 1)
                }
            }
        }
        return out
    }

    // MARK: - Tree reading

    /// Read a Huffman tree from the bitstream.
    /// Returns (lookupTable, effectiveTableSize).
    ///
    /// C-tree (n == nc): T-tree is read FIRST, then nSymbols, then C-lengths via T-tree.
    /// Reference order per block: blocksize → read_pt_len(NT) → read_c_len (nSymbols inside) → read_pt_len(NP).
    /// P-tree (n == np): plain nSymbols → 3-bit lengths, no secondary tree.
    private func readTree(reader: inout BitReader, n: Int, tableSize: Int, bitCount: Int) throws -> ([UInt16], Int) {
        if n == nc {
            // T-tree MUST be read before nSymbols (bitstream order from reference lha.c).
            let (tTree, tTS) = try readTTree(reader: &reader)
            var nSymbols = Int(try reader.readBits(bitCount))
            if nSymbols == 0 {
                let single = Int(try reader.readBits(bitCount))
                return buildSingleTable(symbol: single)
            }
            nSymbols = min(nSymbols, n)
            var lengths = [UInt8](repeating: 0, count: n)
            var i = 0
            while i < nSymbols {
                let t = Int(try huffmanDecode(tree: tTree, tableSize: tTS, reader: &reader))
                switch t {
                case 0: i += 1                                              // zero-length
                case 1: i += Int(try reader.readBits(4)) + 3               // short run
                case 2: i += Int(try reader.readBits(9)) + 20              // long run
                default:
                    lengths[i] = UInt8(t - 2); i += 1
                }
            }
            return try buildTable(lengths: lengths, n: nSymbols, tableSize: tableSize)
        } else {
            // P-tree: nSymbols FIRST, then plain 3-bit lengths (no secondary tree).
            var nSymbols = Int(try reader.readBits(bitCount))
            if nSymbols == 0 {
                let single = Int(try reader.readBits(bitCount))
                return buildSingleTable(symbol: single)
            }
            nSymbols = min(nSymbols, n)
            var lengths = [UInt8](repeating: 0, count: n)
            var i = 0
            while i < nSymbols {
                let len = Int(try reader.readBits(3))
                if len == 7 {
                    var extra = 0
                    while (try? reader.readBits(1)) == 1 { extra += 1 }
                    lengths[i] = UInt8(7 + extra)
                } else {
                    lengths[i] = UInt8(len)
                }
                i += 1
            }
            return try buildTable(lengths: lengths, n: nSymbols, tableSize: tableSize)
        }
    }

    /// Read the secondary T-tree (encodes the C-tree code lengths).
    private func readTTree(reader: inout BitReader) throws -> ([UInt16], Int) {
        var nt = Int(try reader.readBits(Self.TBIT))
        if nt == 0 {
            let single = Int(try reader.readBits(Self.TBIT))
            return buildSingleTable(symbol: single)
        }
        nt = min(nt, Self.NT)
        var lengths = [UInt8](repeating: 0, count: Self.NT)
        var i = 0
        while i < nt {
            let len = Int(try reader.readBits(3))
            if len == 7 {
                // Extended length: count consecutive set bits after the "7"
                var extra = 0
                while (try? reader.readBits(1)) == 1 { extra += 1 }
                lengths[i] = UInt8(7 + extra)
            } else {
                lengths[i] = UInt8(len)
            }
            i += 1
            if i == 3 {
                // Special RLE: skip 2-bit run of zero-length codes after index 2
                let run = Int(try reader.readBits(2))
                i += run
            }
        }
        return try buildTable(lengths: lengths, n: nt, tableSize: 6)
    }

    // MARK: - Table construction

    /// Build a flat canonical-Huffman lookup table.
    /// Dynamically extends tableSize if any code length exceeds it.
    /// Entry format: (codeLen << 9) | symbol.  0xFFFF = empty.
    private func buildTable(lengths: [UInt8], n: Int, tableSize: Int) throws -> ([UInt16], Int) {
        var maxLen = 0
        for i in 0..<n { let l = Int(lengths[i]); if l > maxLen { maxLen = l } }
        let ts = max(tableSize, maxLen)          // extend to cover all actual code lengths
        guard ts <= 16 else { throw LHAError.huffmanError }
        if ts == 0 { return ([], 0) }

        let tableLen = 1 << ts
        var table    = [UInt16](repeating: 0xFFFF, count: tableLen)

        // Count occurrences of each bit length
        var count = [Int](repeating: 0, count: 17)
        for i in 0..<n { count[Int(lengths[i])] += 1 }
        count[0] = 0    // zero-length codes don't get canonical assignments;
                        // excluding them keeps start[1]=0 (canonical-Huffman rule)

        // First canonical code for each bit length
        var start = [Int](repeating: 0, count: 18)
        var code  = 0
        for len in 1...16 {
            code = (code + count[len - 1]) << 1
            start[len] = code
        }

        // Fill the flat table
        for symbol in 0..<n {
            let len = Int(lengths[symbol])
            guard len > 0, len <= ts else { continue }
            let c     = start[len]; start[len] += 1
            let fill  = ts - len
            let base  = c << fill
            let slots = 1 << fill
            guard base + slots <= tableLen else { throw LHAError.huffmanError }
            let entry = (UInt16(len) << 9) | UInt16(symbol)
            for k in 0..<slots { table[base + k] = entry }
        }
        return (table, ts)
    }

    /// Single-symbol degenerate tree: consume 0 bits, always return `symbol`.
    private func buildSingleTable(symbol: Int) -> ([UInt16], Int) {
        ([UInt16(symbol & 0x1FF)], 0)
    }

    // MARK: - Symbol decode

    private func huffmanDecode(tree: [UInt16], tableSize: Int, reader: inout BitReader) throws -> UInt16 {
        if tableSize == 0 {
            return tree.isEmpty ? 0 : tree[0]   // single-symbol tree, consume 0 bits
        }
        let bits  = Int(try reader.peekBits(tableSize))
        let entry = tree[bits]
        guard entry != 0xFFFF else { throw LHAError.huffmanError }
        let length = Int(entry >> 9)
        let symbol = entry & 0x1FF
        if length > 0 { try reader.consumeBits(length) }
        return symbol
    }
}

// MARK: - Bit reader (MSB-first, fills 32-bit buffer 8 bits at a time)

struct BitReader {
    private let data: Data
    private var bytePos: Int  = 0
    private var bitBuf: UInt32 = 0
    private var bitsLeft: Int = 0

    init(data: Data) { self.data = data }

    mutating func readBits(_ n: Int) throws -> UInt16 {
        try fillBuf(n)
        let v = UInt16(bitBuf >> (32 - n))
        bitBuf   <<= n
        bitsLeft  -= n
        return v
    }

    mutating func peekBits(_ n: Int) throws -> UInt16 {
        try fillBuf(n)
        return UInt16(bitBuf >> (32 - n))
    }

    mutating func consumeBits(_ n: Int) throws {
        guard bitsLeft >= n else { throw LHAError.huffmanError }
        bitBuf   <<= n
        bitsLeft  -= n
    }

    private mutating func fillBuf(_ needed: Int) throws {
        while bitsLeft < needed {
            guard bytePos < data.count else {
                // Bits below position (32 - bitsLeft) are already zero from prior <<= operations.
                // Just extend bitsLeft; no shift needed (shifting would corrupt valid bits).
                bitsLeft = needed
                return
            }
            bitBuf  |= UInt32(data[bytePos]) << (24 - bitsLeft)
            bytePos  += 1
            bitsLeft += 8
        }
    }
}
