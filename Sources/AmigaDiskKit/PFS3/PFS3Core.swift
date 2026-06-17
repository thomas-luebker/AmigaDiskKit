import Foundation

/// PFS3 volume machinery: LRU cache, reserved-block allocation, anodes, and
/// the update (commit) engine. Ported function-for-function from hst-amiga
/// `Hst.Amiga.FileSystems.Pfs3` (Lru.cs, Allocation.cs, anodes.cs, Update.cs,
/// Init.cs, Volume.cs, Directory.cs), which is itself a port of pfs3aio.
///
/// Fidelity matters: PFS3 never overwrites reserved blocks in place — dirty
/// blocks are REALLOCATED via AllocReservedBlock (roving scan) when first
/// dirtied after a commit, so the on-disk layout is a deterministic function
/// of this exact call sequence. The golden-fixture tests depend on it.

// MARK: - Cached block

final class PFS3CachedBlock {
    var blocknr: UInt32 = 0
    /// blocknr before reallocation; 0 if not reallocated.
    var oldblocknr: UInt32 = 0
    /// Block locked if used == g.locknr.
    var used: UInt16 = 0
    var changeflag = false
    var blk: PFS3Block?

    var anodeBlock: PFS3AnodeBlock? { blk as? PFS3AnodeBlock }
    var indexBlock: PFS3IndexBlock? { blk as? PFS3IndexBlock }
    var rext: PFS3RootBlockExtension? { blk as? PFS3RootBlockExtension }
    var deldirBlock: PFS3DelDirBlock? { blk as? PFS3DelDirBlock }
    var dirBlock: PFS3DirBlock? { blk as? PFS3DirBlock }
    var bitmapBlock: PFS3BitmapBlock? { blk as? PFS3BitmapBlock }
}

/// One allocation node with its number (canode in the original).
struct PFS3CAnode {
    var clustersize: UInt32 = 0
    var blocknr: UInt32 = 0
    var next: UInt32 = 0
    var nr: UInt32 = 0
}

// MARK: - Global state (globaldata + volumedata + sub-structs)

final class PFS3G {
    let device: BlockDevice
    /// Absolute device LBA of partition sector 0 (sliceStartLBA + lowCyl × blocksPerCyl).
    let baseLBA: Int64

    var rootBlock: PFS3RootBlock!
    let blocksize: UInt32 = 512
    var blockshift: UInt16 = 9
    var fnsize: UInt16 = 32
    var totalSectors: UInt32
    var dirty = false
    var uip = false
    var updateok = true
    /// Wall-clock "now" — injected so tests can pin volume/creation dates.
    var now = Date()
    var locknr: UInt16 = 1
    var numBuffers: UInt32
    var supermode = false
    var harddiskmode = true
    var anodesplitmode = true
    var dirextension = true
    var deldirenabled = false

    // volumedata
    var rblkextension: PFS3CachedBlock?
    var anblks: [UInt32: PFS3CachedBlock] = [:]
    var dirblks: [UInt32: PFS3CachedBlock] = [:]
    var indexblks: [UInt32: PFS3CachedBlock] = [:]
    var indexblksBySeqNr: [UInt32: PFS3CachedBlock] = [:]
    var bmblks: [UInt32: PFS3CachedBlock] = [:]
    var bmblksBySeqNr: [UInt32: PFS3CachedBlock] = [:]
    var superblks: [UInt32: PFS3CachedBlock] = [:]
    var superblksBySeqNr: [UInt32: PFS3CachedBlock] = [:]
    var deldirblks: [UInt32: PFS3CachedBlock] = [:]
    var deldirblksBySeqNr: [UInt32: PFS3CachedBlock] = [:]
    var bmindexblks: [UInt32: PFS3CachedBlock] = [:]
    var bmindexblksBySeqNr: [UInt32: PFS3CachedBlock] = [:]
    var rootblockchangeflag = false
    var numblocks: UInt32 = 0
    var rescluster: UInt32 = 1

    // lru_data_s (useLruArray=false variant)
    var lruQueue: [PFS3CachedBlock] = []   // index 0 = most recently used
    var lruPool: [PFS3CachedBlock] = []

    // anode_data_s
    var curranseqnr: UInt16 = 0
    var indexperblock: UInt16 = 0
    var maxanodeseqnr: UInt32 = 0
    var anodesperblock: UInt16 = 0
    var reservedAnodes: UInt16 = 0   // andata.reserved
    var anblkbitmap: [UInt32] = []
    var anblkbitmapsize: UInt32 = 0
    var maxanseqnr: UInt32 = 0

    // allocation_data_s
    var clean_blocksfree: UInt32 = 0
    var alloc_available: UInt32 = 0
    var longsperbmb: UInt32 = 0
    var no_bmb: UInt32 = 0
    var bitmapstart: UInt32 = 0
    var tobefreed: [(blocknr: UInt32, size: UInt32)] = []
    var tbf_resneed: UInt32 = 0
    var res_roving: UInt32 = 0
    var rovingbit: UInt32 = 0
    var numreserved: UInt32 = 0
    var reservedtobefreed: [UInt32] = []

    var resBlockSize: Int { Int(rootBlock.reservedBlksize) }

    init(device: BlockDevice, sliceStartLBA: Int64,
         blocksPerTrack: UInt32, surfaces: UInt32,
         lowCyl: UInt32, highCyl: UInt32, numBuffers: UInt32) {
        self.device = device
        let blocksPerCylinder = blocksPerTrack * surfaces
        totalSectors = (highCyl - lowCyl + 1) * blocksPerCylinder
        baseLBA = sliceStartLBA + Int64(lowCyl) * Int64(blocksPerCylinder)
        self.numBuffers = numBuffers
    }

    /// 68k divu-compatible divide: low word = quotient, high word = remainder.
    static func divide(_ d0: UInt32, _ d1: UInt32) -> UInt32 {
        let q = d0 / d1
        if q > 65535 { return d0 }
        return ((d0 % d1) << 16) | q
    }
}

// MARK: - Disk raw I/O (Disk.cs)

enum PFS3Disk {
    static func rawRead(blocks: UInt32, blocknr: UInt32, _ g: PFS3G) throws -> Data {
        guard blocknr != 0xFFFFFFFF else {
            throw AmigaDiskError.readFailed(offset: 0, length: 0, reason: "PFS3 read of uninitialised anode")
        }
        return try g.device.read(at: (g.baseLBA + Int64(blocknr)) * 512,
                                 length: Int(blocks) * 512)
    }

    static func rawWrite(_ data: Data, blocks: UInt32, blocknr: UInt32, _ g: PFS3G) throws {
        guard blocknr != 0xFFFFFFFF else { return }
        let length = min(data.count, Int(blocks) * 512)
        try g.device.write(data.prefix(length), at: (g.baseLBA + Int64(blocknr)) * 512)
    }

    static func rawWrite(block: PFS3Block, blocks: UInt32, blocknr: UInt32, _ g: PFS3G) throws {
        try rawWrite(block.serialize(size: Int(blocks) * 512), blocks: blocks, blocknr: blocknr, g)
    }

    /// Parse a reserved block read from disk into its typed representation.
    static func readReservedBlock(blocknr: UInt32, _ g: PFS3G) throws -> PFS3Block? {
        let data = try rawRead(blocks: g.rescluster, blocknr: blocknr, g)
        let resSize = g.resBlockSize
        switch data.readBE16(at: 0) {
        case PFS3.dirBlockID:
            return PFS3DirBlock(data: data, entrySpace: PFS3DirBlock.entrySpace(reservedBlksize: resSize))
        case PFS3.anodeBlockID:
            return PFS3AnodeBlock(data: data, slots: PFS3AnodeBlock.anodesPerBlock(reservedBlksize: resSize))
        case PFS3.indexBlockID:
            return PFS3IndexBlock(id: PFS3.indexBlockID, data: data, longs: (resSize - 12) / 4)
        case PFS3.bitmapBlockID:
            return PFS3BitmapBlock(data: data, longs: (resSize - 12) / 4)
        case PFS3.bitmapIndexBlockID:
            return PFS3IndexBlock(id: PFS3.bitmapIndexBlockID, data: data, longs: (resSize - 12) / 4)
        case PFS3.superBlockID:
            return PFS3IndexBlock(id: PFS3.superBlockID, data: data, longs: (resSize - 12) / 4)
        case PFS3.deldirBlockID:
            return PFS3DelDirBlock(data: data)
        case PFS3.extensionBlockID:
            return PFS3RootBlockExtension(data: data)
        default:
            return nil
        }
    }
}

// MARK: - LRU cache (Lru.cs, useLruArray = false)

enum PFS3Lru {
    static let newLRUEntries = 5

    static func lock(_ blk: PFS3CachedBlock, _ g: PFS3G) { blk.used = g.locknr }
    static func isLocked(_ blk: PFS3CachedBlock, _ g: PFS3G) -> Bool { blk.used == g.locknr }

    static func makeLRU(_ blk: PFS3CachedBlock, _ g: PFS3G) {
        minRemoveLru(blk, g)
        g.lruQueue.insert(blk, at: 0)
    }

    static func freeLRU(_ blk: PFS3CachedBlock, _ g: PFS3G) {
        minRemoveLru(blk, g)
        clearBlock(blk)
        g.lruPool.insert(blk, at: 0)
    }

    static func minRemoveLru(_ blk: PFS3CachedBlock, _ g: PFS3G) {
        g.lruQueue.removeAll { $0 === blk }
        g.lruPool.removeAll { $0 === blk }
    }

    private static func clearBlock(_ blk: PFS3CachedBlock) {
        blk.blocknr = 0
        blk.oldblocknr = 0
        blk.used = 0
        blk.changeflag = false
        blk.blk = nil
    }

    /// Remove a cached block from the volume dictionaries it appears in.
    static func minRemove(_ node: PFS3CachedBlock, _ g: PFS3G) {
        guard let blk = node.blk else { return }
        switch blk.id {
        case PFS3.anodeBlockID:
            g.anblks.removeValue(forKey: node.blocknr)
        case PFS3.dirBlockID:
            g.dirblks.removeValue(forKey: node.blocknr)
        case PFS3.indexBlockID:
            g.indexblks.removeValue(forKey: node.blocknr)
            if let ib = node.indexBlock, g.indexblksBySeqNr[ib.seqnr] === node {
                g.indexblksBySeqNr.removeValue(forKey: ib.seqnr)
            }
        case PFS3.bitmapBlockID:
            g.bmblks.removeValue(forKey: node.blocknr)
            if let bb = node.bitmapBlock, g.bmblksBySeqNr[bb.seqnr] === node {
                g.bmblksBySeqNr.removeValue(forKey: bb.seqnr)
            }
        case PFS3.superBlockID:
            g.superblks.removeValue(forKey: node.blocknr)
            if let sb = node.indexBlock, g.superblksBySeqNr[sb.seqnr] === node {
                g.superblksBySeqNr.removeValue(forKey: sb.seqnr)
            }
        case PFS3.deldirBlockID:
            g.deldirblks.removeValue(forKey: node.blocknr)
            if let dd = node.deldirBlock, g.deldirblksBySeqNr[dd.seqnr] === node {
                g.deldirblksBySeqNr.removeValue(forKey: dd.seqnr)
            }
        case PFS3.bitmapIndexBlockID:
            g.bmindexblks.removeValue(forKey: node.blocknr)
            if let bi = node.indexBlock, g.bmindexblksBySeqNr[bi.seqnr] === node {
                g.bmindexblksBySeqNr.removeValue(forKey: bi.seqnr)
            }
        default:
            break
        }
    }

    /// Make a cached block ready for reuse (decouple + wipe). NOT removed from LRU.
    static func flushBlock(_ block: PFS3CachedBlock, _ g: PFS3G) {
        minRemove(block, g)
        clearBlock(block)
    }

    static func allocLRU(_ g: PFS3G) throws -> PFS3CachedBlock {
        while true {
            if g.lruPool.isEmpty {
                // Evict the least-recently-used unlocked block.
                for blk in g.lruQueue.reversed() {
                    if isLocked(blk, g) { continue }
                    if blk.changeflag {
                        resToBeFreed(blk.oldblocknr, g)
                        PFS3Update.updateDatestamp(blk, g)
                        guard let payload = blk.blk else {
                            throw AmigaDiskError.invalidGeometry(reason: "PFS3 LRU: dirty block without payload")
                        }
                        try PFS3Disk.rawWrite(block: payload, blocks: g.rescluster, blocknr: blk.blocknr, g)
                    }
                    flushBlock(blk, g)
                    g.lruQueue.removeAll { $0 === blk }
                    g.lruQueue.insert(blk, at: 0)
                    lock(blk, g)
                    return blk
                }
                for _ in 0 ..< newLRUEntries {
                    g.lruPool.insert(PFS3CachedBlock(), at: 0)
                }
                continue
            }
            let blk = g.lruPool.removeFirst()
            g.lruQueue.insert(blk, at: 0)
            lock(blk, g)
            return blk
        }
    }

    /// Add a reserved block to the to-be-freed-at-next-update cache.
    static func resToBeFreed(_ blocknr: UInt32, _ g: PFS3G) {
        if blocknr != 0 {
            g.reservedtobefreed.append(blocknr)
        }
    }
}

// MARK: - Reserved-block allocation (Allocation.cs)

enum PFS3Allocation {

    static func allocReservedBlock(_ g: PFS3G) -> UInt32 {
        guard let bitmap = g.rootBlock.reservedBitmap, g.rootBlock.reservedFree != 0 else { return 0 }

        var j = Int(31 - g.res_roving % 32)
        var i = Int(g.res_roving / 32)
        while i < Int((g.numreserved + 31) / 32) {
            if bitmap.bitmap[i] != 0 {
                let field = bitmap.bitmap[i]
                while j >= 0 {
                    if field & (1 << UInt32(j)) != 0 {
                        let blocknr = g.rootBlock.firstReserved
                            + UInt32(i * 32 + (31 - j)) * g.rescluster
                        if blocknr <= g.rootBlock.lastReserved {
                            bitmap.bitmap[i] &= ~(1 << UInt32(j))
                            g.rootblockchangeflag = true
                            g.dirty = true
                            g.rootBlock.reservedFree -= 1
                            g.res_roving = UInt32(32 * i + (31 - j))
                            return blocknr
                        }
                    }
                    j -= 1
                }
            }
            i += 1
            j = 31
        }

        // end of bitmap reached — reset roving pointer and try again
        if g.res_roving != 0 {
            g.res_roving = 0
            return allocReservedBlock(g)
        }
        return 0
    }

    static func freeReservedBlock(_ blocknr: UInt32, _ g: PFS3G) {
        guard blocknr != 0, blocknr <= g.rootBlock.lastReserved,
              let bitmap = g.rootBlock.reservedBitmap else { return }
        let t = (blocknr - g.rootBlock.firstReserved) / g.rescluster
        bitmap.bitmap[Int(t / 32)] |= 0x8000_0000 >> (t % 32)
        g.rootBlock.reservedFree += 1
        g.rootblockchangeflag = true
    }

    static func newBitmapBlock(seqnr: UInt32, _ g: PFS3G) throws -> PFS3CachedBlock? {
        let indexblnr = seqnr / UInt32(g.indexperblock)
        let indexoffset = seqnr % UInt32(g.indexperblock)
        var indexblock: PFS3CachedBlock
        if let existing = try getBitmapIndex(UInt16(indexblnr), g) {
            indexblock = existing
        } else if let fresh = try newBitmapIndexBlock(UInt16(indexblnr), g) {
            indexblock = fresh
        } else {
            return nil
        }

        let oldlock = indexblock.used
        PFS3Lru.lock(indexblock, g)
        let blok = try PFS3Lru.allocLRU(g)
        let blocknr = allocReservedBlock(g)
        guard blocknr != 0 else { return nil }

        indexblock.indexBlock!.index[Int(indexoffset)] = Int32(bitPattern: blocknr)

        blok.blocknr = blocknr
        blok.used = 0
        let bmb = PFS3BitmapBlock(longs: Int(g.longsperbmb))
        bmb.seqnr = seqnr
        for i in 0 ..< Int(g.longsperbmb) { bmb.bitmap[i] = .max }
        blok.blk = bmb
        blok.changeflag = true

        g.bmblks[blok.blocknr] = blok
        g.bmblksBySeqNr[seqnr] = blok
        _ = try PFS3Update.makeBlockDirty(indexblock, g)
        indexblock.used = oldlock
        return blok
    }

    static func newBitmapIndexBlock(_ seqnr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        guard seqnr <= (g.supermode ? UInt16(PFS3.maxBitmapIndex) : UInt16(PFS3.maxSmallBitmapIndex)) else {
            return nil
        }
        let blok = try PFS3Lru.allocLRU(g)
        let blocknr = allocReservedBlock(g)
        guard blocknr != 0 else {
            PFS3Lru.freeLRU(blok, g)
            return nil
        }
        // idx.large.bitmapindex[seqnr] aliases idx.small.bitmapindex for seqnr ≤ 4.
        g.rootBlock.setLargeBitmapIndex(Int(seqnr), blocknr)
        g.rootblockchangeflag = true

        blok.blocknr = blocknr
        blok.used = 0
        let ib = PFS3IndexBlock(id: PFS3.bitmapIndexBlockID, longs: (g.resBlockSize - 12) / 4)
        ib.seqnr = UInt32(seqnr)
        blok.blk = ib
        blok.changeflag = true
        g.bmindexblks[blocknr] = blok
        g.bmindexblksBySeqNr[UInt32(seqnr)] = blok
        return blok
    }

    static func getBitmapIndex(_ nr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        if let cached = g.bmindexblksBySeqNr[UInt32(nr)] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }

        guard nr <= (g.supermode ? UInt16(PFS3.maxBitmapIndex) : UInt16(PFS3.maxSmallBitmapIndex)) else { return nil }
        let blocknr = g.rootBlock.largeBitmapIndex(Int(nr))
        guard blocknr != 0 else { return nil }

        let indexblk = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.bitmapIndexBlockID else {
            PFS3Lru.freeLRU(indexblk, g)
            return nil
        }
        indexblk.blk = blk
        indexblk.blocknr = blocknr
        indexblk.used = 0
        indexblk.changeflag = false
        g.bmindexblks[blocknr] = indexblk
        g.bmindexblksBySeqNr[UInt32(nr)] = indexblk
        PFS3Lru.lock(indexblk, g)
        return indexblk
    }

    static func getBitmapBlock(_ seqnr: UInt32, _ g: PFS3G) throws -> PFS3CachedBlock? {
        if let cached = g.bmblksBySeqNr[seqnr] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }

        let temp = PFS3G.divide(seqnr, UInt32(g.indexperblock))
        guard let indexblock = try getBitmapIndex(UInt16(truncatingIfNeeded: temp), g) else { return nil }
        let blocknr = UInt32(bitPattern: indexblock.indexBlock!.index[Int(temp >> 16)])
        guard blocknr != 0 else { return nil }

        let bmb = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.bitmapBlockID else {
            PFS3Lru.freeLRU(bmb, g)
            return nil
        }
        bmb.blk = blk
        bmb.blocknr = blocknr
        bmb.used = 0
        bmb.changeflag = false
        g.bmblks[blocknr] = bmb
        g.bmblksBySeqNr[seqnr] = bmb
        return bmb
    }

    /// Commit the user-space to-be-freed list to the main bitmap.
    static func updateFreeList(_ g: PFS3G) throws {
        var bitmap: PFS3CachedBlock? = nil
        var bmseqnr: UInt32 = .max
        for entry in g.tobefreed {
            for blocknr in entry.blocknr ..< entry.blocknr + entry.size {
                let bitnr = blocknr - g.bitmapstart
                let longnr = bitnr / 32
                let newbmseqnr = longnr / g.longsperbmb
                let bmoffset = longnr % g.longsperbmb
                if newbmseqnr != bmseqnr {
                    bmseqnr = newbmseqnr
                    bitmap = try getBitmapBlock(bmseqnr, g)
                }
                guard let bm = bitmap, let bmBlk = bm.bitmapBlock else {
                    throw AmigaDiskError.invalidGeometry(reason: "PFS3 updateFreeList: bitmap block missing")
                }
                bmBlk.bitmap[Int(bmoffset)] |= 1 << (31 - (bitnr % 32))
                _ = try PFS3Update.makeBlockDirty(bm, g)
            }
            g.clean_blocksfree += entry.size
        }
        g.tobefreed.removeAll()
        g.tbf_resneed = 0
        g.rootBlock.blocksFree = g.clean_blocksfree
        g.rootblockchangeflag = true
    }
}

// MARK: - Anodes (anodes.cs)

enum PFS3Anodes {

    static func getIndexBlock(_ nr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        if let cached = g.indexblksBySeqNr[UInt32(nr)] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }

        var blocknr: UInt32
        if g.supermode {
            let temp = PFS3G.divide(UInt32(nr), UInt32(g.indexperblock))
            guard let superblk = try getSuperBlock(UInt16(truncatingIfNeeded: temp), g) else { return nil }
            blocknr = UInt32(bitPattern: superblk.indexBlock!.index[Int(temp >> 16)])
            guard blocknr != 0 else { return nil }
        } else {
            guard nr <= UInt16(PFS3.maxSmallIndexNr) else { return nil }
            blocknr = g.rootBlock.smallIndexBlock(Int(nr))
            guard blocknr != 0 else { return nil }
        }

        let indexblk = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.indexBlockID else {
            PFS3Lru.freeLRU(indexblk, g)
            return nil
        }
        indexblk.blk = blk
        indexblk.blocknr = blocknr
        indexblk.used = 0
        indexblk.changeflag = false
        g.indexblks[blocknr] = indexblk
        g.indexblksBySeqNr[UInt32(nr)] = indexblk
        return indexblk
    }

    static func getSuperBlock(_ nr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        guard g.supermode else { return nil }
        if let cached = g.superblksBySeqNr[UInt32(nr)] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }
        guard nr <= UInt16(PFS3.maxSuper),
              let rext = g.rblkextension?.rext else { return nil }
        let blocknr = rext.superindex[Int(nr)]
        guard blocknr != 0 else { return nil }

        let superblk = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.superBlockID else {
            PFS3Lru.freeLRU(superblk, g)
            return nil
        }
        superblk.blk = blk
        superblk.blocknr = blocknr
        superblk.used = 0
        superblk.changeflag = false
        g.superblks[blocknr] = superblk
        g.superblksBySeqNr[UInt32(nr)] = superblk
        return superblk
    }

    static func newSuperBlock(_ seqnr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        guard seqnr <= UInt16(PFS3.maxSuper), let rextCached = g.rblkextension,
              let rext = rextCached.rext else { return nil }
        let blok = try PFS3Lru.allocLRU(g)
        let blocknr = PFS3Allocation.allocReservedBlock(g)
        guard blocknr != 0 else {
            PFS3Lru.freeLRU(blok, g)
            return nil
        }
        rext.superindex[Int(seqnr)] = blocknr
        rextCached.changeflag = true

        blok.blocknr = blocknr
        blok.used = 0
        let sb = PFS3IndexBlock(id: PFS3.superBlockID, longs: (g.resBlockSize - 12) / 4)
        sb.seqnr = UInt32(seqnr)
        blok.blk = sb
        blok.changeflag = true
        g.superblks[blocknr] = blok
        g.superblksBySeqNr[UInt32(seqnr)] = blok
        return blok
    }

    /// Lazy in-memory anode-availability bitmap.
    static func makeAnodeBitmap(formatting: Bool, _ g: PFS3G) throws {
        var i = 0, j = 1, s = 0

        if !formatting {
            if g.supermode {
                guard let rext = g.rblkextension?.rext else {
                    throw AmigaDiskError.invalidGeometry(reason: "PFS3: supermode without extension")
                }
                s = PFS3.maxSuper
                while s >= 0 && rext.superindex[s] == 0 { s -= 1 }
                guard s >= 0 else { throw AmigaDiskError.invalidGeometry(reason: "AFS_ERROR_ANODE_ERROR") }
                guard let sblk = try getSuperBlock(UInt16(s), g) else {
                    throw AmigaDiskError.invalidGeometry(reason: "PFS3: superblock missing")
                }
                i = Int(g.indexperblock) - 1
                while i >= 0 && sblk.indexBlock!.index[i] == 0 { i -= 1 }
            } else {
                s = 0
                i = PFS3.maxSmallIndexNr
                while i >= 0 && g.rootBlock.smallIndexBlock(i) == 0 { i -= 1 }
            }
            guard i >= 0 else { throw AmigaDiskError.invalidGeometry(reason: "AFS_ERROR_ANODE_ERROR") }
            guard let iblk = try getIndexBlock(UInt16(s * Int(g.indexperblock) + i), g) else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3: index block missing")
            }
            j = Int(g.indexperblock) - 1
            while j >= 0 && iblk.indexBlock!.index[j] == 0 { j -= 1 }
        }

        let size: UInt32
        if g.supermode {
            g.maxanseqnr = UInt32(s * Int(g.indexperblock) * Int(g.indexperblock)
                                  + i * Int(g.indexperblock) + j)
            size = UInt32(((s * Int(g.indexperblock) + i + 1) * Int(g.indexperblock) + 7) / 8)
        } else {
            g.maxanseqnr = UInt32(i * Int(g.indexperblock) + j)
            size = UInt32(((i + 1) * Int(g.indexperblock) + 7) / 8)
        }
        g.anblkbitmapsize = (size + 3) & ~3
        g.anblkbitmap = [UInt32](repeating: 0xFFFF_FFFF, count: Int(g.anblkbitmapsize) / 4)
    }

    static func getAnode(_ anode: inout PFS3CAnode, _ anodenr: UInt32, _ g: PFS3G) throws {
        let seqnr: UInt16
        let anodeoffset: UInt16
        if g.anodesplitmode {
            seqnr = UInt16(anodenr >> 16)
            anodeoffset = UInt16(anodenr & 0xFFFF)
        } else {
            let temp = PFS3G.divide(anodenr, UInt32(g.anodesperblock))
            seqnr = UInt16(truncatingIfNeeded: temp)
            anodeoffset = UInt16(temp >> 16)
        }

        guard let ablock = try bigGetAnodeBlock(seqnr, g), let ab = ablock.anodeBlock else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3 GetAnode: anode \(anodenr) unreachable")
        }
        anode.clustersize = ab.anodes[Int(anodeoffset)].clustersize
        anode.blocknr = ab.anodes[Int(anodeoffset)].blocknr
        anode.next = ab.anodes[Int(anodeoffset)].next
        anode.nr = anodenr
    }

    static func saveAnode(_ anode: inout PFS3CAnode, _ anodenr: UInt32, _ g: PFS3G) throws {
        let seqnr: UInt16
        let anodeoffset: UInt16
        if g.anodesplitmode {
            seqnr = UInt16(anodenr >> 16)
            anodeoffset = UInt16(anodenr & 0xFFFF)
        } else {
            let temp = PFS3G.divide(anodenr, UInt32(g.anodesperblock))
            seqnr = UInt16(truncatingIfNeeded: temp)
            anodeoffset = UInt16(temp >> 16)
        }
        anode.nr = anodenr

        guard let ablock = try bigGetAnodeBlock(seqnr, g), let ab = ablock.anodeBlock else {
            throw AmigaDiskError.invalidGeometry(reason: "AFS_ERROR_DNV_ALLOC_BLOCK")
        }
        ab.anodes[Int(anodeoffset)].clustersize = anode.clustersize
        ab.anodes[Int(anodeoffset)].blocknr = anode.blocknr
        ab.anodes[Int(anodeoffset)].next = anode.next
        _ = try PFS3Update.makeBlockDirty(ablock, g)
    }

    /// Allocate an anode and mark it reserved. `connect` = anodenr to co-locate
    /// with (0 = none).
    static func allocAnode(connect: UInt32, _ g: PFS3G) throws -> UInt32 {
        var ablock: PFS3CachedBlock? = nil
        var found = false
        var seqnr: UInt32 = 0
        var k = 0

        if connect != 0 && g.anodesplitmode {
            seqnr = connect >> 16
            ablock = try bigGetAnodeBlock(UInt16(seqnr), g)
            if let ab = ablock?.anodeBlock {
                k = Int(g.anodesperblock) - 1
                while k > -1 && !found {
                    let a = ab.anodes[k]
                    found = a.clustersize == 0 && a.blocknr == 0 && a.next == 0
                    k -= 1
                }
            }
        } else {
            var i = Int(g.curranseqnr) / 32
            var jumped = false
            outer: while i < Int(g.maxanseqnr) / 32 + 1 {
                let field = i < g.anblkbitmap.count ? g.anblkbitmap[i] : 0
                if field != 0 {
                    var j = 31
                    while j >= 0 {
                        if field & (1 << UInt32(j)) != 0 {
                            seqnr = UInt32(i * 32 + 31 - j)
                            ablock = try bigGetAnodeBlock(UInt16(seqnr), g)
                            if let ab = ablock?.anodeBlock {
                                k = 0
                                while k < Int(g.reservedAnodes) && !found {
                                    let a = ab.anodes[k]
                                    found = a.clustersize == 0 && a.blocknr == 0 && a.next == 0
                                    k += 1
                                }
                                if found {
                                    jumped = true
                                    break outer
                                } else {
                                    g.anblkbitmap[i] &= ~(1 << UInt32(j))   // block full
                                }
                            } else {
                                jumped = true
                                break outer   // anodeblock does not exist
                            }
                        }
                        j -= 1
                    }
                }
                i += 1
            }
            if !jumped {
                seqnr = g.maxanseqnr + 1
            }
        }

        if !found {
            if connect != 0 {
                return try allocAnode(connect: 0, g)
            }
            // start over if not started from start of list; else make new block
            if g.curranseqnr != 0 {
                g.curranseqnr = 0
                return try allocAnode(connect: 0, g)
            }
            guard let fresh = try bigNewAnodeBlock(UInt16(seqnr), g) else { return 0 }
            ablock = fresh
            k = 0
        } else {
            // loop increments overshoot the found slot by one
            if connect != 0 { k += 1 } else { k -= 1 }
        }

        guard let ab = ablock?.anodeBlock else { return 0 }
        ab.anodes[k].clustersize = 0
        ab.anodes[k].blocknr = 0xFFFFFFFF
        ab.anodes[k].next = 0

        _ = try PFS3Update.makeBlockDirty(ablock!, g)
        g.curranseqnr = UInt16(seqnr)

        if g.anodesplitmode {
            return (seqnr << 16) | UInt32(k)
        }
        return seqnr * UInt32(g.anodesperblock) + UInt32(k)
    }

    static func bigGetAnodeBlock(_ seqnr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        let temp = PFS3G.divide(UInt32(seqnr), UInt32(g.indexperblock))
        guard let indexblock = try getIndexBlock(UInt16(truncatingIfNeeded: temp), g) else { return nil }
        let blocknr = UInt32(bitPattern: indexblock.indexBlock!.index[Int(temp >> 16)])
        guard blocknr != 0 else { return nil }

        if let cached = g.anblks[blocknr] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }

        let ablock = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.anodeBlockID else {
            PFS3Lru.freeLRU(ablock, g)
            return nil
        }
        ablock.blk = blk
        ablock.blocknr = blocknr
        ablock.used = 0
        ablock.changeflag = false
        g.anblks[blocknr] = ablock
        return ablock
    }

    static func bigNewAnodeBlock(_ seqnr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        let indexblnr = UInt32(seqnr) / UInt32(g.indexperblock)
        let indexoffset = Int(UInt32(seqnr) % UInt32(g.indexperblock))
        var indexblock: PFS3CachedBlock
        if let existing = try getIndexBlock(UInt16(indexblnr), g) {
            indexblock = existing
        } else if let fresh = try newIndexBlock(UInt16(indexblnr), g) {
            indexblock = fresh
        } else {
            return nil
        }

        let oldlock = indexblock.used
        PFS3Lru.lock(indexblock, g)
        let blok = try PFS3Lru.allocLRU(g)
        let blocknr = PFS3Allocation.allocReservedBlock(g)
        guard blocknr != 0 else {
            indexblock.used = oldlock
            return nil
        }

        indexblock.indexBlock!.index[indexoffset] = Int32(bitPattern: blocknr)
        indexblock.changeflag = true

        blok.blocknr = blocknr
        blok.used = 0
        let ab = PFS3AnodeBlock(slots: PFS3AnodeBlock.anodesPerBlock(reservedBlksize: g.resBlockSize))
        ab.seqnr = UInt32(seqnr)
        blok.blk = ab
        blok.changeflag = true
        g.anblks[blocknr] = blok
        _ = try PFS3Update.makeBlockDirty(indexblock, g)
        indexblock.used = oldlock

        reallocAnodeBitmap(UInt32(seqnr), g)
        return blok
    }

    static func newIndexBlock(_ seqnr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        var superblok: PFS3CachedBlock? = nil
        var superoffset = 0
        if g.supermode {
            let superblnr = UInt32(seqnr) / UInt32(g.indexperblock)
            superoffset = Int(UInt32(seqnr) % UInt32(g.indexperblock))
            if let existing = try getSuperBlock(UInt16(superblnr), g) {
                superblok = existing
            } else if let fresh = try newSuperBlock(UInt16(superblnr), g) {
                superblok = fresh
            } else {
                return nil
            }
            PFS3Lru.lock(superblok!, g)
        } else if seqnr > UInt16(PFS3.maxSmallIndexNr) {
            return nil
        }

        let blok = try PFS3Lru.allocLRU(g)
        let blocknr = PFS3Allocation.allocReservedBlock(g)
        guard blocknr != 0 else {
            PFS3Lru.freeLRU(blok, g)
            return nil
        }

        if g.supermode {
            superblok!.indexBlock!.index[superoffset] = Int32(bitPattern: blocknr)
            _ = try PFS3Update.makeBlockDirty(superblok!, g)
        } else {
            g.rootBlock.setSmallIndexBlock(Int(seqnr), blocknr)
            g.rootblockchangeflag = true
        }

        blok.blocknr = blocknr
        blok.used = 0
        let ib = PFS3IndexBlock(id: PFS3.indexBlockID, longs: (g.resBlockSize - 12) / 4)
        ib.seqnr = UInt32(seqnr)
        blok.blk = ib
        blok.changeflag = true
        g.indexblks[blocknr] = blok
        g.indexblksBySeqNr[UInt32(seqnr)] = blok
        return blok
    }

    static func reallocAnodeBitmap(_ newseqnr: UInt32, _ g: PFS3G) {
        if newseqnr > g.maxanseqnr {
            g.maxanseqnr = newseqnr
            var newsize = ((newseqnr / UInt32(g.indexperblock) + 1) * UInt32(g.indexperblock) + 7) / 8
            if newsize > g.anblkbitmapsize {
                newsize = (newsize + 3) & ~3
                var newbitmap = [UInt32](repeating: 0xFFFF_FFFF, count: Int(newsize) / 4)
                for (idx, value) in g.anblkbitmap.enumerated() { newbitmap[idx] = value }
                g.anblkbitmap = newbitmap
                g.anblkbitmapsize = newsize
            }
        }
    }
}

// MARK: - Update engine (Update.cs)

enum PFS3Update {

    /// Reallocate-on-first-dirty. Returns true if the block was clean.
    static func makeBlockDirty(_ blk: PFS3CachedBlock, _ g: PFS3G) throws -> Bool {
        guard !blk.changeflag else { return false }
        g.dirty = true
        let oldlock = blk.used
        PFS3Lru.lock(blk, g)

        let blocknr = PFS3Allocation.allocReservedBlock(g)
        if blocknr != 0 {
            blk.oldblocknr = blk.blocknr
            blk.blocknr = blocknr
            try updateBlocknr(blk, blocknr, g)
        } else {
            blk.changeflag = true
        }
        blk.used = oldlock
        return true
    }

    private static func updateBlocknr(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        switch blk.blk!.id {
        case PFS3.dirBlockID:         try updateDBLK(blk, newblocknr, g)
        case PFS3.anodeBlockID:       try updateABLK(blk, newblocknr, g)
        case PFS3.indexBlockID:       try updateIBLK(blk, newblocknr, g)
        case PFS3.bitmapBlockID:      try updateBMBLK(blk, newblocknr, g)
        case PFS3.bitmapIndexBlockID: try updateBMIBLK(blk, newblocknr, g)
        case PFS3.extensionBlockID:   try updateRBlkExtension(blk, newblocknr, g)
        case PFS3.deldirBlockID:      try updateDELDIR(blk, newblocknr, g)
        case PFS3.superBlockID:       try updateSBLK(blk, newblocknr, g)
        default: break
        }
    }

    private static func rekey(_ dict: inout [UInt32: PFS3CachedBlock], _ blk: PFS3CachedBlock, _ newblocknr: UInt32) {
        if dict[blk.oldblocknr] != nil {
            dict.removeValue(forKey: blk.oldblocknr)
            dict[newblocknr] = blk
        }
    }

    private static func updateDBLK(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.dirblks, blk, newblocknr)
        let oldblocknr = blk.oldblocknr
        PFS3Lru.lock(blk, g)

        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, blk.dirBlock!.anodenr, g)
        while anode.blocknr != oldblocknr && anode.next != 0 {
            try PFS3Anodes.getAnode(&anode, anode.next, g)
        }
        guard anode.blocknr == oldblocknr else {
            throw AmigaDiskError.invalidGeometry(reason: "AFS_ERROR_CACHE_INCONSISTENCY")
        }
        blk.changeflag = true
        anode.blocknr = newblocknr
        try PFS3Anodes.saveAnode(&anode, anode.nr, g)
    }

    private static func updateABLK(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.anblks, blk, newblocknr)
        blk.changeflag = true
        let temp = blk.anodeBlock!.seqnr
        let indexblknr = temp / UInt32(g.indexperblock)
        let indexoffset = Int(temp % UInt32(g.indexperblock))
        guard let index = try PFS3Anodes.getIndexBlock(UInt16(indexblknr), g) else {
            throw AmigaDiskError.invalidGeometry(reason: "UpdateABLK: index block missing")
        }
        index.indexBlock!.index[indexoffset] = Int32(bitPattern: newblocknr)
        _ = try makeBlockDirty(index, g)
    }

    private static func updateIBLK(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.indexblks, blk, newblocknr)
        blk.changeflag = true
        if g.supermode {
            let temp = PFS3G.divide(blk.indexBlock!.seqnr, UInt32(g.indexperblock))
            guard let superblk = try PFS3Anodes.getSuperBlock(UInt16(truncatingIfNeeded: temp), g) else {
                throw AmigaDiskError.invalidGeometry(reason: "UpdateIBLK: superblock missing")
            }
            superblk.indexBlock!.index[Int(temp >> 16)] = Int32(bitPattern: newblocknr)
            _ = try makeBlockDirty(superblk, g)
        } else {
            g.rootBlock.setSmallIndexBlock(Int(blk.indexBlock!.seqnr), newblocknr)
            g.rootblockchangeflag = true
        }
    }

    private static func updateSBLK(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.superblks, blk, newblocknr)
        blk.changeflag = true
        guard let rextCached = g.rblkextension, let rext = rextCached.rext else {
            throw AmigaDiskError.invalidGeometry(reason: "UpdateSBLK: extension missing")
        }
        rextCached.changeflag = true
        rext.superindex[Int(blk.indexBlock!.seqnr)] = newblocknr
    }

    private static func updateBMBLK(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.bmblks, blk, newblocknr)
        blk.changeflag = true
        let temp = PFS3G.divide(blk.bitmapBlock!.seqnr, UInt32(g.indexperblock))
        guard let indexblock = try PFS3Allocation.getBitmapIndex(UInt16(truncatingIfNeeded: temp), g) else {
            throw AmigaDiskError.invalidGeometry(reason: "UpdateBMBLK: bitmap index missing")
        }
        indexblock.indexBlock!.index[Int(temp >> 16)] = Int32(bitPattern: newblocknr)
        _ = try makeBlockDirty(indexblock, g)   // recursion!
    }

    private static func updateBMIBLK(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.bmindexblks, blk, newblocknr)
        blk.changeflag = true
        g.rootBlock.setLargeBitmapIndex(Int(blk.indexBlock!.seqnr), newblocknr)
        g.rootblockchangeflag = true
    }

    private static func updateRBlkExtension(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        blk.changeflag = true
        g.rootBlock.extension_ = newblocknr
        g.rootblockchangeflag = true
        _ = try makeBlockDirty(blk, g)
    }

    private static func updateDELDIR(_ blk: PFS3CachedBlock, _ newblocknr: UInt32, _ g: PFS3G) throws {
        rekey(&g.deldirblks, blk, newblocknr)
        blk.changeflag = true
        guard let rextCached = g.rblkextension, let rext = rextCached.rext else {
            throw AmigaDiskError.invalidGeometry(reason: "UpdateDELDIR: extension missing")
        }
        rext.deldir[Int(blk.deldirBlock!.seqnr)] = newblocknr
        _ = try makeBlockDirty(rextCached, g)
    }

    /// Copy current rootblock datestamp into a block before an LRU write.
    static func updateDatestamp(_ blk: PFS3CachedBlock, _ g: PFS3G) {
        blk.blk?.datestamp = g.rootBlock.datestamp
    }

    static func updateDisk(_ g: PFS3G) throws {
        guard g.dirty else { return }
        g.uip = true
        g.updateok = true

        // make sure rootblockextension is reallocated
        if let rext = g.rblkextension {
            _ = try makeBlockDirty(rext, g)
        }

        // commit user-space free list
        try PFS3Allocation.updateFreeList(g)

        // remove empty dir/anode/index/super blocks
        try removeEmptyDBlocks(g)
        try removeEmptyABlocks(g)
        try removeEmptyIBlocks(g)
        try removeEmptySBlocks(g)

        try updateList(Array(g.dirblks.values), g)
        try updateList(Array(g.anblks.values), g)
        try updateList(Array(g.indexblks.values), g)
        try updateList(Array(g.superblks.values), g)
        try updateList(Array(g.deldirblks.values), g)

        if let rextCached = g.rblkextension, let rext = rextCached.rext {
            rext.reservedRoving = g.res_roving
            rext.rovingbit = UInt16(g.rovingbit)
            rext.curranseqnr = g.curranseqnr
            let now = AmigaDate(date: g.now)
            rext.volumeDate = (UInt16(now.days), UInt16(now.minutes), UInt16(now.ticks))
            rext.datestamp = g.rootBlock.datestamp
            try updateDirtyBlock(rextCached, g)
        }

        // commit reserved to-be-freed list
        for blocknr in g.reservedtobefreed where blocknr != 0 {
            PFS3Allocation.freeReservedBlock(blocknr, g)
        }
        g.reservedtobefreed.removeAll()

        // bitmap and bitmap index blocks
        try updateList(Array(g.bmblks.values), g)
        try updateList(Array(g.bmindexblks.values), g)

        // root (MUST be last) + reserved bitmap behind it
        guard g.updateok else {
            throw AmigaDiskError.invalidGeometry(reason: "AFS_ERROR_UPDATE_FAIL")
        }
        try PFS3Disk.rawWrite(g.rootBlock.serialize(), blocks: 1, blocknr: PFS3.rootBlockNr, g)
        if let reservedBitmap = g.rootBlock.reservedBitmap {
            let bytes = 12 + reservedBitmap.bitmap.count * 4
            let blocks = UInt32((bytes + Int(g.blocksize) - 1) / Int(g.blocksize))
            let data = reservedBitmap.serialize(size: Int(blocks) * Int(g.blocksize))
            try PFS3Disk.rawWrite(data, blocks: blocks, blocknr: PFS3.rootBlockNr + 1, g)
        }
        g.rootBlock.datestamp += 1
        g.rootblockchangeflag = false
        g.uip = false
        g.dirty = false
    }

    private static func updateList(_ list: [PFS3CachedBlock], _ g: PFS3G) throws {
        guard g.updateok else { return }
        for blk in list where blk.changeflag {
            PFS3Allocation.freeReservedBlock(blk.oldblocknr, g)
            blk.blk!.datestamp = g.rootBlock.datestamp
            blk.oldblocknr = 0
            try PFS3Disk.rawWrite(block: blk.blk!, blocks: g.rescluster, blocknr: blk.blocknr, g)
            blk.changeflag = false
        }
    }

    static func updateDirtyBlock(_ blk: PFS3CachedBlock, _ g: PFS3G) throws {
        guard g.updateok else { return }
        if blk.changeflag {
            PFS3Allocation.freeReservedBlock(blk.oldblocknr, g)
            blk.oldblocknr = 0
            try PFS3Disk.rawWrite(block: blk.blk!, blocks: g.rescluster, blocknr: blk.blocknr, g)
        }
        blk.changeflag = false
    }

    private static func isEmptyDBlk(_ blk: PFS3CachedBlock) -> Bool {
        blk.dirBlock.map { $0.entries.first == 0 } ?? false
    }

    private static func isFirstDBlk(_ blk: PFS3CachedBlock, _ g: PFS3G) throws -> Bool {
        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, blk.dirBlock!.anodenr, g)
        return anode.blocknr == blk.blocknr
    }

    private static func getAnodeOfDBlk(_ blk: PFS3CachedBlock, _ anode: inout PFS3CAnode, _ g: PFS3G) throws -> UInt32 {
        var prev: UInt32 = 0
        try PFS3Anodes.getAnode(&anode, blk.dirBlock!.anodenr, g)
        while anode.blocknr != blk.blocknr && anode.next != 0 {
            prev = anode.nr
            try PFS3Anodes.getAnode(&anode, anode.next, g)
        }
        return prev
    }

    private static func removeEmptyDBlocks(_ g: PFS3G) throws {
        for blk in Array(g.dirblks.values) {
            guard blk.dirBlock != nil, isEmptyDBlk(blk),
                  try !isFirstDBlk(blk, g), !PFS3Lru.isLocked(blk, g) else { continue }
            var anode = PFS3CAnode()
            let previous = try getAnodeOfDBlk(blk, &anode, g)
            try PFS3Anodes.removeFromAnodeChain(anode, previous: previous,
                                                head: blk.dirBlock!.anodenr, g)
            PFS3Lru.minRemove(blk, g)
            PFS3Allocation.freeReservedBlock(blk.blocknr, g)
            PFS3Lru.resToBeFreed(blk.oldblocknr, g)
            PFS3Lru.freeLRU(blk, g)
        }
    }

    private static func removeEmptyABlocks(_ g: PFS3G) throws {
        for blk in Array(g.anblks.values) {
            guard blk.changeflag, let ab = blk.anodeBlock, ab.seqnr != 0,
                  ab.anodes.prefix(Int(g.anodesperblock)).allSatisfy({ $0.blocknr == 0 }),
                  !PFS3Lru.isLocked(blk, g) else { continue }
            let indexblknr = ab.seqnr / UInt32(g.indexperblock)
            let indexoffset = Int(ab.seqnr % UInt32(g.indexperblock))
            PFS3Lru.minRemove(blk, g)
            PFS3Allocation.freeReservedBlock(blk.blocknr, g)
            PFS3Lru.resToBeFreed(blk.oldblocknr, g)
            PFS3Lru.freeLRU(blk, g)
            guard let index = try PFS3Anodes.getIndexBlock(UInt16(indexblknr), g) else {
                throw AmigaDiskError.invalidGeometry(reason: "RemoveEmptyABlocks: index missing")
            }
            index.indexBlock!.index[indexoffset] = 0
        }
    }

    private static func isEmptyIBlk(_ blk: PFS3CachedBlock, _ g: PFS3G) -> Bool {
        blk.indexBlock!.index.prefix(Int(g.indexperblock)).allSatisfy { $0 == 0 }
    }

    private static func removeEmptyIBlocks(_ g: PFS3G) throws {
        for blk in Array(g.indexblks.values) {
            guard blk.changeflag, blk.indexBlock?.seqnr != 0, isEmptyIBlk(blk, g),
                  !PFS3Lru.isLocked(blk, g) else { continue }
            try updateIBLK(blk, 0, g)
            PFS3Lru.minRemove(blk, g)
            PFS3Allocation.freeReservedBlock(blk.blocknr, g)
            PFS3Lru.resToBeFreed(blk.oldblocknr, g)
            PFS3Lru.freeLRU(blk, g)
        }
    }

    private static func removeEmptySBlocks(_ g: PFS3G) throws {
        for blk in Array(g.superblks.values) {
            guard blk.changeflag, blk.indexBlock?.seqnr != 0, isEmptyIBlk(blk, g),
                  !PFS3Lru.isLocked(blk, g) else { continue }
            try updateSBLK(blk, 0, g)
            PFS3Lru.minRemove(blk, g)
            PFS3Allocation.freeReservedBlock(blk.blocknr, g)
            PFS3Lru.resToBeFreed(blk.oldblocknr, g)
            PFS3Lru.freeLRU(blk, g)
        }
    }
}

// MARK: - Anode chain removal (anodes.cs, needed by RemoveEmptyDBlocks)

extension PFS3Anodes {
    static func removeFromAnodeChain(_ anode: PFS3CAnode, previous: UInt32, head: UInt32, _ g: PFS3G) throws {
        var sparenode = PFS3CAnode()
        if previous != 0 {
            try getAnode(&sparenode, previous, g)
            sparenode.next = anode.next
            try saveAnode(&sparenode, sparenode.nr, g)
            try freeAnode(anode.nr, g)
        } else if anode.next != 0 {
            try getAnode(&sparenode, anode.next, g)
            try saveAnode(&sparenode, head, g)
            try freeAnode(anode.next, g)
        } else {
            try freeAnode(head, g)
        }
    }

    static func freeAnode(_ anodenr: UInt32, _ g: PFS3G) throws {
        var anode = PFS3CAnode()
        if anodenr < PFS3.anodeUserFirst {
            anode.blocknr = .max   // don't kill reserved anodes
        }
        try saveAnode(&anode, anodenr, g)
        let idx = Int((anodenr >> 16) / 32)
        if idx < g.anblkbitmap.count {
            g.anblkbitmap[idx] |= 1 << (31 - ((anodenr >> 16) % 32))
        }
    }
}

// MARK: - Directory format subset (Directory.cs)

enum PFS3Directory {

    static func makeDirBlock(blocknr: UInt32, anodenr: UInt32, rootanodenr: UInt32,
                             parentnr: UInt32, _ g: PFS3G) throws -> PFS3CachedBlock {
        var anode = PFS3CAnode(clustersize: 1, blocknr: blocknr, next: 0, nr: anodenr)
        try PFS3Anodes.saveAnode(&anode, anodenr, g)

        let blk = try PFS3Lru.allocLRU(g)
        let dirblock = PFS3DirBlock(entrySpace: PFS3DirBlock.entrySpace(reservedBlksize: g.resBlockSize))
        dirblock.anodenr = rootanodenr
        dirblock.parent = parentnr
        blk.blk = dirblock
        blk.blocknr = blocknr
        blk.oldblocknr = 0
        blk.changeflag = true
        g.dirblks[blocknr] = blk
        PFS3Lru.lock(blk, g)
        return blk
    }

    static func newDeldirBlock(seqnr: UInt16, _ g: PFS3G) throws -> PFS3CachedBlock? {
        guard seqnr <= UInt16(PFS3.maxDeldir),
              let rextCached = g.rblkextension, let rext = rextCached.rext else { return nil }
        let ddblk = try PFS3Lru.allocLRU(g)
        let blocknr = PFS3Allocation.allocReservedBlock(g)
        guard blocknr != 0 else {
            PFS3Lru.freeLRU(ddblk, g)
            return nil
        }
        rext.deldir[Int(seqnr)] = blocknr

        ddblk.blocknr = blocknr
        ddblk.used = 0
        let dd = PFS3DelDirBlock()
        dd.seqnr = UInt32(seqnr)
        dd.protection = UInt32(PFS3.delEntryProt)
        dd.creationDay = g.rootBlock.creationDay
        dd.creationMinute = g.rootBlock.creationMinute
        dd.creationTick = g.rootBlock.creationTick
        ddblk.blk = dd
        ddblk.changeflag = true
        g.deldirblks[blocknr] = ddblk
        g.deldirblksBySeqNr[UInt32(seqnr)] = ddblk
        return ddblk
    }

    static func setDeldir(_ nbr: Int, _ g: PFS3G) throws {
        guard let rextCached = g.rblkextension, let rext = rextCached.rext,
              nbr >= 0, nbr <= PFS3.maxDeldir + 1 else {
            throw AmigaDiskError.invalidGeometry(reason: "SetDeldir: bad number")
        }

        try PFS3Update.updateDisk(g)

        // flush deldir cache
        for ddblk in Array(g.deldirblks.values) {
            PFS3Lru.flushBlock(ddblk, g)
            PFS3Lru.minRemoveLru(ddblk, g)
            g.lruPool.insert(ddblk, at: 0)
        }

        // free unwanted, allocate wanted (either range may be empty)
        if nbr < Int(rext.deldirSize) {
            for i in nbr ..< Int(rext.deldirSize) {
                PFS3Allocation.freeReservedBlock(rext.deldir[i], g)
                rext.deldir[i] = 0
            }
        }
        if Int(rext.deldirSize) < nbr {
            for i in Int(rext.deldirSize) ..< nbr {
                guard try newDeldirBlock(seqnr: UInt16(i), g) != nil else {
                    throw AmigaDiskError.invalidGeometry(reason: "SetDeldir: disk full")
                }
            }
        }

        rext.deldirRoving = nbr > Int(rext.deldirSize)
            ? UInt16(Int(rext.deldirSize) * PFS3.deldirEntriesPerBlock) : 0
        rext.deldirSize = UInt16(nbr)
        g.deldirenabled = nbr > 0

        _ = try PFS3Update.makeBlockDirty(rextCached, g)
        try PFS3Update.updateDisk(g)
    }
}
