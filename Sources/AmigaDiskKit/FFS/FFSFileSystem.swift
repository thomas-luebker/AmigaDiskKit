    import Foundation

/// Mounted FFS filesystem — high-level operations over a freshly-formatted partition.
/// Supports: directory listing, mkdir -p, file write, file read, host↔image copy/extract.
public final class FFSFileSystem {
    public let device: BlockDevice
    public let partition: PartitionBlock
    public let rdb: RigidDiskBlock
    public let sliceStartLBA: Int64

    let fsBlockSize: Int
    let layout: FFSLayout
    let partAbsByte: Int64
    let rootFSBlock: UInt32
    private let allocator: FFSAllocator
    /// True for OFS (DOS\0/DOS\1) — data blocks carry a 24-byte header before payload.
    let isOFS: Bool
    /// True for FFS2 long-filename mode (DOS\6/DOS\7) — entry header blocks
    /// store the name in the old comment area and shift the dates. Writing
    /// classic-layout headers on an LNFS volume produces files the real
    /// FFS2 handler sees as nameless (Work Disk.info bug, 2026-06-12).
    let isLongNameFS: Bool

    // MARK: - Init

    public init(
        device: BlockDevice,
        sliceStartLBA: Int64 = 0,
        partition: PartitionBlock,
        rdb: RigidDiskBlock
    ) throws {
        let isFFS = KnownDosType.isFFS(partition.dosType)
        let isOFSType = KnownDosType.isOFS(partition.dosType)
        guard isFFS || isOFSType else {
            throw AmigaDiskError.unsupportedDosType(partition.dosType)
        }
        isOFS = isOFSType
        isLongNameFS = KnownDosType.isLongNameFS(partition.dosType)
        self.device        = device
        self.sliceStartLBA = sliceStartLBA
        self.partition     = partition
        self.rdb           = rdb
        fsBlockSize = Int(partition.fileSystemBlockSize)
        layout      = FFSFormatter.layout(partition: partition, rdb: rdb)
        partAbsByte = (sliceStartLBA + Int64(partition.lowCyl) * Int64(rdb.blocksPerCylinder)) * 512
        rootFSBlock = UInt32(layout.rootBlockFSBlock)

        // Read the actual root block from disk to get the live bitmap block pointers.
        // FFSFormatter.layout() computes expected positions from geometry, but after
        // hst-imager (or any third-party formatter) writes files the authoritative
        // source is the on-disk root block's bitmapBlockPointers field.
        let rootAbsByte = partAbsByte + Int64(rootFSBlock) * Int64(fsBlockSize)
        let rootData = try device.read(at: rootAbsByte, length: fsBlockSize)
        let parsedRoot = try RootBlock(data: rootData)

        // Collect first-25 bitmap pointers from root block (zeros = unused slots).
        var liveBitmapFSBlocks = parsedRoot.bitmapBlockPointers
            .filter { $0 != 0 && $0 != 0xFFFF_FFFF }
            .map { Int($0) }

        // Follow bitmap extension chain for partitions with > 25 bitmap blocks.
        let blockLongsExt = fsBlockSize / 4
        var extFSBlock = parsedRoot.bitmapExtensionBlock
        var extIterations = 0
        while extFSBlock != 0 && extFSBlock != 0xFFFF_FFFF && extIterations < 256 {
            let extAbsByte = partAbsByte + Int64(extFSBlock) * Int64(fsBlockSize)
            let extData = try device.read(at: extAbsByte, length: fsBlockSize)
            for i in 0 ..< (blockLongsExt - 1) {
                let ptr = extData.readBE32(at: i * 4)
                if ptr == 0 || ptr == 0xFFFF_FFFF { break }
                liveBitmapFSBlocks.append(Int(ptr))
            }
            extFSBlock = extData.readBE32(at: (blockLongsExt - 1) * 4)
            extIterations += 1
        }

        // Fall back to layout-computed positions only if root block had no pointers
        // (should never happen on a well-formed image, but ensures allocator is valid).
        let bitmapFSBlocks = liveBitmapFSBlocks.isEmpty ? layout.bitmapBlockFSBlocks : liveBitmapFSBlocks
        allocator = try FFSAllocator(device: device, bitmapFSBlocks: bitmapFSBlocks,
                                     layout: layout, partAbsByte: partAbsByte)

        // hst-imager leaves the root block and bitmap blocks FREE in its bitmap.
        // Mark them used so the allocator never overwrites them.
        allocator.markUsed(rootFSBlock)
        for b in bitmapFSBlocks { allocator.markUsed(UInt32(b)) }

        // ROOT CAUSE (confirmed against hst-imager/hst-amiga source, see Bitmap.cs
        // AdfSetBlockUsed/AdfIsBlockFree): the corruption was a byte-level bitmap
        // *convention* mismatch, not an "untracked region". hst-imager maps absolute
        // block `nSect` to bit `(nSect - reserved) % 32` (LSB-first, mask `1 << k`) of
        // data word `(nSect - reserved) / 32`. FFSAllocator previously mapped the same
        // block to bit `31 - (fsBlock % bitsPerBitmap % 32)` (MSB-first, no `reserved`
        // offset) — a mirrored, incompatible scheme. It was internally self-consistent
        // (format/mount round-trip tests passed) but every "free"/"used" bit either
        // engine wrote was silently misread by the other as describing a *different*
        // block, guaranteeing eventual cross-engine collisions: one engine allocates a
        // block the other believes holds a live header and overwrites it — surfacing
        // later as hst-imager's `Invalid entry block type` while traversing a now-
        // garbage hash-chain pointer. FFSAllocator now uses the canonical mapping
        // (matches hst-imager byte-for-byte), which removes the disagreement at its
        // source — both engines now compute the same bit for the same block.
        //
        // Defense in depth: still re-derive "used" from the live directory tree on
        // every mount (rather than trusting the bitmap snapshot alone). Each AmigaDiskKit
        // invocation is a fresh short-lived process interleaved with raw hst-imager
        // `fs copy` calls on the same partition (sys-merge, OneTimeRunWB staging, Aminet
        // installs); walking the tree confirms ground truth as of "right now" regardless
        // of which engine wrote what since the last mount, independent of whether the
        // on-disk bitmap is perfectly in sync.
        try markReachableEntryBlocksUsed(dirFSBlock: rootFSBlock)
    }

    // MARK: - Public API

    /// Volume name and capacity according to the on-disk root block and the
    /// in-memory allocator bitmap.
    public func volumeInfo() throws -> AmigaVolumeInfo {
        let rootAbsByte = partAbsByte + Int64(rootFSBlock) * Int64(fsBlockSize)
        let root = try RootBlock(data: try device.read(at: rootAbsByte, length: fsBlockSize))
        return AmigaVolumeInfo(
            volumeName: root.diskName,
            totalBytes: Int64(layout.totalFSBlocks) * Int64(fsBlockSize),
            freeBytes: Int64(allocator.freeBlockCount()) * Int64(fsBlockSize)
        )
    }

    /// List entries in the directory at `path`. Use "" or "/" for the volume root.
    public func listDirectory(path: String = "") throws -> [FFSEntry] {
        let dirFSBlock = try resolveDirPath(path)
        return try listDirBlock(dirFSBlock)
    }

    /// List all entries under `path` recursively. Returns relative paths (e.g. "Sub/file.info").
    /// Includes both files and directories. Prefix is prepended to each returned path.
    public func listRecursive(path: String = "") throws -> [String] {
        let dirFSBlock = try resolveDirPath(path)
        return try listRecursiveBlock(dirFSBlock, prefix: "")
    }

    private func listRecursiveBlock(_ dirFSBlock: UInt32, prefix: String) throws -> [String] {
        var results: [String] = []
        let entries = try listDirBlock(dirFSBlock)
        for entry in entries {
            let entryPath = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
            results.append(entryPath)
            if entry.isDirectory {
                let children = try listRecursiveBlock(entry.fsBlock, prefix: entryPath)
                results.append(contentsOf: children)
            }
        }
        return results
    }

    /// Create directories (mkdir -p semantics). No-op for components that already exist.
    public func makeDirectory(path: String) throws {
        let components = pathComponents(path)
        var current = rootFSBlock
        for component in components {
            if let existing = try lookup(name: component, inDir: current) {
                let data = try readFSBlock(existing)
                let bl = data.count / 4
                guard Int32(bitPattern: data.readBE32(at: (bl - 1) * 4)) == 2 else {
                    throw AmigaDiskError.notADirectory(path: component)
                }
                current = existing
            } else {
                let newBlock = try allocator.allocate()
                try writeFSBlock(newBlock, buildDirBlock(own: newBlock, parent: current, name: component))
                try addEntryToDir(entryFSBlock: newBlock, name: component, inDir: current)
                current = newBlock
            }
        }
    }

    /// Write a file to the partition.
    /// - Parameter overwrite: When `true`, silently replace an existing file.
    ///   When `false` (default), throws `entryExists` if the path already exists.
    /// - Parameter protection: Amiga protection bits (e.g. 0x40 for script bit). Default 0 = `----rwed`.
    public func writeFile(path: String, data fileData: Data, overwrite: Bool = false, protection: UInt32 = 0) throws {
        // FFS stores byte_size in a 32-bit field; checked here, before any
        // overwrite-delete or block allocation, so an oversized write is a
        // clean no-op instead of an overflow trap after gigabytes of I/O.
        guard fileData.count <= Int(UInt32.max) else {
            throw AmigaDiskError.fileTooLarge(path: path, size: fileData.count, maxSize: UInt64(UInt32.max))
        }
        let comps = pathComponents(path)
        guard let name = comps.last else { throw AmigaDiskError.pathNotFound(path: path) }
        let parentFSBlock = try resolveDirPath(comps.dropLast().joined(separator: "/"))

        if try lookup(name: name, inDir: parentFSBlock) != nil {
            if overwrite {
                try deleteEntry(name: name, inDir: parentFSBlock)
            } else {
                throw AmigaDiskError.entryExists(path: path)
            }
        }
        try writeFileInternal(name: name, fileData: fileData, parentFSBlock: parentFSBlock, protection: protection)
    }

    /// Read a file from the partition.
    public func readFile(path: String) throws -> Data {
        let comps = pathComponents(path)
        guard let name = comps.last else { throw AmigaDiskError.pathNotFound(path: path) }
        let parentFSBlock = try resolveDirPath(comps.dropLast().joined(separator: "/"))
        guard let entryBlock = try lookup(name: name, inDir: parentFSBlock) else {
            throw AmigaDiskError.pathNotFound(path: path)
        }
        let entry = try FFSEntry.parse(data: try readFSBlock(entryBlock), longNames: isLongNameFS)
        guard entry.isFile else { throw AmigaDiskError.notAFile(path: path) }
        return try assembleFileData(entry: entry)
    }

    /// Copy a host file or directory tree into the partition at `amigaPath`.
    /// If the host item is a directory, its contents are placed inside `amigaPath`.
    /// Files with the macOS executable bit set are written with Amiga script protection
    /// bit 0x40 so AmigaOS `Execute` can run them as scripts.
    public func copyFromHost(hostURL: URL, amigaPath: String, applyUaeMetadata: Bool = false) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: hostURL.path, isDirectory: &isDir) else {
            throw AmigaDiskError.pathNotFound(path: hostURL.path)
        }
        // Never copy the image into itself (e.g. a transfer folder that
        // contains the .img being built) — it reads the file while writing
        // it and fills the partition with garbage.
        if let imageID = device.backingFileID, HostFileIdentity(path: hostURL.path) == imageID {
            fputs("disk fs copy: skipping '\(hostURL.lastPathComponent)': it is the disk image being written\n", stderr)
            return
        }
        if isDir.boolValue {
            try makeDirectory(path: amigaPath)
            let contents = try fm.contentsOfDirectory(
                at: hostURL, includingPropertiesForKeys: nil
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for item in contents {
                // .uaem sidecars carry protection for sibling files; never copy them.
                if applyUaeMetadata && item.pathExtension == UaeMetafile.fileExtension { continue }
                let dest = amigaPath.isEmpty
                    ? item.lastPathComponent
                    : "\(amigaPath)/\(item.lastPathComponent)"
                do {
                    try copyFromHost(hostURL: item, amigaPath: dest, applyUaeMetadata: applyUaeMetadata)
                } catch {
                    // Skip items that can't be accessed or named on FFS
                    // (e.g. locale dirs with non-ASCII names and Latin-1 byte sequences
                    // that macOS cannot reliably resolve as a UTF-8 path string).
                    fputs("disk fs copy: skipping '\(item.lastPathComponent)': \(error)\n", stderr)
                }
            }
        } else {
            let data = try Data(contentsOf: hostURL)
            // A .uaem sidecar (when --uaemetadata is in effect) gives the exact
            // Amiga protection from the source; otherwise fall back to mapping
            // the host execute bit to the script bit. Never mark binaries as
            // scripts — see isBinaryLoadFile.
            let protection: UInt32
            if applyUaeMetadata, let sidecar = uaeSidecarProtection(for: hostURL) {
                protection = sidecar
            } else {
                let attrs = try? fm.attributesOfItem(atPath: hostURL.path)
                let posix = (attrs?[.posixPermissions] as? Int) ?? 0
                protection = (posix & 0o111) != 0 && !isBinaryLoadFile(data) ? 0x40 : 0
            }
            try writeFile(path: amigaPath, data: data, overwrite: true, protection: protection)
        }
    }

    /// Extract a partition path to a host path.
    /// Pass "" or "/" to extract the entire volume.
    public func extractToHost(amigaPath: String, hostURL: URL) throws {
        let comps = pathComponents(amigaPath)
        if comps.isEmpty {
            // Extract entire volume root
            try extractDirBlock(rootFSBlock, to: hostURL)
        } else {
            let parentDir = try resolveDirPath(comps.dropLast().joined(separator: "/"))
            guard let entryBlock = try lookup(name: comps.last!, inDir: parentDir) else {
                throw AmigaDiskError.pathNotFound(path: amigaPath)
            }
            let data = try readFSBlock(entryBlock)
            let bl = data.count / 4
            let secType = Int32(bitPattern: data.readBE32(at: (bl - 1) * 4))
            if secType == 2 {
                // Directory
                try FileManager.default.createDirectory(at: hostURL, withIntermediateDirectories: true)
                try extractDirBlock(entryBlock, to: hostURL)
            } else {
                // File
                let entry = try FFSEntry.parse(data: data, longNames: isLongNameFS)
                let fileData = try assembleFileData(entry: entry)
                try fileData.write(to: hostURL)
            }
        }
    }

    /// Flush bitmap changes to disk. Must be called after all write operations.
    public func flush() throws {
        try allocator.flush(device: device)
    }

    // MARK: - Block I/O

    func readFSBlock(_ fsBlock: UInt32) throws -> Data {
        try device.read(at: partAbsByte + Int64(fsBlock) * Int64(fsBlockSize), length: fsBlockSize)
    }

    func writeFSBlock(_ fsBlock: UInt32, _ data: Data) throws {
        try device.write(data, at: partAbsByte + Int64(fsBlock) * Int64(fsBlockSize))
    }

    // MARK: - Path helpers

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func resolveDirPath(_ path: String) throws -> UInt32 {
        let comps = pathComponents(path)
        var current = rootFSBlock
        for component in comps {
            guard let nextBlock = try lookup(name: component, inDir: current) else {
                throw AmigaDiskError.pathNotFound(path: component)
            }
            let data = try readFSBlock(nextBlock)
            let bl = data.count / 4
            guard Int32(bitPattern: data.readBE32(at: (bl - 1) * 4)) == 2 else {
                throw AmigaDiskError.notADirectory(path: component)
            }
            current = nextBlock
        }
        return current
    }

    // MARK: - Directory operations

    /// Read the hash-table size from a directory or extension block.
    /// OFS user directory blocks store long[3] = 0 (unlike the root block, which always has the
    /// correct ht_size, and FFS blocks, which always store it). Fall back to bl-56 when 0.
    private func readHTSize(_ data: Data) -> Int {
        let bl = data.count / 4
        let stored = Int(data.readBE32(at: 3 * 4))
        return (stored > 0 && stored <= bl - 56) ? stored : bl - 56
    }

    /// Look up a name in a directory (case-insensitive). Returns the entry's FS-block or nil.
    func lookup(name: String, inDir dirFSBlock: UInt32) throws -> UInt32? {
        let dirData = try readFSBlock(dirFSBlock)
        let htSize = readHTSize(dirData)
        let hash = ffsHashName(name, htSize: htSize)
        var chainBlock = dirData.readBE32(at: (6 + hash) * 4)
        while chainBlock != 0 {
            let entryData = try readFSBlock(chainBlock)
            let ebl = entryData.count / 4
            let entryName = isLongNameFS
                ? entryData.readBSTR(at: (ebl - 46) * 4, maxLength: 112)
                : entryData.readBSTR(at: (ebl - 20) * 4, maxLength: 32)
            if entryName.uppercased() == name.uppercased() { return chainBlock }
            chainBlock = entryData.readBE32(at: (ebl - 4) * 4)
        }
        return nil
    }

    /// List all entries in a directory block.
    func listDirBlock(_ dirFSBlock: UInt32) throws -> [FFSEntry] {
        let dirData = try readFSBlock(dirFSBlock)
        let htSize = readHTSize(dirData)
        var entries: [FFSEntry] = []
        for slot in 0 ..< htSize {
            var chainBlock = dirData.readBE32(at: (6 + slot) * 4)
            while chainBlock != 0 {
                let entryData = try readFSBlock(chainBlock)
                let entry = try FFSEntry.parse(data: entryData, longNames: isLongNameFS)
                entries.append(entry)
                chainBlock = entry.hashChain
            }
        }
        return entries.sorted { $0.name.uppercased() < $1.name.uppercased() }
    }

    /// Add an entry to a directory's hashtable.
    private func addEntryToDir(entryFSBlock: UInt32, name: String, inDir dirFSBlock: UInt32) throws {
        var dirData = try readFSBlock(dirFSBlock)
        let htSize = readHTSize(dirData)
        let hash = ffsHashName(name, htSize: htSize)
        let slotOff = (6 + hash) * 4

        let existingHead = dirData.readBE32(at: slotOff)
        if existingHead == 0 {
            // Empty slot — write directly
            dirData.writeBE32(entryFSBlock, at: slotOff)
            embedFFSBlockChecksum(into: &dirData)
            try writeFSBlock(dirFSBlock, dirData)
        } else {
            // Walk to end of chain and append
            var chainBlock = existingHead
            while true {
                var chainData = try readFSBlock(chainBlock)
                let cbl = chainData.count / 4
                let next = chainData.readBE32(at: (cbl - 4) * 4)
                if next == 0 {
                    chainData.writeBE32(entryFSBlock, at: (cbl - 4) * 4)
                    embedFFSBlockChecksum(into: &chainData)
                    try writeFSBlock(chainBlock, chainData)
                    break
                }
                chainBlock = next
            }
        }
    }

    // MARK: - Block builders

    private func buildDirBlock(own: UInt32, parent: UInt32, name: String) -> Data {
        let bl = fsBlockSize / 4
        let htSize = bl - 56
        var block = Data(count: fsBlockSize)
        block.writeBE32(UInt32(2),    at: 0 * 4)   // type = T_SHORT
        block.writeBE32(own,          at: 1 * 4)   // header_key
        block.writeBE32(UInt32(0),    at: 2 * 4)   // high_seq = 0
        block.writeBE32(UInt32(htSize), at: 3 * 4) // ht_size
        block.writeBE32(UInt32(0),    at: 4 * 4)   // first_data = 0
        // long[5] = checksum (embedded below)
        // long[6..6+htSize-1] = hashtable (all zeros)
        block.writeBE32(UInt32(0),    at: (bl - 48) * 4) // protect
        block.writeBE32(UInt32(0),    at: (bl - 47) * 4) // byte_size
        let (d, m, t) = Self.amigaDate(Date())
        if isLongNameFS {
            // LNFS: name in the old comment area, dates at block end − 60.
            block.writeBSTR(name, at: (bl - 46) * 4, maxLength: 110)
            block.writeBE32(d, at: (bl - 15) * 4)
            block.writeBE32(m, at: (bl - 14) * 4)
            block.writeBE32(t, at: (bl - 13) * 4)
        } else {
            block.writeBE32(d, at: (bl - 23) * 4)
            block.writeBE32(m, at: (bl - 22) * 4)
            block.writeBE32(t, at: (bl - 21) * 4)
            block.writeBSTR(name, at: (bl - 20) * 4, maxLength: 31)
        }
        block.writeBE32(UInt32(0),    at: (bl - 4) * 4)  // hash_chain
        block.writeBE32(parent,       at: (bl - 3) * 4)  // parent
        block.writeBE32(UInt32(0),    at: (bl - 2) * 4)  // extension
        block.writeBE32(UInt32(2),    at: (bl - 1) * 4)  // sec_type = ST_USERDIR
        embedFFSBlockChecksum(into: &block)
        return block
    }

    private func buildFileHeaderBlock(
        own: UInt32, parent: UInt32, name: String,
        byteSize: UInt32, dataPtrs: [UInt32], htSize: Int,
        firstExtBlock: UInt32, protection: UInt32 = 0
    ) -> Data {
        let bl = fsBlockSize / 4
        var block = Data(count: fsBlockSize)
        block.writeBE32(UInt32(2),            at: 0 * 4)  // type = T_SHORT
        block.writeBE32(own,                  at: 1 * 4)  // header_key
        block.writeBE32(UInt32(dataPtrs.count), at: 2 * 4) // high_seq
        block.writeBE32(UInt32(htSize),       at: 3 * 4)  // ht_size
        block.writeBE32(dataPtrs.first ?? 0,  at: 4 * 4)  // first_data
        // long[5] = checksum
        // Data ptrs stored reversed: table[htSize-1] = block 0, table[htSize-2] = block 1 …
        for (i, ptr) in dataPtrs.enumerated() {
            block.writeBE32(ptr, at: (6 + htSize - 1 - i) * 4)
        }
        block.writeBE32(protection,   at: (bl - 48) * 4)  // protect
        block.writeBE32(byteSize,     at: (bl - 47) * 4)  // byte_size
        let (d, m, t) = Self.amigaDate(Date())
        if isLongNameFS {
            // LNFS: name in the old comment area, dates at block end − 60.
            block.writeBSTR(name, at: (bl - 46) * 4, maxLength: 110)
            block.writeBE32(d, at: (bl - 15) * 4)
            block.writeBE32(m, at: (bl - 14) * 4)
            block.writeBE32(t, at: (bl - 13) * 4)
        } else {
            block.writeBE32(d, at: (bl - 23) * 4)
            block.writeBE32(m, at: (bl - 22) * 4)
            block.writeBE32(t, at: (bl - 21) * 4)
            block.writeBSTR(name, at: (bl - 20) * 4, maxLength: 31)
        }
        block.writeBE32(UInt32(0),    at: (bl - 4) * 4)   // hash_chain
        block.writeBE32(parent,       at: (bl - 3) * 4)   // parent
        block.writeBE32(firstExtBlock, at: (bl - 2) * 4)  // extension (first ext block or 0)
        block.writeBE32(UInt32(bitPattern: Int32(-3)), at: (bl - 1) * 4) // sec_type = ST_FILE
        embedFFSBlockChecksum(into: &block)
        return block
    }

    private func buildFileExtBlock(
        own: UInt32, parentHeader: UInt32,
        dataPtrs: [UInt32], htSize: Int, nextExt: UInt32
    ) -> Data {
        let bl = fsBlockSize / 4
        var block = Data(count: fsBlockSize)
        block.writeBE32(UInt32(16),           at: 0 * 4)  // type = T_LIST
        block.writeBE32(own,                  at: 1 * 4)  // header_key = own block
        block.writeBE32(UInt32(dataPtrs.count), at: 2 * 4) // high_seq
        block.writeBE32(UInt32(htSize),       at: 3 * 4)  // ht_size
        block.writeBE32(UInt32(0),            at: 4 * 4)  // first_data
        // Data ptrs reversed
        for (i, ptr) in dataPtrs.enumerated() {
            block.writeBE32(ptr, at: (6 + htSize - 1 - i) * 4)
        }
        block.writeBE32(parentHeader, at: (bl - 3) * 4)  // parent = file header
        block.writeBE32(nextExt,      at: (bl - 2) * 4)  // extension (next ext or 0)
        block.writeBE32(UInt32(bitPattern: Int32(-3)), at: (bl - 1) * 4) // sec_type = ST_FILE
        embedFFSBlockChecksum(into: &block)
        return block
    }

    // MARK: - Bitmap repair

    /// Safety bound on hash-chain / extension-chain length — guards against garbage
    /// or cyclic block-number chains in a corrupted tree without limiting any chain
    /// that could plausibly occur on a real volume.
    private static let maxChainHops = 100_000

    /// Walk the directory tree rooted at `dirFSBlock` and call `markUsed` on every
    /// reachable entry block (directory headers, file headers, extension blocks).
    /// File data blocks are intentionally skipped — those are correctly tracked by
    /// hst-imager's bitmap.
    ///
    /// Every block actually present in a hash chain is marked used FIRST, before its
    /// type is even inspected: a chain entry occupies a real block on disk whether or
    /// not it is a type this scan recognises (hard links, soft links, or anything
    /// else FFS allows in a directory). Bailing out of the chain walk early on an
    /// unrecognised type — as a prior version of this scan did — left the remainder
    /// of that chain (and any subtrees beneath it) marked "free", which is exactly
    /// the kind of stale-bitmap gap this whole repair pass exists to close. We only
    /// stop walking a chain on an actual read failure or the hop-count safety bound.
    private func markReachableEntryBlocksUsed(dirFSBlock: UInt32, depth: Int = 0) throws {
        guard depth < 64 else { return }
        guard let dirData = try? readFSBlock(dirFSBlock) else { return }
        let htSize = readHTSize(dirData)
        guard htSize > 0 else { return }

        for slot in 0 ..< htSize {
            var chainBlock = dirData.readBE32(at: (6 + slot) * 4)
            var hops = 0
            while chainBlock != 0 && chainBlock != 0xFFFF_FFFF {
                guard hops < Self.maxChainHops else { break }
                hops += 1
                allocator.markUsed(chainBlock)
                guard let entryData = try? readFSBlock(chainBlock) else { break }
                let eBl = entryData.count / 4
                let primary = entryData.readBE32(at: 0)
                let secType = Int32(bitPattern: entryData.readBE32(at: (eBl - 1) * 4))

                if primary == 2 && secType == 2 {
                    // Directory — recurse into it
                    try markReachableEntryBlocksUsed(dirFSBlock: chainBlock, depth: depth + 1)
                } else if primary == 2 && secType == -3 {
                    // File header — mark extension blocks (data blocks already tracked)
                    var extBlock = entryData.readBE32(at: (eBl - 2) * 4)
                    var extHops = 0
                    while extBlock != 0 && extBlock != 0xFFFF_FFFF && extHops < Self.maxChainHops {
                        extHops += 1
                        allocator.markUsed(extBlock)
                        guard let extData = try? readFSBlock(extBlock) else { break }
                        let extBl = extData.count / 4
                        extBlock = extData.readBE32(at: (extBl - 2) * 4)
                    }
                }
                // Anything else (hard/soft links, unexpected types) is already marked
                // used above; we just don't know how to recurse/extend it further —
                // the chain walk continues regardless.

                // Advance along the hash chain
                chainBlock = entryData.readBE32(at: (eBl - 4) * 4)
            }
        }
    }

    // MARK: - Entry deletion

    /// Free all data blocks and structure blocks (header + extension blocks) of a file.
    private func freeFileBlocks(headerFSBlock: UInt32) throws {
        var structBlock: UInt32 = headerFSBlock
        while structBlock != 0 && structBlock != 0xFFFF_FFFF {
            let blkData = try readFSBlock(structBlock)
            let bl      = blkData.count / 4
            let primary = blkData.readBE32(at: 0)
            let secType = Int32(bitPattern: blkData.readBE32(at: (bl - 1) * 4))
            guard secType == -3 && (primary == 2 || primary == 16) else { break }
            let htSize  = readHTSize(blkData)
            let highSeq = Int(blkData.readBE32(at: 2 * 4))
            for i in 0 ..< highSeq {
                let ptr = blkData.readBE32(at: (6 + htSize - 1 - i) * 4)
                if ptr != 0 && ptr != 0xFFFF_FFFF { allocator.free(ptr) }
            }
            let nextExt = blkData.readBE32(at: (bl - 2) * 4)
            allocator.free(structBlock)
            structBlock = nextExt
        }
    }

    /// Unlink an entry from its parent directory's hashtable chain.
    private func removeEntryFromDir(entryFSBlock: UInt32, name: String, inDir dirFSBlock: UInt32) throws {
        var dirData = try readFSBlock(dirFSBlock)
        let htSize  = readHTSize(dirData)
        let hash    = ffsHashName(name, htSize: htSize)
        let slotOff = (6 + hash) * 4
        let head    = dirData.readBE32(at: slotOff)

        let entryData = try readFSBlock(entryFSBlock)
        let ebl       = entryData.count / 4
        let hashChain = entryData.readBE32(at: (ebl - 4) * 4)

        if head == entryFSBlock {
            dirData.writeBE32(hashChain, at: slotOff)
            embedFFSBlockChecksum(into: &dirData)
            try writeFSBlock(dirFSBlock, dirData)
        } else {
            var prevBlock = head
            while prevBlock != 0 && prevBlock != 0xFFFF_FFFF {
                var prevData = try readFSBlock(prevBlock)
                let pbl  = prevData.count / 4
                let next = prevData.readBE32(at: (pbl - 4) * 4)
                if next == entryFSBlock {
                    prevData.writeBE32(hashChain, at: (pbl - 4) * 4)
                    embedFFSBlockChecksum(into: &prevData)
                    try writeFSBlock(prevBlock, prevData)
                    return
                }
                prevBlock = next
            }
        }
    }

    /// Delete a named entry: free its blocks and unlink from the parent directory.
    /// For files, frees all data blocks and the header block.
    /// For directories, frees only the directory block (non-recursive; contents are orphaned).
    private func deleteEntry(name: String, inDir parentFSBlock: UInt32) throws {
        guard let entryBlock = try lookup(name: name, inDir: parentFSBlock) else { return }
        let entryData = try readFSBlock(entryBlock)
        let bl        = entryData.count / 4
        let secType   = Int32(bitPattern: entryData.readBE32(at: (bl - 1) * 4))
        if secType == -3 {
            try freeFileBlocks(headerFSBlock: entryBlock)
        } else {
            allocator.free(entryBlock)
        }
        try removeEntryFromDir(entryFSBlock: entryBlock, name: name, inDir: parentFSBlock)
    }

    /// Delete a file or directory at the given path. Silently succeeds if the entry does not exist.
    /// Non-recursive: deleting a non-empty directory leaves its contents orphaned on disk.
    public func delete(path: String) throws {
        let comps = pathComponents(path)
        guard !comps.isEmpty else { return }
        let name       = comps.last!
        let parentPath = comps.dropLast().joined(separator: "/")
        let parentFSBlock = try resolveDirPath(parentPath)
        try deleteEntry(name: name, inDir: parentFSBlock)
    }

    // MARK: - File write

    private func writeFileInternal(name: String, fileData: Data, parentFSBlock: UInt32, protection: UInt32 = 0) throws {
        let htSize = fsBlockSize / 4 - 56
        let numDataBlocks = fileData.isEmpty ? 0 : (fileData.count + fsBlockSize - 1) / fsBlockSize
        let numExtBlocks  = numDataBlocks > htSize
            ? (numDataBlocks - htSize + htSize - 1) / htSize : 0

        // Reject up front instead of exhausting the bitmap partway through:
        // allocate(count:) rolls back on failure, but the three allocation
        // calls below are independent, so without this check a failure in a
        // later call would leak the blocks claimed by the earlier ones.
        let neededBlocks = 1 + numExtBlocks + numDataBlocks
        let freeBlocks   = allocator.freeBlockCount()
        guard neededBlocks <= freeBlocks else {
            throw AmigaDiskError.diskFull(requiredBlocks: neededBlocks, freeBlocks: freeBlocks)
        }

        let fileHeaderBlock = try allocator.allocate()
        let extBlocks  = try allocator.allocate(count: numExtBlocks)
        let dataBlocks = try allocator.allocate(count: numDataBlocks)

        // Write data blocks
        for i in 0 ..< numDataBlocks {
            let start = i * fsBlockSize
            let end   = Swift.min(start + fsBlockSize, fileData.count)
            var blk   = Data(count: fsBlockSize)
            blk.replaceSubrange(0 ..< (end - start), with: fileData[start ..< end])
            try writeFSBlock(dataBlocks[i], blk)
        }

        // Write extension blocks (forward order)
        for extIdx in 0 ..< numExtBlocks {
            let startData = htSize + extIdx * htSize
            let endData   = Swift.min(startData + htSize, numDataBlocks)
            let ptrs      = Array(dataBlocks[startData ..< endData])
            let nextExt: UInt32 = extIdx + 1 < numExtBlocks ? extBlocks[extIdx + 1] : 0
            let extData = buildFileExtBlock(
                own: extBlocks[extIdx], parentHeader: fileHeaderBlock,
                dataPtrs: ptrs, htSize: htSize, nextExt: nextExt
            )
            try writeFSBlock(extBlocks[extIdx], extData)
        }

        // Write file header
        let headerPtrs = Array(dataBlocks.prefix(Swift.min(numDataBlocks, htSize)))
        let firstExt: UInt32 = numExtBlocks > 0 ? extBlocks[0] : 0
        let headerData = buildFileHeaderBlock(
            own: fileHeaderBlock, parent: parentFSBlock, name: name,
            byteSize: UInt32(fileData.count), dataPtrs: headerPtrs,
            htSize: htSize, firstExtBlock: firstExt, protection: protection
        )
        try writeFSBlock(fileHeaderBlock, headerData)

        // Link into parent directory
        try addEntryToDir(entryFSBlock: fileHeaderBlock, name: name, inDir: parentFSBlock)
    }

    // MARK: - File read

    private func assembleFileData(entry: FFSEntry) throws -> Data {
        var allPtrs = entry.dataPtrs

        var extFSBlock = entry.extension_
        while extFSBlock != 0 {
            let extData  = try readFSBlock(extFSBlock)
            let htSize   = readHTSize(extData)
            let extHigh  = Int(extData.readBE32(at: 2 * 4))
            for i in 0 ..< extHigh {
                allPtrs.append(extData.readBE32(at: (6 + htSize - 1 - i) * 4))
            }
            extFSBlock = extData.readBE32(at: (extData.count / 4 - 2) * 4)
        }

        var raw = Data()
        raw.reserveCapacity(allPtrs.count * fsBlockSize)
        for (index, ptr) in allPtrs.enumerated() {
            let blk = try readFSBlock(ptr)
            // OFS data blocks carry a 24-byte header: type(T_DATA=8), header_key,
            // seq_num, data_size, next_data, checksum. Detect them robustly —
            // checking ONLY block[0]==8 false-positives on raw FFS file data that
            // happens to begin a block with the longword 0x00000008 (e.g.
            // scsi.device's 8th block), which silently strips 24 bytes and
            // corrupts the file from that point on. A genuine OFS data block also
            // has seq_num == its 1-based position and data_size within the payload.
            let looksOFS = isOFS && blk.count >= 24 && blk.readBE32(at: 0) == 8
            let seq      = looksOFS ? Int(blk.readBE32(at: 2 * 4)) : 0
            let dataSize = looksOFS ? Int(blk.readBE32(at: 3 * 4)) : 0
            if looksOFS && seq == index + 1 && dataSize > 0 && dataSize <= blk.count - 24 {
                raw.append(blk[(blk.startIndex + 24) ..< (blk.startIndex + 24 + dataSize)])
            } else {
                raw.append(contentsOf: blk)
            }
        }
        return Data(raw.prefix(Int(entry.byteSize)))
    }

    // MARK: - Extract helpers

    private func extractDirBlock(_ dirFSBlock: UInt32, to hostURL: URL) throws {
        let entries = try listDirBlock(dirFSBlock)
        let fm = FileManager.default
        for entry in entries {
            let dest = hostURL.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try extractDirBlock(entry.fsBlock, to: dest)
            } else {
                let fileData = try assembleFileData(entry: entry)
                try fileData.write(to: dest)
            }
        }
    }

    // MARK: - Date helper

    private static func amigaDate(_ date: Date) -> (UInt32, UInt32, UInt32) {
        let amigaEpoch: TimeInterval = 252_460_800
        let elapsed = date.timeIntervalSince1970 - amigaEpoch
        guard elapsed >= 0 else { return (0, 0, 0) }
        let total      = Int(elapsed)
        let secsToday  = total % 86400
        return (UInt32(total / 86400), UInt32(secsToday / 60), UInt32(secsToday % 60) * 50)
    }
}

// MARK: - Convenience factory

extension FFSFileSystem {
    /// Open an FFSFileSystem for the named partition in an image.
    /// Pass `sliceStartLBA: nil` (the default) to auto-detect MBR+RDB layout
    /// (PiStorm images); pass an explicit value to override.
    /// Open an ADF (Amiga Disk File) as a read-only filesystem.
    /// Supports standard 880 KB (DD) and 1760 KB (HD) ADF images.
    /// Both FFS (DOS\3/DOS\5/DOS\7) and OFS (DOS\0/DOS\1) are supported.
    /// Other DOS types throw `unsupportedDosType`.
    ///
    /// Internally synthesises a PartitionBlock + RigidDiskBlock that describe the
    /// flat ADF as a single partition: 1 head × 1 sector/track → 1 block/cylinder,
    /// cylinders = totalFSBlocks.  This gives partAbsByte = 0 and
    /// totalFSBlocks = fileSize / 512 without any RDB I/O.
    public static func openADF(url: URL, readOnly: Bool = true) throws -> FFSFileSystem {
        let device = try BlockDevice(url: url, readOnly: readOnly)
        let fileSize: Int64 = try device.size
        guard fileSize >= 1024, fileSize % 512 == 0 else {
            throw AmigaDiskError.readFailed(offset: 0, length: 0,
                                            reason: "invalid ADF size (\(fileSize) bytes): \(url.lastPathComponent)")
        }

        // Read boot block to get DOS type and verify FFS signature.
        let bootData = try device.read(at: 0, length: 1024)
        let bootBlock = try FFSBootBlock(data: bootData)
        let dosType: UInt32 = UInt32(bootBlock.dosType[0]) << 24
                            | UInt32(bootBlock.dosType[1]) << 16
                            | UInt32(bootBlock.dosType[2]) <<  8
                            | UInt32(bootBlock.dosType[3])
        guard KnownDosType.isFFS(dosType) || KnownDosType.isOFS(dosType) else {
            throw AmigaDiskError.unsupportedDosType(dosType)
        }

        // Synthetic geometry: 1 head × 1 sector/track → blocksPerCylinder = 1.
        // totalFSBlocks = fileSize/512; partAbsByte = lowCyl(0) × 1 × 512 = 0.
        let totalBlocks = Int64(fileSize) / 512
        let geo = try DiskGeometry(sizeBytes: fileSize, heads: 1, sectors: 1)
        let rdb = RigidDiskBlock(geometry: geo)
        let part = PartitionBlock(
            name: url.deletingPathExtension().lastPathComponent,
            dosType: dosType,
            lowCyl: 0,
            highCyl: UInt32(totalBlocks - 1),
            geometry: geo,
            sectorsPerFSBlock: 1
        )
        return try FFSFileSystem(device: device, sliceStartLBA: 0, partition: part, rdb: rdb)
    }

    public static func open(
        imageURL: URL,
        partitionName: String,
        sliceStartLBA: Int64? = nil
    ) throws -> FFSFileSystem {
        try open(device: BlockDevice(url: imageURL), partitionName: partitionName,
                 sliceStartLBA: sliceStartLBA)
    }

    /// Mount over an already-open device (shared with the caller).
    public static func open(
        device: BlockDevice,
        partitionName: String,
        sliceStartLBA: Int64? = nil
    ) throws -> FFSFileSystem {
        let resolvedSliceLBA = try resolveRDBSliceLBA(device: device, explicit: sliceStartLBA)
        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: resolvedSliceLBA)
        guard let partition = rdb.partitionBlocks.first(where: { $0.driveName == partitionName }) else {
            throw AmigaDiskError.pathNotFound(path: partitionName)
        }
        return try FFSFileSystem(device: device, sliceStartLBA: resolvedSliceLBA,
                                 partition: partition, rdb: rdb)
    }
}
