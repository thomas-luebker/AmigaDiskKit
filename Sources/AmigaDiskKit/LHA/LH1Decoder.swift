import Foundation

// LZH decoder for the LArc-era -lh1- method (also the basis lhasa uses; there is
// no reference implementation for -lh2-/-lh3-, which were never finalised).
//
// Algorithm: 4 KB sliding ring buffer + ADAPTIVE (dynamic) Huffman over 314 codes
// (256 literals + 58 copy-length codes), with a fixed offset lookup for the high
// bits of the copy position. Ported from lhasa's lh1_decoder.c (Simon Howard),
// MSB-first bit order.
struct LH1Decoder {
    private static let ringSize = 4096
    private static let reorderLimit = 32 * 1024
    private static let numCodes = 314
    private static let numTreeNodes = numCodes * 2 - 1   // 627
    private static let numOffsets = 64
    private static let minOffsetLength = 3
    private static let copyThreshold = 3
    private static let offsetFdist = [1, 3, 8, 12, 24, 16]   // codes of length 3,4,5,6,7,8 bits

    private let srcData: Data
    private let originalSize: Int

    // Adaptive code tree (parallel arrays; nodes[0] = root).
    private var leaf       = [Bool](repeating: false, count: numTreeNodes)
    private var childIndex = [Int](repeating: 0, count: numTreeNodes)
    private var parent     = [Int](repeating: 0, count: numTreeNodes)
    private var freq       = [Int](repeating: 0, count: numTreeNodes)
    private var group      = [Int](repeating: 0, count: numTreeNodes)
    private var leafNodes  = [Int](repeating: 0, count: numCodes)
    private var groups       = [Int](repeating: 0, count: numTreeNodes)
    private var numGroups    = 0
    private var groupLeader  = [Int](repeating: 0, count: numTreeNodes)

    private var offsetLookup  = [Int](repeating: 0, count: 256)
    private var offsetLengths = [Int](repeating: 0, count: numOffsets)

    private var ring = [UInt8](repeating: 0x20, count: ringSize)
    private var ringPos = 0

    init(data: Data, originalSize: Int) {
        self.srcData = data
        self.originalSize = originalSize
    }

    // MARK: groups

    private mutating func allocGroup() -> Int { defer { numGroups += 1 }; return groups[numGroups] }
    private mutating func freeGroup(_ g: Int) { numGroups -= 1; groups[numGroups] = g }
    private mutating func initGroups() {
        for i in 0 ..< Self.numTreeNodes { groups[i] = i }
        numGroups = 0
    }

    private mutating func initTree() {
        var nodeIndex = Self.numTreeNodes - 1
        let leafGroup = allocGroup()
        for i in 0 ..< Self.numCodes {
            leaf[nodeIndex] = true
            childIndex[nodeIndex] = i
            freq[nodeIndex] = 1
            group[nodeIndex] = leafGroup
            groupLeader[leafGroup] = nodeIndex
            leafNodes[i] = nodeIndex
            nodeIndex -= 1
        }
        var child = Self.numTreeNodes - 1
        while nodeIndex >= 0 {
            leaf[nodeIndex] = false
            childIndex[nodeIndex] = child
            parent[child] = nodeIndex
            parent[child - 1] = nodeIndex
            freq[nodeIndex] = freq[child] + freq[child - 1]
            if freq[nodeIndex] == freq[nodeIndex + 1] {
                group[nodeIndex] = group[nodeIndex + 1]
            } else {
                group[nodeIndex] = allocGroup()
            }
            groupLeader[group[nodeIndex]] = nodeIndex
            nodeIndex -= 1
            child -= 2
        }
    }

    private mutating func fillOffsetRange(code: Int, mask: Int, offset: Int) {
        var i = 0
        while (i & ~mask) == 0 {
            offsetLookup[(code | i) & 0xFF] = offset
            i += 1
        }
    }

    private mutating func initOffsetTable() {
        var code = 0, offset = 0
        for i in 0 ..< Self.offsetFdist.count {
            let len = i + Self.minOffsetLength
            let iterbit = 1 << (8 - len)
            for _ in 0 ..< Self.offsetFdist[i] {
                fillOffsetRange(code: code, mask: iterbit - 1, offset: offset)
                offsetLengths[offset] = len
                code = (code + iterbit) & 0xFF
                offset += 1
            }
        }
    }

    // MARK: adaptive tree maintenance

    private mutating func makeGroupLeader(_ nodeIndex: Int) -> Int {
        let g = group[nodeIndex]
        let leaderIndex = groupLeader[g]
        if leaderIndex == nodeIndex { return nodeIndex }
        // swap leaf flag + child index between node and its group leader
        leaf.swapAt(nodeIndex, leaderIndex)
        childIndex.swapAt(nodeIndex, leaderIndex)
        if leaf[nodeIndex] {
            leafNodes[childIndex[nodeIndex]] = nodeIndex
        } else {
            parent[childIndex[nodeIndex]] = nodeIndex
            parent[childIndex[nodeIndex] - 1] = nodeIndex
        }
        if leaf[leaderIndex] {
            leafNodes[childIndex[leaderIndex]] = leaderIndex
        } else {
            parent[childIndex[leaderIndex]] = leaderIndex
            parent[childIndex[leaderIndex] - 1] = leaderIndex
        }
        return leaderIndex
    }

    private mutating func incrementNodeFreq(_ nodeIndex: Int) {
        freq[nodeIndex] += 1
        if nodeIndex < Self.numTreeNodes - 1 && group[nodeIndex] == group[nodeIndex + 1] {
            groupLeader[group[nodeIndex]] += 1
            if freq[nodeIndex] == freq[nodeIndex - 1] {
                group[nodeIndex] = group[nodeIndex - 1]
            } else {
                group[nodeIndex] = allocGroup()
                groupLeader[group[nodeIndex]] = nodeIndex
            }
        } else {
            if freq[nodeIndex] == freq[nodeIndex - 1] {
                freeGroup(group[nodeIndex])
                group[nodeIndex] = group[nodeIndex - 1]
            }
        }
    }

    private mutating func reconstructTree() {
        // Gather leaves at the front, halving frequencies (running average).
        var w = 0
        for i in 0 ..< Self.numTreeNodes where leaf[i] {
            leaf[w] = true
            childIndex[w] = childIndex[i]
            freq[w] = (freq[i] + 1) / 2
            w += 1
        }
        // Rebuild branch nodes from the end backwards.
        var leafPtr = Self.numCodes - 1
        var child = Self.numTreeNodes - 1
        var i = Self.numTreeNodes - 1
        // snapshot leaves since we overwrite nodes in place
        let lfLeaf = leaf, lfChild = childIndex, lfFreq = freq
        func copyLeaf(_ dst: Int, _ src: Int) {
            leaf[dst] = lfLeaf[src]; childIndex[dst] = lfChild[src]; freq[dst] = lfFreq[src]
            leafNodes[lfChild[src]] = dst
        }
        while i >= 0 {
            while child - i < 2 {
                copyLeaf(i, leafPtr); i -= 1; leafPtr -= 1
            }
            let f = freq[child] + freq[child - 1]
            while leafPtr >= 0 && f >= lfFreq[leafPtr] {
                copyLeaf(i, leafPtr); i -= 1; leafPtr -= 1
            }
            leaf[i] = false
            freq[i] = f
            childIndex[i] = child
            parent[child] = i
            parent[child - 1] = i
            i -= 1
            child -= 2
        }
        // Reassign groups.
        initGroups()
        var g = allocGroup()
        group[0] = g
        groupLeader[g] = 0
        for j in 1 ..< Self.numTreeNodes {
            if freq[j] == freq[j - 1] {
                group[j] = group[j - 1]
            } else {
                g = allocGroup()
                group[j] = g
                groupLeader[g] = j
            }
        }
    }

    private mutating func incrementForCode(_ code: Int) {
        if freq[0] >= Self.reorderLimit { reconstructTree() }
        freq[0] += 1
        var nodeIndex = leafNodes[code]
        while nodeIndex != 0 {
            nodeIndex = makeGroupLeader(nodeIndex)
            incrementNodeFreq(nodeIndex)
            nodeIndex = parent[nodeIndex]
        }
    }

    // MARK: decode

    mutating func decode() throws -> Data {
        initGroups(); initTree(); initOffsetTable()
        var reader = BitReader(data: srcData)
        var out = Data(); out.reserveCapacity(originalSize)

        while out.count < originalSize {
            // read_code: walk the tree from the root to a leaf.
            var nodeIndex = 0
            while !leaf[nodeIndex] {
                let bit = Int(try reader.readBits(1))
                nodeIndex = childIndex[nodeIndex] - bit
            }
            let code = childIndex[nodeIndex]
            incrementForCode(code)

            if code < 0x100 {
                let b = UInt8(code)
                out.append(b)
                ring[ringPos] = b
                ringPos = (ringPos + 1) % Self.ringSize
            } else {
                // read_offset
                let future = Int(try reader.peekBits(8))
                let offset = offsetLookup[future]
                try reader.consumeBits(offsetLengths[offset])
                let low6 = Int(try reader.readBits(6))
                let pos = (offset << 6) | low6
                let count = code - 0x100 + Self.copyThreshold
                let start = ringPos - pos + Self.ringSize - 1
                for k in 0 ..< count {
                    guard out.count < originalSize else { break }
                    let b = ring[(start + k) % Self.ringSize]
                    out.append(b)
                    ring[ringPos] = b
                    ringPos = (ringPos + 1) % Self.ringSize
                }
            }
        }
        return out
    }
}
