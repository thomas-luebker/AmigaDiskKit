import Foundation

/// PFS3 format specification.
public struct PFS3FormatSpec {
    public let volumeName: String
    public let now: Date

    public init(volumeName: String, now: Date = Date()) {
        self.volumeName = volumeName
        self.now = now
    }
}

/// Formats a PDS3 partition with PFS3, ported from hst-amiga's
/// `Pfs3Formatter.FormatPartition` (format.c `FDSFormat`). The full
/// allocation/update machinery runs so the resulting reserved area is
/// byte-compatible with hst-imager's output.
public enum PFS3Formatter {

    /// "schijf" table from the original PFS3 format.c: thresholds (in reserved
    /// blocksize units) and divisors for reserved-area sizing.
    private static let schijf: [(UInt32, UInt32)] = [
        (20480, 20), (51200, 30), (512000, 40),
        (1048567, 50), (10_000_000, 70), (0xFFFFFFFF, 80),
    ]

    public static func format(
        device: BlockDevice,
        sliceStartLBA: Int64,
        partition: PartitionBlock,
        rdb: RigidDiskBlock,
        spec: PFS3FormatSpec
    ) throws {
        try format(device: device, sliceStartLBA: sliceStartLBA,
                   blocksPerTrack: partition.blocksPerTrack, surfaces: partition.surfaces,
                   lowCyl: partition.lowCyl, highCyl: partition.highCyl,
                   numBuffers: partition.numBuffer, spec: spec)
    }

    public static func format(
        device: BlockDevice,
        sliceStartLBA: Int64,
        blocksPerTrack: UInt32,
        surfaces: UInt32,
        lowCyl: UInt32,
        highCyl: UInt32,
        numBuffers: UInt32,
        spec: PFS3FormatSpec
    ) throws {
        let g = PFS3G(device: device, sliceStartLBA: sliceStartLBA,
                      blocksPerTrack: blocksPerTrack,
                      surfaces: surfaces,
                      lowCyl: lowCyl, highCyl: highCyl,
                      numBuffers: numBuffers)
        g.now = spec.now

        // Only standard PFS\1 with 1024-byte reserved blocks is supported.
        // Larger volumes need the experimental PFS\2 large-disk variant.
        guard Int64(g.totalSectors) <= PFS3.maxDiskSize1K else {
            throw AmigaDiskError.invalidGeometry(
                reason: "PFS3 partition exceeds 104 GB standard limit (\(g.totalSectors) sectors)")
        }

        try makeBootBlock(g)
        let rootBlock = makeRootBlock(diskName: spec.volumeName, g)
        g.rootBlock = rootBlock

        // volumedata (Volume.MakeVolumeData) — single-volume state lives on g
        g.numblocks = g.totalSectors
        g.rescluster = UInt32(rootBlock.reservedBlksize) / g.blocksize

        // rootblock extension (made BEFORE InitModules; bug 00135)
        g.rblkextension = makeFormatRBlkExtension(rootBlock, g)
        rootBlock.options.insert(.extensionBlock)

        try initModules(formatting: true, g)

        // main bitmap
        for seqnr in 0 ..< g.no_bmb {
            guard try PFS3Allocation.newBitmapBlock(seqnr: seqnr, g) != nil else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3 format: bitmap block allocation failed")
            }
        }

        // reserve anodes 0..ANODE_ROOTDIR-1
        var i: UInt32 = 0
        var prev: UInt32? = nil
        repeat {
            i = try PFS3Anodes.allocAnode(connect: 0, g)
            if let p = prev, p == i {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3 format: anode allocation stalled")
            }
            prev = i
        } while i < PFS3.anodeRootDir - 1

        // root directory
        let rootDirBlockNr = PFS3Allocation.allocReservedBlock(g)
        let rootAnodeNr = try PFS3Anodes.allocAnode(connect: 0, g)
        _ = try PFS3Directory.makeDirBlock(blocknr: rootDirBlockNr, anodenr: rootAnodeNr,
                                           rootanodenr: rootAnodeNr, parentnr: 0, g)

        // deldir
        try PFS3Directory.setDeldir(2, g)
        rootBlock.options.insert(.deldir)
        rootBlock.options.insert(.superDeldir)
        g.dirty = true

        try PFS3Update.updateDisk(g)
    }

    // MARK: - format.c building blocks

    private static func makeBootBlock(_ g: PFS3G) throws {
        var boot = Data(count: 2 * Int(g.blocksize))
        boot.writeBE32(PFS3.idPFSDisk, at: 0)
        try PFS3Disk.rawWrite(boot, blocks: 2, blocknr: PFS3.bootBlock1, g)
    }

    private static func makeRootBlock(diskName: String, _ g: PFS3G) -> PFS3RootBlock {
        let rootBlock = PFS3RootBlock()
        rootBlock.diskType = PFS3.idPFSDisk
        rootBlock.datestamp = 1
        let creation = AmigaDate(date: g.now)
        rootBlock.creationDay = UInt16(creation.days)
        rootBlock.creationMinute = UInt16(creation.minutes)
        rootBlock.creationTick = UInt16(creation.ticks)
        rootBlock.protection = 0xF0
        rootBlock.firstReserved = 2
        rootBlock.diskName = String(diskName.prefix(31))
        rootBlock.diskSize = g.totalSectors
        rootBlock.options = [.hardDisk, .splittedAnodes, .dirExtension,
                             .sizeField, .datestamp, .extRoving, .longFN]

        let resblocksize: UInt32 = 1024
        if Int64(g.totalSectors) > PFS3.maxSmallDisk {
            rootBlock.options.insert(.superIndex)
            g.supermode = true
        }
        g.rescluster = resblocksize / g.blocksize
        rootBlock.reservedBlksize = UInt16(resblocksize)

        let numReserved = calcNumReserved(g, resblocksize)
        rootBlock.lastReserved = g.rescluster * numReserved + rootBlock.firstReserved - 1
        rootBlock.reservedFree = numReserved
        rootBlock.blocksFree = g.totalSectors - g.rescluster * numReserved - rootBlock.firstReserved
        rootBlock.alwaysFree = rootBlock.blocksFree / 20

        makeReservedBitmap(rootBlock, numReserved: numReserved, g)
        return rootBlock
    }

    static func calcNumReserved(_ g: PFS3G, _ resblocksize: UInt32) -> UInt32 {
        var temp = g.totalSectors * (g.blocksize / 512)
        temp /= (resblocksize / 512)
        var taken: UInt32 = 0
        var i = 0
        while temp > schijf[i].0 {
            taken += schijf[i].0 / schijf[i].1
            temp -= schijf[i].0
            i += 1
        }
        taken += temp / schijf[i].1
        taken += 10
        taken = min(UInt32(PFS3.maxNumReserved), taken)
        taken = (taken + 31) & ~0x1F
        return taken
    }

    private static func makeReservedBitmap(_ rootBlock: PFS3RootBlock, numReserved: UInt32, _ g: PFS3G) {
        // number of 1024-byte blocks needed for rootblock + reserved bitmap
        var numblocks = 1
        var i = 125
        while i < Int(numReserved / 32) {
            numblocks += 1
            i += 256
        }
        numblocks = (1024 * numblocks + Int(rootBlock.reservedBlksize) - 1) / Int(rootBlock.reservedBlksize)
        rootBlock.reservedFree -= UInt32(numblocks)

        let rescluster = Int(rootBlock.reservedBlksize) / Int(g.blocksize)
        rootBlock.rblkCluster = UInt16(rescluster * numblocks)

        let longs = Int(numReserved / 32 + 1)
        let bmb = PFS3BitmapBlock(longs: longs)
        for idx in 0 ..< longs { bmb.bitmap[idx] = .max }
        var last: UInt32 = 0
        for bit in 0 ..< Int(numReserved % 32) {
            last |= 0x8000_0000 >> bit
        }
        bmb.bitmap[longs - 1] = last

        // allocate rootblock cluster + rootblock extension (numblocks + 1 bits)
        for bit in 0 ... numblocks {
            bmb.bitmap[bit / 32] ^= 0x8000_0000 >> (bit % 32)
        }

        rootBlock.extension_ = rootBlock.firstReserved + UInt32(rootBlock.rblkCluster)
        rootBlock.reservedFree -= 1
        rootBlock.reservedBitmap = bmb
    }

    private static func makeFormatRBlkExtension(_ rootBlock: PFS3RootBlock, _ g: PFS3G) -> PFS3CachedBlock {
        let rext = PFS3CachedBlock()
        rext.blocknr = rootBlock.extension_
        rext.changeflag = true
        let blk = PFS3RootBlockExtension()
        blk.pfs2version = (PFS3.verNum << 16) + PFS3.revNum
        blk.rootDate = (rootBlock.creationDay, rootBlock.creationMinute, rootBlock.creationTick)
        // hst-amiga's rootblockextension constructor stamps dd_creationdate with
        // DateTime.Now (LOCAL time), while the rootblock creation date uses
        // UtcNow — replicate both for byte parity. The field is rewritten as
        // soon as the deldir is actually used.
        let localOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: g.now))
        let ddDate = AmigaDate(date: g.now.addingTimeInterval(localOffset))
        blk.ddCreationDay = UInt16(ddDate.days)
        blk.ddCreationMinute = UInt16(ddDate.minutes)
        blk.ddCreationTick = UInt16(ddDate.ticks)
        blk.fnsize = PFS3.formattedFNSize
        g.fnsize = PFS3.formattedFNSize
        rext.blk = blk
        g.dirty = true
        return rext
    }

    // MARK: - Init.cs

    static func initModules(formatting: Bool, _ g: PFS3G) throws {
        let rootBlock = g.rootBlock!
        let rext = g.rblkextension?.rext

        g.harddiskmode = rootBlock.options.contains(.hardDisk)
        g.anodesplitmode = rootBlock.options.contains(.splittedAnodes)
        g.dirextension = rootBlock.options.contains(.dirExtension)
        g.deldirenabled = rootBlock.options.contains(.deldir) && g.dirextension
            && (rext?.deldirSize ?? 0) > 0
        g.supermode = rootBlock.options.contains(.superIndex)
        g.fnsize = rext?.fnsize ?? 32
        if g.fnsize == 0 { g.fnsize = 32 }

        // InitAnodes
        guard g.harddiskmode else {
            throw AmigaDiskError.invalidGeometry(reason: "AFS_ERROR_ANODE_INIT")
        }
        g.curranseqnr = rext?.curranseqnr ?? 0
        g.anodesperblock = UInt16((Int(rootBlock.reservedBlksize) - 16) / 12)
        g.indexperblock = UInt16((Int(rootBlock.reservedBlksize) - 12) / 4)
        g.maxanodeseqnr = g.supermode
            ? UInt32(PFS3.maxSuper + 1) * UInt32(g.indexperblock) * UInt32(g.indexperblock)
                * UInt32(g.anodesperblock) - 1
            : UInt32(PFS3.maxSmallIndexNr) * UInt32(g.indexperblock) - 1
        g.reservedAnodes = g.anodesperblock - UInt16(PFS3.reservedAnodes)
        try PFS3Anodes.makeAnodeBitmap(formatting: formatting, g)

        // InitAllocation
        g.clean_blocksfree = rootBlock.blocksFree
        g.alloc_available = rootBlock.blocksFree - rootBlock.alwaysFree
        g.longsperbmb = UInt32(rootBlock.longsPerBmb)
        var t = (g.numblocks - (rootBlock.lastReserved + 1) + 31) / 32
        t = (t + g.longsperbmb - 1) / g.longsperbmb
        g.no_bmb = t
        g.bitmapstart = rootBlock.lastReserved + 1
        g.tobefreed.removeAll()
        g.tbf_resneed = 0
        if let rext {
            g.res_roving = rext.reservedRoving
            g.rovingbit = UInt32(rext.rovingbit)
        } else {
            g.res_roving = 0
            g.rovingbit = 0
        }
        g.numreserved = (rootBlock.lastReserved - rootBlock.firstReserved + 1) / g.rescluster
        g.reservedtobefreed.removeAll()
    }
}
