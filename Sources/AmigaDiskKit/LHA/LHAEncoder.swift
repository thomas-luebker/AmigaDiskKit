import Foundation

// MARK: - LHA archive writer
//
// The encode-side counterpart of LHAArchive: writes level-0 headers with
// -lh5- compression (8 KB window LZSS + per-block canonical Huffman, the
// classic ar002 format) and falls back to -lh0- (stored) whenever
// compression does not pay. The bitstream mirrors LHDecoder exactly — the
// decoder in this module IS the format spec:
//
//   block := blockSize:16
//            T-tree   (TBIT=5 count; 3-bit lens, 7+unary extension;
//                      2-bit zero-run field when the writing index hits 3)
//            C-count:CBIT=9, C-lens as T-symbols (0=one zero, 1=run 3–18+4b,
//                      2=run 20+…+9b, len+2 otherwise)
//            P-tree   (pbit=4 count; 3-bit lens, 7+unary extension)
//            symbols  (literal c<256 | match c=256+len-3, then P symbol =
//                      bitlength(dist-1), extra (j-1) low bits)
//
// Degenerate trees use the count==0 form: count-field 0, then the single
// symbol in the same field width; such codes cost 0 bits per symbol.
//
// Amiga notes: paths are stored with the 0xFF separator Amiga LhA uses
// (LHAArchive.sanitizePath maps it back to "/"); timestamps are MS-DOS
// packed local time, the only form a level-0 header has.

public struct LHAWriter {

    public struct Options {
        /// Force -lh0- (stored) for every member (mklha.py behavior).
        public var storeOnly = false
        /// Fixed timestamp for every member — deterministic archives
        /// (identical rebuilds yield identical bytes / stable sha256).
        public var fixedDate: Date? = nil
        public init() {}
    }

    private var archive = Data()
    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Append one file. `path` uses "/" separators; empty path is invalid.
    public mutating func addFile(path: String, data: Data, modificationDate: Date? = nil) throws {
        let name = Self.amigaName(path)
        guard !name.isEmpty, name.count <= 255 - 24 else {
            throw LHAError.truncatedHeader
        }
        var method = "-lh0-"
        var payload = data
        if !options.storeOnly && data.count > 32 {
            let packed = LH5Encoder.encode(data)
            if packed.count < data.count {
                method = "-lh5-"
                payload = packed
            }
        }
        archive.append(Self.level0Header(
            name: name, method: method,
            compressedSize: payload.count, originalSize: data.count,
            crc: crc16(data), date: options.fixedDate ?? modificationDate ?? Date()))
        archive.append(payload)
    }

    /// Finish the archive (appends the end-of-archive marker byte).
    public func finish() -> Data {
        var out = archive
        out.append(0)
        return out
    }

    /// Convenience: archive a host directory tree (files only, sorted paths).
    public static func archive(directory: URL, options: Options = Options()) throws -> Data {
        let fm = FileManager.default
        // Resolve symlinks on BOTH sides before computing relative paths —
        // temp dirs are /var/... while the enumerator yields /private/var/...
        // (the same trap ISO staging hit), which corrupts the prefix strip.
        let base = directory.resolvingSymlinksInPath()
        var files: [String] = []
        if let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in en {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    let full = url.resolvingSymlinksInPath().path
                    guard full.hasPrefix(base.path) else { continue }
                    let rel = full.dropFirst(base.path.count).drop(while: { $0 == "/" })
                    if !rel.isEmpty { files.append(String(rel)) }
                }
            }
        }
        var w = LHAWriter(options: options)
        for rel in files.sorted() {
            let url = base.appendingPathComponent(rel)
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            try w.addFile(path: rel, data: try Data(contentsOf: url), modificationDate: date)
        }
        return w.finish()
    }

    // MARK: header

    private static func amigaName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "\u{FF}")
    }

    private static func level0Header(name: String, method: String,
                                     compressedSize: Int, originalSize: Int,
                                     crc: UInt16, date: Date) -> Data {
        let nameBytes = [UInt8](name.unicodeScalars.map { UInt8($0.value & 0xFF) })
        var h = [UInt8]()
        h.append(contentsOf: Array(method.utf8))                    // 2..6
        h.append(contentsOf: le32(UInt32(compressedSize)))          // 7..10
        h.append(contentsOf: le32(UInt32(originalSize)))            // 11..14
        h.append(contentsOf: le32(dosTime(date)))                   // 15..18
        h.append(0x20)                                              // 19 attr
        h.append(0)                                                 // 20 level
        h.append(UInt8(nameBytes.count))                            // 21
        h.append(contentsOf: nameBytes)                             // 22..
        h.append(UInt8(crc & 0xFF)); h.append(UInt8(crc >> 8))      // crc16
        var out = Data()
        out.append(UInt8(h.count))                                  // headerSize
        out.append(UInt8(h.reduce(0) { ($0 &+ Int($1)) & 0xFF }))   // header checksum
        out.append(contentsOf: h)
        return out
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    private static func dosTime(_ date: Date) -> UInt32 {
        let c = Calendar(identifier: .gregorian)
        let d = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = max(1980, min(2107, d.year ?? 1980)) - 1980
        return UInt32(y) << 25 | UInt32(d.month ?? 1) << 21 | UInt32(d.day ?? 1) << 16
             | UInt32(d.hour ?? 0) << 11 | UInt32(d.minute ?? 0) << 5
             | UInt32((d.second ?? 0) / 2)
    }
}

// MARK: - lh5 block encoder

enum LH5Encoder {
    private static let dictBits   = 13
    private static let dictSize   = 1 << 13          // 8192
    private static let maxMatch   = 256
    private static let threshold  = 3
    private static let nc         = 510
    private static let np         = 14
    private static let nt         = 19
    private static let tbit       = 5
    private static let cbit       = 9
    private static let pbit       = 4
    private static let blockLimit = 16_000           // symbols per block (< 0xFFFF)

    private struct Token { let c: Int; let pos: Int }   // c<256 literal; else match, pos=dist-1

    static func encode(_ input: Data) -> Data {
        var writer = LHABitWriter()
        let src = [UInt8](input)
        var tokens: [Token] = []
        tokens.reserveCapacity(blockLimit)

        // LZSS parse with 3-byte hash chains (greedy — every parse is valid).
        var head = [Int](repeating: -1, count: 1 << 15)
        var next = [Int](repeating: -1, count: src.count)
        @inline(__always) func hash(_ i: Int) -> Int {
            (Int(src[i]) << 7 ^ Int(src[i + 1]) << 4 ^ Int(src[i + 2])) & 0x7FFF
        }
        @inline(__always) func insert(_ i: Int) {
            guard i + 2 < src.count else { return }
            let h = hash(i)
            next[i] = head[h]
            head[h] = i
        }

        var i = 0
        while i < src.count {
            var bestLen = 0, bestDist = 0
            if i + threshold <= src.count && i + 2 < src.count {
                var cand = head[hash(i)]
                var chain = 0
                let limit = min(maxMatch, src.count - i)
                while cand >= 0 && chain < 64 {
                    let dist = i - cand
                    if dist > dictSize { break }
                    var l = 0
                    while l < limit && src[cand + l] == src[i + l] { l += 1 }
                    if l > bestLen { bestLen = l; bestDist = dist
                        if l >= limit { break } }
                    cand = next[cand]; chain += 1
                }
            }
            if bestLen >= threshold {
                tokens.append(Token(c: 256 + bestLen - threshold, pos: bestDist - 1))
                for k in 0..<bestLen { insert(i + k) }
                i += bestLen
            } else {
                tokens.append(Token(c: Int(src[i]), pos: 0))
                insert(i)
                i += 1
            }
            if tokens.count >= blockLimit {
                flushBlock(tokens, to: &writer)
                tokens.removeAll(keepingCapacity: true)
            }
        }
        if !tokens.isEmpty { flushBlock(tokens, to: &writer) }
        return writer.finish()
    }

    // MARK: block emission

    private static func flushBlock(_ tokens: [Token], to w: inout LHABitWriter) {
        w.put(tokens.count, bits: 16)

        var cFreq = [Int](repeating: 0, count: nc)
        var pFreq = [Int](repeating: 0, count: np)
        for t in tokens {
            cFreq[t.c] += 1
            if t.c >= 256 { pFreq[pSymbol(t.pos)] += 1 }
        }
        var cLen = Huffman.lengths(freq: cFreq, limit: 16)
        var pLen = Huffman.lengths(freq: pFreq, limit: 16)

        writeCTable(cLen, to: &w)
        writeSmallTable(pLen, count: np, countBits: pbit, special: nil, to: &w)

        // Degenerate trees are written in the count==0 single-symbol form,
        // which the decoder reads with ZERO bits per symbol - the emission
        // lengths must match or the bitstream desyncs (found the hard way:
        // any file whose matches all share one distance class).
        if cLen.filter({ $0 > 0 }).count <= 1 { cLen = cLen.map { _ in 0 } }
        if pLen.filter({ $0 > 0 }).count <= 1 { pLen = pLen.map { _ in 0 } }
        let cCode = Huffman.canonicalCodes(lengths: cLen)
        let pCode = Huffman.canonicalCodes(lengths: pLen)

        for t in tokens {
            if cLen[t.c] > 0 { w.put(cCode[t.c], bits: Int(cLen[t.c])) }
            if t.c >= 256 {
                let j = pSymbol(t.pos)
                if pLen[j] > 0 { w.put(pCode[j], bits: Int(pLen[j])) }
                if j > 1 { w.put(t.pos & ((1 << (j - 1)) - 1), bits: j - 1) }
            }
        }
    }

    @inline(__always) private static func pSymbol(_ pos: Int) -> Int {
        pos == 0 ? 0 : Int.bitWidth - pos.leadingZeroBitCount   // bit length of pos
    }

    /// C-table: T-tree first, then CBIT count, then C-lens via T symbols.
    private static func writeCTable(_ cLen: [UInt8], to w: inout LHABitWriter) {
        // Build the T symbol stream describing cLen.
        var stream: [(sym: Int, extra: Int, extraBits: Int)] = []
        var n = nc
        while n > 0 && cLen[n - 1] == 0 { n -= 1 }
        var i = 0
        while i < n {
            if cLen[i] == 0 {
                var run = 1
                while i + run < n && cLen[i + run] == 0 { run += 1 }
                i += run
                while run > 0 {
                    if run <= 2 {
                        for _ in 0..<run { stream.append((0, 0, 0)) }
                        run = 0
                    } else if run <= 18 {
                        stream.append((1, run - 3, 4)); run = 0
                    } else if run == 19 {
                        stream.append((0, 0, 0)); stream.append((1, 15, 4)); run = 0
                    } else {
                        let take = min(run, 20 + 511)
                        stream.append((2, take - 20, cbit)); run -= take
                    }
                }
            } else {
                stream.append((Int(cLen[i]) + 2, 0, 0)); i += 1
            }
        }

        var tFreq = [Int](repeating: 0, count: nt)
        for s in stream { tFreq[s.sym] += 1 }
        let used = tFreq.enumerated().filter { $0.element > 0 }.map(\.offset)

        if n == 0 || used.isEmpty {
            // No C symbols at all (empty input) — degenerate everything.
            w.put(0, bits: tbit); w.put(0, bits: tbit)
            w.put(0, bits: cbit); w.put(0, bits: cbit)
            return
        }
        if used.count == 1 && stream.count > 1 {
            // Single T symbol: 0-bit codes via the count==0 form.
            w.put(0, bits: tbit); w.put(used[0], bits: tbit)
        } else if used.count == 1 {
            w.put(0, bits: tbit); w.put(used[0], bits: tbit)
        } else {
            let tLen = Huffman.lengths(freq: tFreq, limit: 16)
            writeSmallTable(tLen, count: nt, countBits: tbit, special: 3, to: &w)
        }
        // C symbol count + stream. A single distinct C symbol uses the
        // degenerate form (the decoder returns early, so no lens follow).
        var distinctC = 0, lastC = 0
        for s in 0..<nc where cLen[s] > 0 { distinctC += 1; lastC = s }
        if distinctC == 1 && streamOnlyDescribes(single: lastC, n: n) {
            w.put(0, bits: cbit); w.put(lastC, bits: cbit)
            return
        }
        w.put(n, bits: cbit)
        let tLenArr: [UInt8]
        let tCodeArr: [Int]
        if used.count == 1 {
            tLenArr = [UInt8](repeating: 0, count: nt)
            tCodeArr = [Int](repeating: 0, count: nt)
        } else {
            tLenArr = Huffman.lengths(freq: tFreq, limit: 16)
            tCodeArr = Huffman.canonicalCodes(lengths: tLenArr)
        }
        for s in stream {
            if tLenArr[s.sym] > 0 { w.put(tCodeArr[s.sym], bits: Int(tLenArr[s.sym])) }
            if s.extraBits > 0 { w.put(s.extra, bits: s.extraBits) }
        }
    }

    /// A C table with ONE distinct symbol can use the degenerate form only if
    /// no leading zeros would need describing (symbol may sit anywhere — the
    /// decoder's single form carries the symbol index, so always OK).
    private static func streamOnlyDescribes(single: Int, n: Int) -> Bool { true }

    /// T-tree / P-tree writer: count field, 3-bit lens with 7+unary
    /// extension; T adds the 2-bit zero-run field when the index hits 3.
    private static func writeSmallTable(_ lens: [UInt8], count total: Int,
                                        countBits: Int, special: Int?,
                                        to w: inout LHABitWriter) {
        var n = total
        while n > 0 && lens[n - 1] == 0 { n -= 1 }
        var used: [Int] = []
        for s in 0..<total where lens[s] > 0 { used.append(s) }
        if used.isEmpty {
            w.put(0, bits: countBits); w.put(0, bits: countBits)
            return
        }
        if used.count == 1 {
            w.put(0, bits: countBits); w.put(used[0], bits: countBits)
            return
        }
        w.put(n, bits: countBits)
        var i = 0
        while i < n {
            let k = Int(lens[i]); i += 1
            if k <= 6 {
                w.put(k, bits: 3)
            } else {
                // 3 bits "111" then (k-7) ones and a zero: total k-3 bits
                // holding the value (1<<(k-3)) - 2.
                w.put((1 << (k - 3)) - 2, bits: k - 3)
            }
            if special == 3 && i == 3 {
                var skip = 0
                while i < n && i < 6 && lens[i] == 0 && skip < 3 { i += 1; skip += 1 }
                w.put(skip, bits: 2)
            }
        }
    }
}

// MARK: - Length-limited canonical Huffman (package-merge)

enum Huffman {

    /// Package-merge length-limited code lengths. Symbols with freq 0 get 0.
    static func lengths(freq: [Int], limit: Int) -> [UInt8] {
        let n = freq.count
        var lens = [UInt8](repeating: 0, count: n)
        let active = freq.enumerated().filter { $0.element > 0 }
        if active.isEmpty { return lens }
        if active.count == 1 { lens[active[0].offset] = 1; return lens }

        // package-merge: coins[level] sorted by weight; each original coin
        // carries its symbol, packages carry their contents.
        struct Coin { let weight: Int; let symbols: [Int] }
        var prev: [Coin] = []
        for _ in 0..<limit {
            var row = active.map { Coin(weight: $0.element, symbols: [$0.offset]) }
            var pi = 0
            while pi + 1 < prev.count {
                row.append(Coin(weight: prev[pi].weight + prev[pi + 1].weight,
                                symbols: prev[pi].symbols + prev[pi + 1].symbols))
                pi += 2
            }
            row.sort { $0.weight < $1.weight }
            prev = row
        }
        let take = 2 * active.count - 2
        for coin in prev.prefix(take) {
            for s in coin.symbols { lens[s] += 1 }
        }
        return lens
    }

    /// Canonical codes matching LHDecoder.buildTable: symbols in ascending
    /// index order within each length, MSB-first.
    static func canonicalCodes(lengths: [UInt8]) -> [Int] {
        var count = [Int](repeating: 0, count: 17)
        for l in lengths where l > 0 { count[Int(l)] += 1 }
        var start = [Int](repeating: 0, count: 18)
        var code = 0
        for len in 1...16 {
            code = (code + count[len - 1]) << 1
            start[len] = code
        }
        var codes = [Int](repeating: 0, count: lengths.count)
        for s in 0..<lengths.count {
            let l = Int(lengths[s])
            guard l > 0 else { continue }
            codes[s] = start[l]; start[l] += 1
        }
        return codes
    }
}

// MARK: - Bit writer (MSB-first, mirror of BitReader)

struct LHABitWriter {
    private var out = Data()
    private var buf: UInt32 = 0
    private var nbits = 0

    mutating func put(_ value: Int, bits: Int) {
        guard bits > 0 else { return }
        buf |= UInt32(truncatingIfNeeded: value & ((1 << bits) - 1)) << (32 - nbits - bits)
        nbits += bits
        while nbits >= 8 {
            out.append(UInt8(buf >> 24))
            buf <<= 8
            nbits -= 8
        }
    }

    mutating func finish() -> Data {
        if nbits > 0 { out.append(UInt8(buf >> 24)); buf = 0; nbits = 0 }
        return out
    }
}
