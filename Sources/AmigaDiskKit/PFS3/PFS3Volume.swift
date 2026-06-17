import Foundation

/// A directory listing entry.
public struct PFS3Entry {
    public let name: String
    public let isDirectory: Bool
    public let byteSize: Int
    public let protection: UInt32
    public let creationDay: UInt16
    public let creationMinute: UInt16
    public let creationTick: UInt16
    public let comment: String
}

/// Mounted PFS3 volume with the same public surface as `FFSFileSystem`,
/// so the CLI `disk fs` commands can dispatch on the partition dostype.
///
/// Directory and file mechanics ported from hst-amiga `Directory.cs` /
/// `Allocation.cs` (anodechains of extents; packed direntries in dirblock
/// chains; deldir for deleted files; rootblock-last commit via PFS3Update).
public final class PFS3Volume {
    let g: PFS3G

    // MARK: - Mount

    public static func open(imageURL: URL, partitionName: String,
                            sliceStartLBA: Int64? = nil) throws -> PFS3Volume {
        try open(device: BlockDevice(url: imageURL), partitionName: partitionName,
                 sliceStartLBA: sliceStartLBA)
    }

    /// Mount over an already-open device (shared with the caller).
    public static func open(device: BlockDevice, partitionName: String,
                            sliceStartLBA: Int64? = nil) throws -> PFS3Volume {
        let resolvedSlice = try resolveRDBSliceLBA(device: device, explicit: sliceStartLBA)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: resolvedSlice)
        guard let part = rdb.partitionBlocks.first(where: { $0.driveName == partitionName }) else {
            throw AmigaDiskError.pathNotFound(path: partitionName)
        }
        guard KnownDosType.isPFS3(part.dosType) else {
            throw AmigaDiskError.unsupportedDosType(part.dosType)
        }
        return try PFS3Volume(device: device, sliceStartLBA: resolvedSlice, partition: part)
    }

    init(device: BlockDevice, sliceStartLBA: Int64, partition: PartitionBlock) throws {
        g = PFS3G(device: device, sliceStartLBA: sliceStartLBA,
                  blocksPerTrack: partition.blocksPerTrack, surfaces: partition.surfaces,
                  lowCyl: partition.lowCyl, highCyl: partition.highCyl,
                  numBuffers: partition.numBuffer)

        // GetCurrentRoot: boot sector must carry the PFS id, rootblock at 2.
        let boot = try PFS3Disk.rawRead(blocks: 1, blocknr: PFS3.bootBlock1, g)
        guard boot.readBE32(at: 0) == PFS3.idPFSDisk else {
            throw AmigaDiskError.unsupportedDosType(boot.readBE32(at: 0))
        }
        let rootBlock = try PFS3RootBlock(data: try PFS3Disk.rawRead(blocks: 1, blocknr: PFS3.rootBlockNr, g))
        guard rootBlock.diskType == PFS3.idPFSDisk, rootBlock.reservedBlksize == 1024,
              !rootBlock.options.contains(.largeFile) else {
            throw AmigaDiskError.unsupportedDosType(UInt32(bitPattern: Int32(rootBlock.diskType)))
        }
        g.rootBlock = rootBlock
        g.numblocks = g.totalSectors
        g.rescluster = UInt32(rootBlock.reservedBlksize) / g.blocksize

        // reserved bitmap directly behind the rootblock
        let numReserved = (rootBlock.lastReserved - rootBlock.firstReserved + 1) / g.rescluster
        let longs = Int(numReserved / 32 + 1)
        let bitmapBytes = 12 + longs * 4
        let bitmapBlocks = UInt32((bitmapBytes + 511) / 512)
        let bitmapData = try PFS3Disk.rawRead(blocks: bitmapBlocks, blocknr: PFS3.rootBlockNr + 1, g)
        rootBlock.reservedBitmap = PFS3BitmapBlock(data: bitmapData, longs: longs)

        // rootblock extension
        if rootBlock.extension_ > 0, rootBlock.options.contains(.extensionBlock) {
            guard let blk = try PFS3Disk.readReservedBlock(blocknr: rootBlock.extension_, g),
                  blk.id == PFS3.extensionBlockID else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3: rootblock extension invalid")
            }
            let rext = PFS3CachedBlock()
            rext.blk = blk
            rext.blocknr = rootBlock.extension_
            g.rblkextension = rext
        }

        try PFS3Formatter.initModules(formatting: false, g)

        // DiskInsertSequence: bump datestamp for this mount generation.
        rootBlock.options.insert(.datestamp)
        rootBlock.datestamp += 1
        g.dirty = true
    }

    public func flush() throws {
        try PFS3Update.updateDisk(g)
    }

    // MARK: - Anode chain helpers

    /// Advance (anode, offset) by one block within the chain. Returns false at end.
    private func nextBlock(_ anode: inout PFS3CAnode, _ anodeoffset: inout UInt32) throws -> Bool {
        anodeoffset += 1
        while anodeoffset >= anode.clustersize {
            if anode.next == 0 { return false }
            anodeoffset -= anode.clustersize
            try PFS3Anodes.getAnode(&anode, anode.next, g)
        }
        return true
    }

    private func loadDirBlock(_ blocknr: UInt32) throws -> PFS3CachedBlock? {
        if let cached = g.dirblks[blocknr] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }
        let dirblk = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.dirBlockID else {
            PFS3Lru.freeLRU(dirblk, g)
            return nil
        }
        dirblk.blk = blk
        dirblk.blocknr = blocknr
        dirblk.used = 0
        dirblk.changeflag = false
        g.dirblks[blocknr] = dirblk
        return dirblk
    }

    // MARK: - Directory traversal

    private struct FoundEntry {
        let entry: PFS3DirEntry
        let dirblock: PFS3CachedBlock
        let entryOffset: Int
    }

    /// All entries of the directory identified by its anode number.
    private func entries(ofDirAnode dirnodenr: UInt32) throws -> [PFS3DirEntry] {
        var result: [PFS3DirEntry] = []
        try walkDir(dirnodenr) { entry, _, _ in
            result.append(entry)
            return true
        }
        return result
    }

    /// Walk every entry of a directory chain. `body` returns false to stop.
    private func walkDir(_ dirnodenr: UInt32,
                         _ body: (PFS3DirEntry, PFS3CachedBlock, Int) throws -> Bool) throws {
        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, dirnodenr, g)
        var anodeoffset: UInt32 = 0
        while true {
            guard let dirblock = try loadDirBlock(anode.blocknr + anodeoffset),
                  let blk = dirblock.dirBlock else { return }
            var offset = 0
            while let entry = try PFS3DirEntry.read(blk.entries, offset: offset,
                                                    dirExtension: g.dirextension) {
                if try !body(entry, dirblock, offset) { return }
                offset += Int(entry.next)
            }
            if try !nextBlock(&anode, &anodeoffset) { return }
        }
    }

    private func searchInDir(_ dirnodenr: UInt32, _ name: String) throws -> FoundEntry? {
        var found: FoundEntry? = nil
        try walkDir(dirnodenr) { entry, dirblock, offset in
            if entry.name.caseInsensitiveCompare(name) == .orderedSame {
                found = FoundEntry(entry: entry, dirblock: dirblock, entryOffset: offset)
                PFS3Lru.lock(dirblock, g)
                return false
            }
            return true
        }
        return found
    }

    private func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    /// Anode number of the directory at `path` ("" or "/" = root).
    private func resolveDirAnode(_ path: String) throws -> UInt32 {
        var anodenr = PFS3.anodeRootDir
        for component in components(of: path) {
            guard let found = try searchInDir(anodenr, component) else {
                throw AmigaDiskError.pathNotFound(path: path)
            }
            guard found.entry.isDirectory else {
                throw AmigaDiskError.notADirectory(path: path)
            }
            anodenr = found.entry.anode
        }
        return anodenr
    }

    private func resolveParentAndName(_ path: String) throws -> (parentAnode: UInt32, name: String) {
        var comps = components(of: path)
        guard let name = comps.popLast() else {
            throw AmigaDiskError.pathNotFound(path: path)
        }
        return (try resolveDirAnode(comps.joined(separator: "/")), name)
    }

    // MARK: - Public API

    public func listDirectory(path: String) throws -> [PFS3Entry] {
        let anodenr = try resolveDirAnode(path)
        return try entries(ofDirAnode: anodenr).map {
            PFS3Entry(name: $0.name, isDirectory: $0.isDirectory,
                      byteSize: Int($0.fsize),
                      protection: UInt32($0.protection) | $0.extraFields.prot,
                      creationDay: $0.creationDay,
                      creationMinute: $0.creationMinute,
                      creationTick: $0.creationTick,
                      comment: $0.comment)
        }
    }

    /// Volume name and capacity from the root block.
    public func volumeInfo() throws -> AmigaVolumeInfo {
        guard let root = g.rootBlock else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: volume not mounted")
        }
        return AmigaVolumeInfo(
            volumeName: root.diskName,
            totalBytes: Int64(g.numblocks) * Int64(g.blocksize),
            freeBytes: Int64(root.blocksFree) * Int64(g.blocksize)
        )
    }

    public func listRecursive(path: String) throws -> [String] {
        var result: [String] = []
        func recurse(_ dirPath: String) throws {
            for entry in try listDirectory(path: dirPath) {
                let full = dirPath.isEmpty ? entry.name : "\(dirPath)/\(entry.name)"
                result.append(full)
                if entry.isDirectory {
                    try recurse(full)
                }
            }
        }
        try recurse(components(of: path).joined(separator: "/"))
        return result
    }

    public func makeDirectory(path: String) throws {
        var anodenr = PFS3.anodeRootDir
        for component in components(of: path) {
            if let found = try searchInDir(anodenr, component) {
                guard found.entry.isDirectory else {
                    throw AmigaDiskError.invalidGeometry(reason: "PFS3 mkdir: '\(component)' exists as file")
                }
                anodenr = found.entry.anode
            } else {
                anodenr = try newDir(parentAnode: anodenr, name: component)
            }
        }
        try flush()
    }

    public func writeFile(path: String, data: Data, protection: UInt8 = 0) throws {
        // fsize is a 32-bit field; checked before the overwrite-delete below
        // so an oversized write is a clean no-op instead of an overflow trap.
        guard data.count <= Int(UInt32.max) else {
            throw AmigaDiskError.fileTooLarge(path: path, size: data.count, maxSize: UInt64(UInt32.max))
        }
        let (parentAnode, name) = try resolveParentAndName(path)
        if let existing = try searchInDir(parentAnode, name) {
            guard !existing.entry.isDirectory else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3: '\(path)' is a directory")
            }
            try deleteEntry(existing, parentAnode: parentAnode)
        }

        // direntry with a fresh anode (MakeDirEntry + AddDirectoryEntry)
        var entry = PFS3DirEntry()
        entry.type = PFS3.stFile
        entry.anode = try PFS3Anodes.allocAnode(connect: 0, g)
        entry.protection = protection
        let date = AmigaDate(date: g.now)
        entry.creationDay = UInt16(date.days)
        entry.creationMinute = UInt16(date.minutes)
        entry.creationTick = UInt16(date.ticks)
        entry.name = String(name.prefix(Int(g.fnsize) - 1))
        guard entry.anode != 0 else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: anode allocation failed")
        }
        var added = try addDirectoryEntry(dirAnode: parentAnode, entry: entry)

        // allocate data blocks and write contents
        let blocks = UInt32((data.count + Int(g.blocksize) - 1) / Int(g.blocksize))
        if blocks > 0 {
            var chain = try anodeChain(entry.anode)
            guard try allocateBlocksAC(&chain, size: blocks) else {
                // Roll back the direntry added above — a disk-full write must
                // not leave a 0-byte orphan entry in the directory.
                if let orphan = try? searchInDir(parentAnode, name) {
                    try? deleteEntry(orphan, parentAnode: parentAnode)
                    try? flush()
                }
                throw AmigaDiskError.diskFull(requiredBlocks: Int(blocks),
                                              freeBlocks: Int(g.clean_blocksfree))
            }
            var remaining = data
            for node in chain {
                guard !remaining.isEmpty else { break }
                let chunk = remaining.prefix(Int(node.clustersize) * Int(g.blocksize))
                try PFS3Disk.rawWrite(Data(chunk), blocks: node.clustersize, blocknr: node.blocknr, g)
                remaining = remaining.dropFirst(chunk.count)
            }
        }

        // update fsize in the direntry (re-locate it; blocks may have moved)
        guard let written = try searchInDir(parentAnode, name) else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: entry vanished while writing")
        }
        added = written
        var updated = added.entry
        updated.fsize = UInt32(data.count)
        try rewriteEntry(updated, in: added)
        try flush()
    }

    public func readFile(path: String) throws -> Data {
        let (parentAnode, name) = try resolveParentAndName(path)
        guard let found = try searchInDir(parentAnode, name), !found.entry.isDirectory else {
            throw AmigaDiskError.pathNotFound(path: path)
        }
        var result = Data()
        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, found.entry.anode, g)
        while result.count < Int(found.entry.fsize) {
            if anode.blocknr != 0, anode.blocknr != 0xFFFFFFFF, anode.clustersize > 0 {
                result.append(try PFS3Disk.rawRead(blocks: anode.clustersize, blocknr: anode.blocknr, g))
            }
            if anode.next == 0 { break }
            try PFS3Anodes.getAnode(&anode, anode.next, g)
        }
        return result.prefix(Int(found.entry.fsize))
    }

    public func delete(path: String) throws {
        let (parentAnode, name) = try resolveParentAndName(path)
        guard let found = try searchInDir(parentAnode, name) else {
            throw AmigaDiskError.pathNotFound(path: path)
        }
        try deleteEntry(found, parentAnode: parentAnode)
        try flush()
    }

    public func copyFromHost(hostURL: URL, amigaPath: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir) else {
            throw AmigaDiskError.pathNotFound(path: hostURL.path)
        }
        // Never copy the image into itself (e.g. a transfer folder that
        // contains the .img being built) — it reads the file while writing
        // it and fills the partition with garbage.
        if let imageID = g.device.backingFileID, HostFileIdentity(path: hostURL.path) == imageID {
            fputs("disk fs copy: skipping '\(hostURL.lastPathComponent)': it is the disk image being written\n", stderr)
            return
        }
        if isDir.boolValue {
            try makeDirectory(path: amigaPath)
            for child in try FileManager.default.contentsOfDirectory(at: hostURL,
                                                                     includingPropertiesForKeys: nil) {
                let target = amigaPath.isEmpty ? child.lastPathComponent
                                               : "\(amigaPath)/\(child.lastPathComponent)"
                do {
                    try copyFromHost(hostURL: child, amigaPath: target)
                } catch {
                    // Skip items that can't be copied (unreadable, file too
                    // large, disk full) and keep going — same per-item
                    // resilience as the FFS engine's directory recursion.
                    fputs("disk fs copy: skipping '\(child.lastPathComponent)': \(error)\n", stderr)
                }
            }
        } else {
            let data = try Data(contentsOf: hostURL)
            // AmigaOS protection: low nibble RWED active-low (0 = allowed);
            // mirror the FFS engine's mapping of the host execute bit to 's',
            // but never mark binaries as scripts (see isBinaryLoadFile).
            let executable = FileManager.default.isExecutableFile(atPath: hostURL.path)
            let protection: UInt8 = executable && !isBinaryLoadFile(data) ? 0x40 : 0
            try writeFile(path: amigaPath, data: data, protection: protection)
        }
    }

    public func extractToHost(amigaPath: String, hostURL: URL) throws {
        let comps = components(of: amigaPath)
        if let parentName = comps.last,
           let found = try? searchInDir(try resolveDirAnode(comps.dropLast().joined(separator: "/")),
                                        parentName),
           !found.entry.isDirectory {
            try FileManager.default.createDirectory(at: hostURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try readFile(path: amigaPath).write(to: hostURL)
            return
        }
        // directory (or root): recurse
        try FileManager.default.createDirectory(at: hostURL, withIntermediateDirectories: true)
        for entry in try listDirectory(path: amigaPath) {
            let childAmiga = comps.isEmpty ? entry.name : "\(comps.joined(separator: "/"))/\(entry.name)"
            try extractToHost(amigaPath: childAmiga, hostURL: hostURL.appendingPathComponent(entry.name))
        }
    }

    // MARK: - Internals: create / insert / remove

    /// Create a subdirectory; returns its anode number (Directory.NewDir).
    private func newDir(parentAnode: UInt32, name: String) throws -> UInt32 {
        var entry = PFS3DirEntry()
        entry.type = PFS3.stUserDir
        entry.anode = try PFS3Anodes.allocAnode(connect: 0, g)
        let date = AmigaDate(date: g.now)
        entry.creationDay = UInt16(date.days)
        entry.creationMinute = UInt16(date.minutes)
        entry.creationTick = UInt16(date.ticks)
        entry.name = String(name.prefix(Int(g.fnsize) - 1))
        guard entry.anode != 0 else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3 mkdir: anode allocation failed")
        }
        _ = try addDirectoryEntry(dirAnode: parentAnode, entry: entry)

        // make the directory's first dirblock (needed for parent finding)
        let blocknr = PFS3Allocation.allocReservedBlock(g)
        guard blocknr != 0 else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3 mkdir: disk full")
        }
        _ = try PFS3Directory.makeDirBlock(blocknr: blocknr, anodenr: entry.anode,
                                           rootanodenr: entry.anode, parentnr: parentAnode, g)
        return entry.anode
    }

    /// Directory.AddDirectoryEntry: append into the first dirblock with room,
    /// else prepend a fresh dirblock to the chain (the new block takes over
    /// the directory's head anode number, keeping it stable).
    @discardableResult
    private func addDirectoryEntry(dirAnode diranodenr: UInt32, entry: PFS3DirEntry) throws -> FoundEntry {
        let entrySpace = PFS3DirBlock.entrySpace(reservedBlksize: g.resBlockSize)
        let newSize = PFS3DirEntry.entrySize(name: entry.name, comment: entry.comment,
                                             extraFields: entry.extraFields, dirExtension: g.dirextension)

        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, diranodenr, g)
        var anodeoffset: UInt32 = 0
        var eof = false
        var lastBlok: PFS3CachedBlock? = nil
        while !eof {
            guard let blok = try loadDirBlock(anode.blocknr + anodeoffset),
                  let blk = blok.dirBlock else { break }
            lastBlok = blok
            // used bytes = sum of entry sizes up to the 0 terminator
            var used = 0
            while used < blk.entries.count {
                let next = blk.entries[blk.entries.startIndex + used]
                if next == 0 { break }
                used += Int(next)
            }
            if used + newSize + 1 < entrySpace {
                var entries = blk.entries
                var mutable = entry
                mutable.write(into: &entries, offset: used, dirExtension: g.dirextension)
                blk.entries = entries
                PFS3Lru.lock(blok, g)
                _ = try PFS3Update.makeBlockDirty(blok, g)
                return FoundEntry(entry: entry, dirblock: blok, entryOffset: used)
            }
            eof = try !nextBlock(&anode, &anodeoffset)
        }

        // no space: new dirblock at the START of the chain
        guard let parentBlok = lastBlok, let parentBlk = parentBlok.dirBlock else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: directory chain unreadable")
        }
        let parent = parentBlk.parent
        var newanode = PFS3CAnode(clustersize: 1, blocknr: 0, next: 0, nr: 0)
        newanode.blocknr = PFS3Allocation.allocReservedBlock(g)
        guard newanode.blocknr != 0 else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: disk full extending directory")
        }
        try PFS3Anodes.getAnode(&anode, diranodenr, g)
        newanode.nr = diranodenr
        let movedNr = try PFS3Anodes.allocAnode(connect: anode.next > 0 ? anode.next : anode.nr, g)
        newanode.next = movedNr
        anode.nr = movedNr
        try PFS3Anodes.saveAnode(&anode, anode.nr, g)
        let blok = try PFS3Directory.makeDirBlock(blocknr: newanode.blocknr, anodenr: newanode.nr,
                                                  rootanodenr: diranodenr, parentnr: parent, g)
        try PFS3Anodes.saveAnode(&newanode, newanode.nr, g)
        guard let blk = blok.dirBlock else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: fresh dirblock invalid")
        }
        var entries = blk.entries
        var mutable = entry
        mutable.write(into: &entries, offset: 0, dirExtension: g.dirextension)
        blk.entries = entries
        PFS3Lru.lock(blok, g)
        _ = try PFS3Update.makeBlockDirty(blok, g)
        return FoundEntry(entry: entry, dirblock: blok, entryOffset: 0)
    }

    /// Remove the entry at `found` from its dirblock (compact in place).
    private func removeDirEntry(_ found: FoundEntry) throws {
        guard let blk = found.dirblock.dirBlock else { return }
        var entries = blk.entries
        let size = Int(found.entry.next)
        let start = entries.startIndex + found.entryOffset
        entries.removeSubrange(start ..< start + size)
        entries.append(Data(count: size))   // keep the area size constant
        blk.entries = entries
        PFS3Lru.lock(found.dirblock, g)
        _ = try PFS3Update.makeBlockDirty(found.dirblock, g)
    }

    /// Rewrite an entry's fixed fields in place (same name/size).
    private func rewriteEntry(_ entry: PFS3DirEntry, in found: FoundEntry) throws {
        guard let blk = found.dirblock.dirBlock else { return }
        var entries = blk.entries
        var mutable = entry
        mutable.write(into: &entries, offset: found.entryOffset, dirExtension: g.dirextension)
        blk.entries = entries
        _ = try PFS3Update.makeBlockDirty(found.dirblock, g)
    }

    private func deleteEntry(_ found: FoundEntry, parentAnode: UInt32) throws {
        if found.entry.isDirectory {
            guard try entries(ofDirAnode: found.entry.anode).isEmpty else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3: directory not empty")
            }
            // free the directory's dirblocks, then its anode chain
            var anode = PFS3CAnode()
            try PFS3Anodes.getAnode(&anode, found.entry.anode, g)
            while true {
                if anode.blocknr != 0, anode.blocknr != 0xFFFFFFFF {
                    PFS3Allocation.freeReservedBlock(anode.blocknr, g)
                }
                if anode.next == 0 { break }
                try PFS3Anodes.getAnode(&anode, anode.next, g)
            }
            try freeAnodesInChain(found.entry.anode)
            try removeDirEntry(found)
            return
        }

        // file: free data blocks; deldir keeps the anode chain for recovery
        var chain = try anodeChain(found.entry.anode)
        if g.deldirenabled {
            try freeBlocksAC(&chain, size: .max, freetype: .keepAnodes)
            let ddnr = try allocDeldirSlot()
            try addToDeldir(found.entry, ddnr: ddnr)
        } else {
            try freeBlocksAC(&chain, size: .max, freetype: .freeAnodes)
            try PFS3Anodes.freeAnode(found.entry.anode, g)
        }
        try removeDirEntry(found)
    }

    // MARK: - Anode chains + block allocation (Allocation.cs AC functions)

    private func anodeChain(_ anodenr: UInt32) throws -> [PFS3CAnode] {
        var chain: [PFS3CAnode] = []
        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, anodenr, g)
        chain.append(anode)
        while anode.next != 0 {
            try PFS3Anodes.getAnode(&anode, anode.next, g)
            chain.append(anode)
        }
        return chain
    }

    /// Allocation.AllocateBlocksAC (ref == nil variant): extend the chain's
    /// tail with `size` blocks from the main bitmap using the roving pointer.
    private func allocateBlocksAC(_ chain: inout [PFS3CAnode], size: UInt32) throws -> Bool {
        var size = size
        guard g.alloc_available >= size else { return false }
        if g.clean_blocksfree < size {
            try PFS3Update.updateDisk(g)
        }

        var chnodeIdx = chain.count - 1
        let fragments = UInt32(chain.count - 1)
        let extra = min(256, fragments * 8)
        var extend = false
        var updateroving = true
        var nr: UInt32 = 0
        var i: UInt32 = 0
        var j: UInt32 = 0
        var bmseqnr: UInt32 = 0
        var bmoffset: UInt32 = 0

        if chain[chnodeIdx].blocknr != 0, chain[chnodeIdx].blocknr != .max {
            i = chain[chnodeIdx].blocknr + chain[chnodeIdx].clustersize - g.bitmapstart
            nr = i / 32
            i %= 32
            j = UInt32(1) << (31 - i)
            bmseqnr = nr / g.longsperbmb
            bmoffset = nr % g.longsperbmb
            guard let bitmap = try PFS3Allocation.getBitmapBlock(bmseqnr, g),
                  let bmBlk = bitmap.bitmapBlock else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3: bitmap block missing")
            }
            if bmBlk.bitmap[Int(bmoffset)] & j != 0 {
                extend = true
                if nr != g.rootBlock.rovingPtr { updateroving = false }
            }
        }

        if !extend {
            nr = g.rootBlock.rovingPtr
            bmseqnr = nr / g.longsperbmb
            bmoffset = nr % g.longsperbmb
            i = g.rovingbit
            j = UInt32(1) << (31 - i)
        }

        allocLoop: while size != 0 {
            guard let bitmap = try PFS3Allocation.getBitmapBlock(bmseqnr, g) else {
                throw AmigaDiskError.invalidGeometry(reason: "PFS3: bitmap block missing")
            }
            let oldlock = bitmap.used
            while bmoffset < g.longsperbmb {
                guard let bmBlk = bitmap.bitmapBlock else {
                    throw AmigaDiskError.invalidGeometry(reason: "PFS3: bitmap cache corrupted")
                }
                let field = bmBlk.bitmap[Int(bmoffset)]
                if field != 0 {
                    while i < 32 {
                        if field & j != 0 {
                            let blocknr = (bmseqnr * g.longsperbmb + bmoffset) * 32 + i + g.bitmapstart
                            if blocknr >= g.numblocks {
                                bmoffset = g.longsperbmb
                                continue
                            }
                            PFS3Lru.lock(bitmap, g)
                            if chain[chnodeIdx].blocknr == .max {
                                chain[chnodeIdx].blocknr = blocknr
                                chain[chnodeIdx].clustersize = 0
                                chain[chnodeIdx].next = 0
                            } else if chain[chnodeIdx].blocknr + chain[chnodeIdx].clustersize != blocknr {
                                let anodenr = try PFS3Anodes.allocAnode(connect: chain[chnodeIdx].nr, g)
                                chain[chnodeIdx].next = anodenr
                                try PFS3Anodes.saveAnode(&chain[chnodeIdx], chain[chnodeIdx].nr, g)
                                chain.append(PFS3CAnode(clustersize: 0, blocknr: blocknr, next: 0, nr: anodenr))
                                chnodeIdx += 1
                            }
                            bmBlk.bitmap[Int(bmoffset)] &= ~j
                            chain[chnodeIdx].clustersize += 1
                            _ = try PFS3Update.makeBlockDirty(bitmap, g)
                            g.clean_blocksfree -= 1
                            g.alloc_available -= 1
                            size -= 1
                            if size == 0 { break allocLoop }
                        }
                        j >>= 1
                        i += 1
                    }
                    i = 0
                    j = UInt32(1) << 31
                }
                bmoffset += 1
            }
            bitmap.used = oldlock
            bmseqnr = (bmseqnr + 1) % g.no_bmb
            bmoffset = 0
        }

        try PFS3Anodes.saveAnode(&chain[chnodeIdx], chain[chnodeIdx].nr, g)

        if updateroving {
            if extend {
                i += extra
                g.rovingbit = i % 32
                bmoffset += i / 32
                if bmoffset >= g.longsperbmb {
                    bmoffset -= g.longsperbmb
                    bmseqnr = (bmseqnr + 1) % g.no_bmb
                }
            } else {
                g.rovingbit = i
            }
            g.rootBlock.rovingPtr = bmseqnr * g.longsperbmb + bmoffset
        }
        return true
    }

    private enum FreeBlockType { case keepAnodes, freeAnodes }

    /// Allocation.FreeBlocksAC, whole-chain variant (delete path): every
    /// extent goes onto the to-be-freed list committed by the next update.
    /// `keepAnodes` leaves the anode chain intact for the deldir.
    private func freeBlocksAC(_ chain: inout [PFS3CAnode], size: UInt32,
                              freetype: FreeBlockType) throws {
        let rext = g.rblkextension
        if let rextBlk = rext?.rext {
            rextBlk.tobedone = (freetype == .keepAnodes ? 2 : 1, chain[0].nr, size, 0)
            _ = try PFS3Update.makeBlockDirty(rext!, g)
        }

        for idx in stride(from: chain.count - 1, through: 0, by: -1) {
            let freeing = chain[idx].clustersize
            guard freeing != 0, chain[idx].blocknr != 0, chain[idx].blocknr != .max else { continue }
            chain[idx].clustersize = 0
            g.tobefreed.append((chain[idx].blocknr, freeing))
            g.tbf_resneed += 3 + freeing / (32 * g.longsperbmb)
            g.alloc_available += freeing
            if freetype == .freeAnodes, idx != 0 {
                try PFS3Anodes.freeAnode(chain[idx].nr, g)
            }
        }

        if freetype == .freeAnodes {
            // restore head anode as empty
            chain[0].next = 0
            chain[0].clustersize = 0
            chain[0].blocknr = .max
            try PFS3Anodes.saveAnode(&chain[0], chain[0].nr, g)
        }

        if let rextBlk = rext?.rext {
            rextBlk.tobedone = (0, 0, 0, 0)
            _ = try PFS3Update.makeBlockDirty(rext!, g)
        }
        g.dirty = true
    }

    private func freeAnodesInChain(_ anodenr: UInt32) throws {
        var anode = PFS3CAnode()
        try PFS3Anodes.getAnode(&anode, anodenr, g)
        while anode.nr != 0 {
            try PFS3Anodes.freeAnode(anode.nr, g)
            if anode.next == 0 { break }
            try PFS3Anodes.getAnode(&anode, anode.next, g)
        }
    }

    // MARK: - Deldir

    private func getDeldirBlock(_ seqnr: UInt16) throws -> PFS3CachedBlock? {
        guard let rext = g.rblkextension?.rext else { return nil }
        if let cached = g.deldirblksBySeqNr[UInt32(seqnr)] {
            PFS3Lru.makeLRU(cached, g)
            return cached
        }
        let blocknr = rext.deldir[Int(seqnr)]
        guard blocknr != 0 else { return nil }
        let ddblk = try PFS3Lru.allocLRU(g)
        guard let blk = try PFS3Disk.readReservedBlock(blocknr: blocknr, g),
              blk.id == PFS3.deldirBlockID else {
            PFS3Lru.freeLRU(ddblk, g)
            return nil
        }
        ddblk.blk = blk
        ddblk.blocknr = blocknr
        ddblk.changeflag = false
        g.deldirblks[blocknr] = ddblk
        g.deldirblksBySeqNr[UInt32(seqnr)] = ddblk
        return ddblk
    }

    private func allocDeldirSlot() throws -> Int {
        guard let rextCached = g.rblkextension, let rext = rextCached.rext else {
            throw AmigaDiskError.invalidGeometry(reason: "PFS3: deldir without extension")
        }
        let ddnr = Int(rext.deldirRoving)
        guard let ddblk = try getDeldirBlock(UInt16(ddnr / PFS3.deldirEntriesPerBlock)),
              let dd = ddblk.deldirBlock else {
            rext.deldirRoving = 0
            return 0
        }
        rext.deldirRoving = UInt16((Int(rext.deldirRoving) + 1)
                                   % (Int(rext.deldirSize) * PFS3.deldirEntriesPerBlock))
        _ = try PFS3Update.makeBlockDirty(ddblk, g)
        let slot = ddnr % PFS3.deldirEntriesPerBlock
        let anodenr = dd.entries[slot].anodenr
        if anodenr != 0 {
            dd.entries[slot].anodenr = 0
            try freeAnodesInChain(anodenr)
        }
        return ddnr
    }

    private func addToDeldir(_ entry: PFS3DirEntry, ddnr: Int) throws {
        guard let ddblk = try getDeldirBlock(UInt16(ddnr / PFS3.deldirEntriesPerBlock)),
              let dd = ddblk.deldirBlock,
              let rext = g.rblkextension?.rext else { return }
        var slotEntry = PFS3DelDirBlock.Entry()
        slotEntry.anodenr = entry.anode
        slotEntry.fsize = entry.fsize
        slotEntry.creationDay = entry.creationDay
        slotEntry.creationMinute = entry.creationMinute
        slotEntry.creationTick = entry.creationTick
        var nameData = Data(count: 16)
        let truncated = Array(entry.name.amigaLatin1Bytes.prefix(PFS3.delEntryFNSize - 1 - 2))
        nameData[nameData.startIndex] = UInt8(truncated.count)
        for (i, byte) in truncated.enumerated() where i < 15 {
            nameData[nameData.startIndex + 1 + i] = byte
        }
        slotEntry.filename = nameData
        dd.entries[ddnr % PFS3.deldirEntriesPerBlock] = slotEntry
        dd.creationDay = rext.ddCreationDay
        dd.creationMinute = rext.ddCreationMinute
        dd.creationTick = rext.ddCreationTick
        _ = try PFS3Update.makeBlockDirty(ddblk, g)
    }
}
