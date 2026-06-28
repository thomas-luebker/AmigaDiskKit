import Foundation

// Decoder for the PMarc -pm2- method. Ported from lhasa's pm2_decoder.c +
// pma_common.c + tree_decode.c (Simon Howard). PMarc is a rare archiver; -pm2-
// combines an adaptive move-to-front history list (literals) with periodically-
// rebuilt Huffman trees for codes and copy offsets, over an 8 KB ring buffer.
struct PM2Decoder {
    private static let ringSize = 8192
    private static let codeTreeElements = 65
    private static let offsetTreeElements = 17
    private static let leaf: UInt8 = 0x80   // TreeElement leaf bit (uint8 tree)

    private let srcData: Data
    private let originalSize: Int

    // history move-to-front linked list over 256 byte values
    private var hPrev = [Int](repeating: 0, count: 256)
    private var hNext = [Int](repeating: 0, count: 256)
    private var hHead = 0x20

    private var ring = [UInt8](repeating: 0x20, count: ringSize)
    private var ringPos = 0

    private var codeTree = [UInt8](repeating: leaf, count: codeTreeElements)
    private var offsetTree = [UInt8](repeating: leaf, count: offsetTreeElements)
    private var needOffsetTree = false

    private enum RebuildState { case unbuilt, build1, build2, build3, continuing }
    private var treeState: RebuildState = .unbuilt
    private var rebuildRemaining = 0

    init(data: Data, originalSize: Int) { self.srcData = data; self.originalSize = originalSize }

    // (offset, bits) variable-length tables
    private static let historyDecode: [(Int, Int)] =
        [(0,3),(8,3),(16,4),(32,5),(64,5),(96,5),(128,6),(192,6)]
    private static let copyDecode: [(Int, Int)] =
        [(17,3),(25,3),(33,5),(65,6),(129,7),(256,0)]

    // MARK: history list (pma_common)

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

    // MARK: tree (tree_decode)

    private func buildTree(_ tree: inout [UInt8], _ codeLengths: [UInt8], _ n: Int) {
        for i in 0 ..< tree.count { tree[i] = Self.leaf }
        var nextEntry = 0, allocated = 1, codeLen = 0
        repeat {
            // expand_queue
            let newNodes = (allocated - nextEntry) * 2
            if allocated + newNodes <= tree.count {
                let end = allocated
                while nextEntry < end { tree[nextEntry] = UInt8(allocated); allocated += 2; nextEntry += 1 }
            }
            codeLen += 1
            // add_codes_with_length
            var remaining = false
            for i in 0 ..< n {
                if Int(codeLengths[i]) == codeLen {
                    if nextEntry < allocated { tree[nextEntry] = UInt8(i) | Self.leaf; nextEntry += 1 }
                } else if Int(codeLengths[i]) > codeLen {
                    remaining = true
                }
            }
            if !remaining { break }
        } while true
    }
    private func setTreeSingle(_ tree: inout [UInt8], _ code: Int) { tree[0] = UInt8(code) | Self.leaf }
    private func readFromTree(_ tree: [UInt8], _ r: inout BitReader) throws -> Int {
        var code = tree[0]
        while (code & Self.leaf) == 0 {
            let bit = Int(try r.readBits(1))
            code = tree[Int(code) + bit]
        }
        return Int(code & ~Self.leaf)
    }
    private func decodeVarLen(_ r: inout BitReader, _ table: [(Int, Int)], _ header: Int) throws -> Int {
        let v = Int(try r.readBits(table[header].1))
        return table[header].0 + v
    }

    // MARK: tree reading (pm2)

    private mutating func readCodeTree(_ r: inout BitReader) throws {
        let numCodes = Int(try r.readBits(5))
        let minCodeLength = Int(try r.readBits(3))
        if numCodes > 29 { return }
        needOffsetTree = numCodes >= 10 && !(numCodes == 29 && minCodeLength == 0)
        if minCodeLength == 0 { setTreeSingle(&codeTree, numCodes - 1); return }
        let lengthBits = Int(try r.readBits(3))
        var lengths = [UInt8](repeating: 0, count: 31)
        for i in 0 ..< numCodes {
            let val = Int(try r.readBits(lengthBits))
            lengths[i] = val == 0 ? 0 : UInt8(minCodeLength + val - 1)
        }
        buildTree(&codeTree, lengths, numCodes)
    }
    private mutating func readOffsetTree(_ r: inout BitReader, _ numOffsets: Int) throws {
        if !needOffsetTree { return }
        var lengths = [UInt8](repeating: 0, count: 8)
        var numCodes = 0, single = 0
        for off in 0 ..< numOffsets {
            let len = Int(try r.readBits(3))
            lengths[off] = UInt8(len)
            if len != 0 { single = off; numCodes += 1 }
        }
        if numCodes == 1 { setTreeSingle(&offsetTree, single); return }
        buildTree(&offsetTree, lengths, numOffsets)
    }
    private mutating func rebuildTree(_ r: inout BitReader) throws {
        switch treeState {
        case .unbuilt:
            try readCodeTree(&r); try readOffsetTree(&r, 5)
            treeState = .build1; rebuildRemaining = 1024
        case .build1:
            try readOffsetTree(&r, 6); treeState = .build2; rebuildRemaining = 1024
        case .build2:
            try readOffsetTree(&r, 7); treeState = .build3; rebuildRemaining = 2048
        case .build3:
            if try r.readBits(1) == 1 { try readCodeTree(&r) }
            try readOffsetTree(&r, 8); treeState = .continuing; rebuildRemaining = 4096
        case .continuing:
            if try r.readBits(1) == 1 { try readCodeTree(&r); try readOffsetTree(&r, 8) }
            rebuildRemaining = 4096
        }
    }

    // MARK: decode

    mutating func decode() throws -> Data {
        initHistory()
        var r = BitReader(data: srcData)
        var out = Data(); out.reserveCapacity(originalSize)

        func emit(_ b: UInt8) throws {
            ring[ringPos] = b; ringPos = (ringPos + 1) % Self.ringSize
            out.append(b)
            updateHistory(Int(b))
            rebuildRemaining -= 1
            if rebuildRemaining == 0 { try rebuildTree(&r) }
        }

        // first read: discard a bit, build initial trees
        _ = try r.readBits(1)
        try rebuildTree(&r)

        while out.count < originalSize {
            let code = try readFromTree(codeTree, &r)
            if code < 8 {
                // single byte via history list
                let offset = try decodeVarLen(&r, Self.historyDecode, code)
                try emit(findInHistory(offset))
            } else {
                // copy from history
                let c = code - 8
                let toCopy: Int = c < 15 ? c + 2 : try decodeVarLen(&r, Self.copyDecode, c - 15)
                // offset
                var result = 0, bits: Int
                if c == 0 {
                    bits = 6
                } else if c < 20 {
                    let val = try readFromTree(offsetTree, &r)
                    if val == 0 { bits = 6 } else { bits = val + 5; result = 1 << bits }
                } else {
                    bits = 0   // offset 0
                }
                if bits > 0 { result += Int(try r.readBits(bits)) }
                let start = ringPos + Self.ringSize - 1 - result
                for i in 0 ..< toCopy {
                    guard out.count < originalSize else { break }
                    try emit(ring[(start + i) % Self.ringSize])
                }
            }
        }
        return out
    }
}
