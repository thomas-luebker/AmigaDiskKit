import Foundation

/// PFS3 reserved-block codecs, ported field-for-field from pfs3aio `blocks.h`
/// and hst-amiga's Blocks/ readers and writers.
///
/// PFS3 reserved blocks carry NO checksums — consistency is maintained by the
/// datestamp discipline: every block's datestamp must be ≤ the rootblock's,
/// and the rootblock write is the commit point of any update.
///
/// All block classes use reference semantics, mirroring the original's cached
/// in-memory blocks that mutate until flushed.

// MARK: - Rootblock (sector 2; first 512 bytes of the rootblock cluster)

final class PFS3RootBlock {
    var diskType: UInt32 = PFS3.idPFSDisk
    var options: PFS3.Options = []
    var datestamp: UInt32 = 0
    var creationDay: UInt16 = 0
    var creationMinute: UInt16 = 0
    var creationTick: UInt16 = 0
    var protection: UInt16 = 0
    var diskName: String = ""
    var lastReserved: UInt32 = 0
    var firstReserved: UInt32 = 0
    var reservedFree: UInt32 = 0
    var reservedBlksize: UInt16 = 0
    var rblkCluster: UInt16 = 0
    var blocksFree: UInt32 = 0
    var alwaysFree: UInt32 = 0
    var rovingPtr: UInt32 = 0
    var deldir: UInt32 = 0           // deprecated (<= 17.8), always 0
    var diskSize: UInt32 = 0
    var extension_: UInt32 = 0
    /// Union area at 0x60: small mode = bitmapindex[5] + indexblocks[99];
    /// supermode (MODE_SUPERINDEX) = bitmapindex[104]. 104 ULONGs either way.
    var idx = [UInt32](repeating: 0, count: 104)

    /// The reserved bitmap lives directly behind the rootblock within the
    /// rootblock cluster (`rblkCluster` sectors total).
    var reservedBitmap: PFS3BitmapBlock?

    var longsPerBmb: Int { Int(reservedBlksize) / 4 - 3 }

    // Small-mode union accessors (bitmapindex[0..4], indexblocks[0..98]).
    func smallBitmapIndex(_ i: Int) -> UInt32 { idx[i] }
    func setSmallBitmapIndex(_ i: Int, _ v: UInt32) { idx[i] = v }
    func smallIndexBlock(_ i: Int) -> UInt32 { idx[PFS3.maxSmallBitmapIndex + 1 + i] }
    func setSmallIndexBlock(_ i: Int, _ v: UInt32) { idx[PFS3.maxSmallBitmapIndex + 1 + i] = v }
    // Supermode union accessor (bitmapindex[0..103]).
    func largeBitmapIndex(_ i: Int) -> UInt32 { idx[i] }
    func setLargeBitmapIndex(_ i: Int, _ v: UInt32) { idx[i] = v }

    init() {}

    init(data: Data) throws {
        let diskType = data.readBE32(at: 0)
        guard diskType == PFS3.idPFSDisk || diskType == PFS3.idPFS2Disk else {
            throw AmigaDiskError.unsupportedDosType(diskType)
        }
        self.diskType = diskType
        options         = PFS3.Options(rawValue: data.readBE32(at: 0x04))
        datestamp       = data.readBE32(at: 0x08)
        creationDay     = data.readBE16(at: 0x0C)
        creationMinute  = data.readBE16(at: 0x0E)
        creationTick    = data.readBE16(at: 0x10)
        protection      = data.readBE16(at: 0x12)
        diskName        = data.readBSTR(at: 0x14, maxLength: 32)
        lastReserved    = data.readBE32(at: 0x34)
        firstReserved   = data.readBE32(at: 0x38)
        reservedFree    = data.readBE32(at: 0x3C)
        reservedBlksize = data.readBE16(at: 0x40)
        rblkCluster     = data.readBE16(at: 0x42)
        blocksFree      = data.readBE32(at: 0x44)
        alwaysFree      = data.readBE32(at: 0x48)
        rovingPtr       = data.readBE32(at: 0x4C)
        deldir          = data.readBE32(at: 0x50)
        diskSize        = data.readBE32(at: 0x54)
        extension_      = data.readBE32(at: 0x58)
        for i in 0 ..< 104 {
            idx[i] = data.readBE32(at: 0x60 + i * 4)
        }
    }

    /// Serialize the 512-byte rootblock (without the reserved bitmap behind it).
    func serialize() -> Data {
        var block = Data(count: 512)
        block.writeBE32(diskType, at: 0x00)
        block.writeBE32(options.rawValue, at: 0x04)
        block.writeBE32(datestamp, at: 0x08)
        block.writeBE16(creationDay, at: 0x0C)
        block.writeBE16(creationMinute, at: 0x0E)
        block.writeBE16(creationTick, at: 0x10)
        block.writeBE16(protection, at: 0x12)
        block.writeBSTR(diskName, at: 0x14, maxLength: 32)
        block.writeBE32(lastReserved, at: 0x34)
        block.writeBE32(firstReserved, at: 0x38)
        block.writeBE32(reservedFree, at: 0x3C)
        block.writeBE16(reservedBlksize, at: 0x40)
        block.writeBE16(rblkCluster, at: 0x42)
        block.writeBE32(blocksFree, at: 0x44)
        block.writeBE32(alwaysFree, at: 0x48)
        block.writeBE32(rovingPtr, at: 0x4C)
        block.writeBE32(deldir, at: 0x50)
        block.writeBE32(diskSize, at: 0x54)
        block.writeBE32(extension_, at: 0x58)
        for i in 0 ..< 104 {
            block.writeBE32(idx[i], at: 0x60 + i * 4)
        }
        return block
    }
}

// MARK: - Reserved cached blocks

/// Common shape of all reserved blocks that live in the cache and get
/// reallocated on flush.
protocol PFS3Block: AnyObject {
    var id: UInt16 { get }
    var datestamp: UInt32 { get set }
    /// Serialize into a `size`-byte buffer (the reserved blocksize).
    func serialize(size: Int) -> Data
}

/// Bitmap block ('BM') — also used for the reserved bitmap behind the rootblock.
final class PFS3BitmapBlock: PFS3Block {
    let id = PFS3.bitmapBlockID
    var datestamp: UInt32 = 0
    var seqnr: UInt32 = 0
    var bitmap: [UInt32]

    init(longs: Int) {
        bitmap = [UInt32](repeating: 0, count: longs)
    }

    init(data: Data, longs: Int) {
        datestamp = data.readBE32(at: 4)
        seqnr     = data.readBE32(at: 8)
        bitmap = (0 ..< longs).map { data.readBE32(at: 12 + $0 * 4) }
    }

    func serialize(size: Int) -> Data {
        var block = Data(count: size)
        block.writeBE16(id, at: 0)
        block.writeBE32(datestamp, at: 4)
        block.writeBE32(seqnr, at: 8)
        for (i, long) in bitmap.enumerated() where 12 + i * 4 + 4 <= size {
            block.writeBE32(long, at: 12 + i * 4)
        }
        return block
    }
}

/// Index block — anode index ('IB'), bitmap index ('MI'), or super ('SB');
/// identical layout, different id.
final class PFS3IndexBlock: PFS3Block {
    let id: UInt16
    var datestamp: UInt32 = 0
    var seqnr: UInt32 = 0
    var index: [Int32]

    init(id: UInt16, longs: Int) {
        self.id = id
        index = [Int32](repeating: 0, count: longs)
    }

    init(id: UInt16, data: Data, longs: Int) {
        self.id = id
        datestamp = data.readBE32(at: 4)
        seqnr     = data.readBE32(at: 8)
        index = (0 ..< longs).map { Int32(bitPattern: data.readBE32(at: 12 + $0 * 4)) }
    }

    func serialize(size: Int) -> Data {
        var block = Data(count: size)
        block.writeBE16(id, at: 0)
        block.writeBE32(datestamp, at: 4)
        block.writeBE32(seqnr, at: 8)
        for (i, value) in index.enumerated() where 12 + i * 4 + 4 <= size {
            block.writeBE32(UInt32(bitPattern: value), at: 12 + i * 4)
        }
        return block
    }
}

/// One allocation node: a file/directory extent.
struct PFS3Anode {
    var clustersize: UInt32 = 0
    var blocknr: UInt32 = 0
    var next: UInt32 = 0
}

/// Anode block ('AB').
final class PFS3AnodeBlock: PFS3Block {
    let id = PFS3.anodeBlockID
    var datestamp: UInt32 = 0
    var seqnr: UInt32 = 0
    var anodes: [PFS3Anode]

    /// Anodes per block for a given reserved blocksize: (size − 16) / 12.
    static func anodesPerBlock(reservedBlksize: Int) -> Int {
        (reservedBlksize - 16) / 12
    }

    init(slots: Int) {
        anodes = [PFS3Anode](repeating: PFS3Anode(), count: slots)
    }

    init(data: Data, slots: Int) {
        datestamp = data.readBE32(at: 4)
        seqnr     = data.readBE32(at: 8)
        anodes = (0 ..< slots).map {
            let base = 16 + $0 * 12
            return PFS3Anode(clustersize: data.readBE32(at: base),
                             blocknr: data.readBE32(at: base + 4),
                             next: data.readBE32(at: base + 8))
        }
    }

    func serialize(size: Int) -> Data {
        var block = Data(count: size)
        block.writeBE16(id, at: 0)
        block.writeBE32(datestamp, at: 4)
        block.writeBE32(seqnr, at: 8)
        for (i, anode) in anodes.enumerated() where 16 + i * 12 + 12 <= size {
            let base = 16 + i * 12
            block.writeBE32(anode.clustersize, at: base)
            block.writeBE32(anode.blocknr, at: base + 4)
            block.writeBE32(anode.next, at: base + 8)
        }
        return block
    }
}

/// Directory block ('DB') — header + packed variable-length direntries.
final class PFS3DirBlock: PFS3Block {
    let id = PFS3.dirBlockID
    var datestamp: UInt32 = 0
    var anodenr: UInt32 = 0
    var parent: UInt32 = 0
    /// Raw packed direntry area (`reservedBlksize − 20` bytes). A 0x00 `next`
    /// byte terminates the used portion.
    var entries: Data

    static func entrySpace(reservedBlksize: Int) -> Int { reservedBlksize - 20 }

    init(entrySpace: Int) {
        entries = Data(count: entrySpace)
    }

    init(data: Data, entrySpace: Int) {
        datestamp = data.readBE32(at: 4)
        anodenr   = data.readBE32(at: 12)
        parent    = data.readBE32(at: 16)
        entries   = data.subdata(in: data.startIndex + 20 ..< data.startIndex + 20 + entrySpace)
    }

    func serialize(size: Int) -> Data {
        var block = Data(count: size)
        block.writeBE16(id, at: 0)
        block.writeBE32(datestamp, at: 4)
        block.writeBE32(anodenr, at: 12)
        block.writeBE32(parent, at: 16)
        let space = min(entries.count, size - 20)
        block.replaceSubrange(block.startIndex + 20 ..< block.startIndex + 20 + space,
                              with: entries.prefix(space))
        return block
    }
}

/// Deldir block ('DD').
final class PFS3DelDirBlock: PFS3Block {
    struct Entry {
        var anodenr: UInt32 = 0
        var fsize: UInt32 = 0
        var creationDay: UInt16 = 0
        var creationMinute: UInt16 = 0
        var creationTick: UInt16 = 0
        var filename: Data = Data(count: 16)   // pascal string, padded
        var fsizex: UInt16 = 0
    }

    let id = PFS3.deldirBlockID
    var datestamp: UInt32 = 0
    var seqnr: UInt32 = 0
    var uid: UInt16 = 0
    var gid: UInt16 = 0
    var protection: UInt32 = PFS3.delEntryProt == 0 ? 0 : UInt32(PFS3.delEntryProt)
    var creationDay: UInt16 = 0
    var creationMinute: UInt16 = 0
    var creationTick: UInt16 = 0
    var entries: [Entry]

    /// Always 31 entries regardless of reserved blocksize (blocks.h).
    init() {
        entries = [Entry](repeating: Entry(), count: PFS3.deldirEntriesPerBlock)
    }

    init(data: Data) {
        datestamp = data.readBE32(at: 4)
        seqnr     = data.readBE32(at: 8)
        uid       = data.readBE16(at: 18)
        gid       = data.readBE16(at: 20)
        protection = data.readBE32(at: 22)
        creationDay    = data.readBE16(at: 26)
        creationMinute = data.readBE16(at: 28)
        creationTick   = data.readBE16(at: 30)
        entries = (0 ..< PFS3.deldirEntriesPerBlock).map {
            let base = 32 + $0 * 32
            return Entry(anodenr: data.readBE32(at: base),
                         fsize: data.readBE32(at: base + 4),
                         creationDay: data.readBE16(at: base + 8),
                         creationMinute: data.readBE16(at: base + 10),
                         creationTick: data.readBE16(at: base + 12),
                         filename: data.subdata(in: data.startIndex + base + 14 ..< data.startIndex + base + 30),
                         fsizex: data.readBE16(at: base + 30))
        }
    }

    func serialize(size: Int) -> Data {
        var block = Data(count: size)
        block.writeBE16(id, at: 0)
        block.writeBE32(datestamp, at: 4)
        block.writeBE32(seqnr, at: 8)
        block.writeBE16(uid, at: 18)
        block.writeBE16(gid, at: 20)
        block.writeBE32(protection, at: 22)
        block.writeBE16(creationDay, at: 26)
        block.writeBE16(creationMinute, at: 28)
        block.writeBE16(creationTick, at: 30)
        for (i, entry) in entries.enumerated() {
            let base = 32 + i * 32
            guard base + 32 <= size else { break }
            block.writeBE32(entry.anodenr, at: base)
            block.writeBE32(entry.fsize, at: base + 4)
            block.writeBE16(entry.creationDay, at: base + 8)
            block.writeBE16(entry.creationMinute, at: base + 10)
            block.writeBE16(entry.creationTick, at: base + 12)
            block.replaceSubrange(block.startIndex + base + 14 ..< block.startIndex + base + 30,
                                  with: entry.filename.prefix(16))
            block.writeBE16(entry.fsizex, at: base + 30)
        }
        return block
    }
}

/// Rootblock extension ('EX').
final class PFS3RootBlockExtension: PFS3Block {
    let id = PFS3.extensionBlockID
    var datestamp: UInt32 = 0
    var extOptions: UInt32 = 0
    var pfs2version: UInt32 = (PFS3.verNum << 16) + PFS3.revNum
    var rootDate: (day: UInt16, minute: UInt16, tick: UInt16) = (0, 0, 0)
    var volumeDate: (day: UInt16, minute: UInt16, tick: UInt16) = (0, 0, 0)
    var tobedone: (operationID: UInt32, arg1: UInt32, arg2: UInt32, arg3: UInt32) = (0, 0, 0, 0)
    var reservedRoving: UInt32 = 0
    var rovingbit: UInt16 = 0
    var curranseqnr: UInt16 = 0
    var deldirRoving: UInt16 = 0
    var deldirSize: UInt16 = 0
    var fnsize: UInt16 = 0
    var superindex = [UInt32](repeating: 0, count: PFS3.maxSuper + 1)
    var ddUID: UInt16 = 0
    var ddGID: UInt16 = 0
    var ddProtection: UInt32 = 0
    var ddCreationDay: UInt16 = 0
    var ddCreationMinute: UInt16 = 0
    var ddCreationTick: UInt16 = 0
    var deldir = [UInt32](repeating: 0, count: 32)

    init() {}

    init(data: Data) {
        extOptions  = data.readBE32(at: 4)
        datestamp   = data.readBE32(at: 8)
        pfs2version = data.readBE32(at: 12)
        rootDate    = (data.readBE16(at: 16), data.readBE16(at: 18), data.readBE16(at: 20))
        volumeDate  = (data.readBE16(at: 22), data.readBE16(at: 24), data.readBE16(at: 26))
        tobedone    = (data.readBE32(at: 28), data.readBE32(at: 32),
                       data.readBE32(at: 36), data.readBE32(at: 40))
        reservedRoving = data.readBE32(at: 44)
        rovingbit    = data.readBE16(at: 48)
        curranseqnr  = data.readBE16(at: 50)
        deldirRoving = data.readBE16(at: 52)
        deldirSize   = data.readBE16(at: 54)
        fnsize       = data.readBE16(at: 56)
        for i in 0 ... PFS3.maxSuper {
            superindex[i] = data.readBE32(at: 64 + i * 4)
        }
        ddUID = data.readBE16(at: 128)
        ddGID = data.readBE16(at: 130)
        ddProtection = data.readBE32(at: 132)
        ddCreationDay    = data.readBE16(at: 136)
        ddCreationMinute = data.readBE16(at: 138)
        ddCreationTick   = data.readBE16(at: 140)
        for i in 0 ..< 32 {
            deldir[i] = data.readBE32(at: 144 + i * 4)
        }
    }

    func serialize(size: Int) -> Data {
        var block = Data(count: size)
        block.writeBE16(id, at: 0)
        block.writeBE32(extOptions, at: 4)
        block.writeBE32(datestamp, at: 8)
        block.writeBE32(pfs2version, at: 12)
        block.writeBE16(rootDate.day, at: 16)
        block.writeBE16(rootDate.minute, at: 18)
        block.writeBE16(rootDate.tick, at: 20)
        block.writeBE16(volumeDate.day, at: 22)
        block.writeBE16(volumeDate.minute, at: 24)
        block.writeBE16(volumeDate.tick, at: 26)
        block.writeBE32(tobedone.operationID, at: 28)
        block.writeBE32(tobedone.arg1, at: 32)
        block.writeBE32(tobedone.arg2, at: 36)
        block.writeBE32(tobedone.arg3, at: 40)
        block.writeBE32(reservedRoving, at: 44)
        block.writeBE16(rovingbit, at: 48)
        block.writeBE16(curranseqnr, at: 50)
        block.writeBE16(deldirRoving, at: 52)
        block.writeBE16(deldirSize, at: 54)
        block.writeBE16(fnsize, at: 56)
        for i in 0 ... PFS3.maxSuper {
            block.writeBE32(superindex[i], at: 64 + i * 4)
        }
        block.writeBE16(ddUID, at: 128)
        block.writeBE16(ddGID, at: 130)
        block.writeBE32(ddProtection, at: 132)
        block.writeBE16(ddCreationDay, at: 136)
        block.writeBE16(ddCreationMinute, at: 138)
        block.writeBE16(ddCreationTick, at: 140)
        for i in 0 ..< 32 {
            block.writeBE32(deldir[i], at: 144 + i * 4)
        }
        return block
    }
}
