import Foundation

/// Low-level FAT32 cluster allocation table reader/writer.
///
/// All byte offsets passed to BlockDevice are absolute image offsets
/// (partition start byte + FAT-relative offset). This layer does not know
/// about paths or directory entries — it only manages cluster chains.
final class FAT32Table {

    // MARK: - Special cluster values (28-bit; top 4 bits are reserved)

    static let free:        UInt32 = 0x00000000
    static let badCluster:  UInt32 = 0x0FFFFFF7
    static let eocMin:      UInt32 = 0x0FFFFFF8
    static let eoc:         UInt32 = 0x0FFFFFFF
    private static let mask: UInt32 = 0x0FFFFFFF

    // MARK: - State

    let device: BlockDevice
    let bpb: FAT32BPB
    let partitionStart: Int64   // absolute byte offset of partition VBR in the image

    // MARK: - Init

    init(device: BlockDevice, bpb: FAT32BPB, partitionStart: Int64) {
        self.device = device
        self.bpb = bpb
        self.partitionStart = partitionStart
    }

    // MARK: - Entry access

    private func entryOffset(_ cluster: UInt32, fatIndex: Int = 0) -> Int64 {
        let fatByte = Int64(bpb.fatSectorOffset(fatIndex: fatIndex)) * Int64(bpb.bytesPerSector)
        return partitionStart + fatByte + Int64(cluster) * 4
    }

    func readEntry(_ cluster: UInt32) throws -> UInt32 {
        let data = try device.read(at: entryOffset(cluster), length: 4)
        return data.readLE32(at: 0) & FAT32Table.mask
    }

    /// Write `value` to the FAT entry for `cluster` in all FAT copies.
    /// The reserved top 4 bits of the existing entry are preserved.
    func writeEntry(_ cluster: UInt32, value: UInt32) throws {
        for i in 0 ..< Int(bpb.fatCount) {
            let offset = entryOffset(cluster, fatIndex: i)
            let existing = try device.read(at: offset, length: 4)
            let top4 = existing.readLE32(at: 0) & 0xF0000000
            var buf = Data(count: 4)
            buf.writeLE32(top4 | (value & FAT32Table.mask), at: 0)
            try device.write(buf, at: offset)
        }
    }

    // MARK: - Chain navigation

    /// Returns the next cluster after `cluster`, or nil for EOC / bad / free.
    func nextCluster(after cluster: UInt32) throws -> UInt32? {
        let entry = try readEntry(cluster)
        if entry == FAT32Table.free
            || entry == FAT32Table.badCluster
            || entry >= FAT32Table.eocMin { return nil }
        return entry
    }

    /// All clusters in the chain starting at `first`, in order.
    func clusterChain(startingAt first: UInt32) throws -> [UInt32] {
        var clusters: [UInt32] = []
        var current = first
        let limit = Int(bpb.clusterCount) + 4   // guard against loops in corrupt images
        while clusters.count < limit {
            clusters.append(current)
            guard let next = try nextCluster(after: current) else { break }
            current = next
        }
        return clusters
    }

    // MARK: - Allocation

    /// Allocate one free cluster, mark it EOC, and chain it after `previous` if provided.
    @discardableResult
    func allocateCluster(chainAfter previous: UInt32? = nil) throws -> UInt32 {
        for candidate: UInt32 in 2 ..< (2 &+ bpb.clusterCount) {
            if try readEntry(candidate) == FAT32Table.free {
                try writeEntry(candidate, value: FAT32Table.eoc)
                if let prev = previous { try writeEntry(prev, value: candidate) }
                return candidate
            }
        }
        throw AmigaDiskError.diskFull(requiredBlocks: 1, freeBlocks: 0)
    }

    /// Allocate `count` free clusters as a chain, optionally starting after `previous`.
    /// Returns the first allocated cluster (0 if count == 0).
    /// All-or-nothing: FAT entries hit the disk immediately, so if the volume
    /// fills partway through, the partial chain is freed and `previous` is
    /// restored to end-of-chain before the error propagates.
    @discardableResult
    func allocateChain(length count: Int, chainAfter previous: UInt32? = nil) throws -> UInt32 {
        guard count > 0 else { return 0 }
        var first: UInt32 = 0
        var last = previous
        do {
            for i in 0 ..< count {
                let c = try allocateCluster(chainAfter: last)
                if i == 0 { first = c }
                last = c
            }
        } catch {
            if first != 0 {
                try? freeChain(startingAt: first)
                if let prev = previous { try? writeEntry(prev, value: FAT32Table.eoc) }
            }
            throw error
        }
        return first
    }

    /// Mark every cluster in the chain starting at `first` as free.
    func freeChain(startingAt first: UInt32) throws {
        for c in try clusterChain(startingAt: first) {
            try writeEntry(c, value: FAT32Table.free)
        }
    }

    // MARK: - Cluster data I/O

    func clusterStartOffset(_ cluster: UInt32) -> Int64 {
        partitionStart + Int64(bpb.clusterOffset(cluster))
    }

    func readCluster(_ cluster: UInt32) throws -> Data {
        try device.read(at: clusterStartOffset(cluster), length: bpb.bytesPerCluster)
    }

    func writeCluster(_ cluster: UInt32, data: Data) throws {
        precondition(data.count == bpb.bytesPerCluster, "cluster data must be exactly \(bpb.bytesPerCluster) bytes")
        try device.write(data, at: clusterStartOffset(cluster))
    }

    /// Read the entire chain and return up to `maxBytes` bytes of data.
    func readChainData(startingAt first: UInt32, maxBytes: Int? = nil) throws -> Data {
        let chain = try clusterChain(startingAt: first)
        let clusterSize = bpb.bytesPerCluster
        let rawTotal = chain.count * clusterSize
        let limit = maxBytes.map { min($0, rawTotal) } ?? rawTotal
        var result = Data(capacity: limit)
        for cluster in chain {
            if result.count >= limit { break }
            let raw = try readCluster(cluster)
            let take = min(clusterSize, limit - result.count)
            result.append(raw.prefix(take))
        }
        return result
    }

    /// Write `data` into the existing chain starting at `first`.
    /// The chain must already be large enough to hold all the data.
    func writeChainData(startingAt first: UInt32, data: Data) throws {
        let clusterSize = bpb.bytesPerCluster
        let chain = try clusterChain(startingAt: first)
        var offset = 0
        for cluster in chain {
            guard offset < data.count else { break }
            let slice = data[data.startIndex + offset ..< min(data.startIndex + offset + clusterSize, data.endIndex)]
            var buf = Data(count: clusterSize)
            buf.replaceSubrange(0 ..< slice.count, with: slice)
            try writeCluster(cluster, data: buf)
            offset += clusterSize
        }
    }
}
