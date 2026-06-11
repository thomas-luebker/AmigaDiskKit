import Foundation

/// High-level FAT32 filesystem operations.
///
/// Reads the MBR to locate the FAT32 partition (partition index 0 by default),
/// then provides directory listing, file copy, mkdir, and delete operations.
///
/// All path arguments use forward-slash separators and are case-insensitive.
/// A leading slash is optional: `/config.txt` and `config.txt` are equivalent.
public final class FAT32Volume {

    // MARK: - State

    private let fat: FAT32Table

    // MARK: - Init

    /// Open a disk image and attach to the FAT32 partition at `mbrIndex` (0-based).
    public convenience init(imageURL: URL, mbrIndex: Int = 0, readOnly: Bool = false) throws {
        let device = try BlockDevice(url: imageURL, readOnly: readOnly)
        try self.init(device: device, mbrIndex: mbrIndex)
    }

    init(device: BlockDevice, mbrIndex: Int = 0) throws {
        let mbrData = try device.read(at: 0, length: 512)
        let mbr = try MBRPartitionTable(data: mbrData)
        guard mbrIndex < mbr.partitions.count else {
            throw AmigaDiskError.mbrPartitionOutOfBounds(index: mbrIndex)
        }
        let entry = mbr.partitions[mbrIndex]
        let partStart = Int64(entry.lbaStart) * 512
        let vbr = try device.read(at: partStart, length: 512)
        let bpb = try FAT32BPB(data: vbr)
        self.fat = FAT32Table(device: device, bpb: bpb, partitionStart: partStart)
    }

    // MARK: - Public API

    /// List the contents of `path` (default: root directory).
    public func listDirectory(_ path: String = "/") throws -> [FAT32Entry] {
        let cluster = try resolveDirectoryCluster(path)
        return try readDirectory(cluster: cluster)
    }

    /// Return true if the path exists (file or directory).
    public func exists(_ path: String) throws -> Bool {
        let components = normalize(path)
        if components.isEmpty { return true }
        return try resolveEntry(components: components) != nil
    }

    /// Create a directory at `path` (including any missing parents).
    public func makeDirectory(_ path: String) throws {
        try makeDirectoryInternal(components: normalize(path))
    }

    /// Copy a host file into the FAT32 volume at `destination`.
    /// Parent directories must exist; overwrites any existing file.
    public func copyFromHost(source: URL, destination: String) throws {
        let data = try Data(contentsOf: source)
        try writeFile(data: data, at: normalize(destination))
    }

    /// Extract a FAT32 file to a host path.
    public func copyToHost(source: String, destination: URL) throws {
        let components = normalize(source)
        guard let entry = try resolveEntry(components: components) else {
            throw AmigaDiskError.pathNotFound(path: source)
        }
        guard !entry.isDirectory else { throw AmigaDiskError.notAFile(path: source) }
        let data: Data
        if entry.firstCluster >= 2 {
            data = try fat.readChainData(startingAt: entry.firstCluster, maxBytes: Int(entry.fileSize))
        } else {
            data = Data()
        }
        try data.write(to: destination)
    }

    /// Recursively copy `source` host directory into `destination` on the volume.
    /// Creates `destination` if it doesn't exist.
    public func copyDirectoryFromHost(source: URL, destination: String) throws {
        try makeDirectoryIfAbsent(destination)
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: source,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])
        for item in items {
            let name = item.lastPathComponent
            let destPath = destination.hasSuffix("/") ? "\(destination)\(name)" : "\(destination)/\(name)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue {
                try copyDirectoryFromHost(source: item, destination: destPath)
            } else {
                try copyFromHost(source: item, destination: destPath)
            }
        }
    }

    /// Delete a file or empty directory at `path` (no-op if not found).
    public func delete(_ path: String) throws {
        let components = normalize(path)
        guard !components.isEmpty else { return }
        let parentComponents = Array(components.dropLast())
        let name = components.last!
        let parentCluster = try resolveDirectoryCluster(pathComponents: parentComponents)
        try removeEntry(name: name, from: parentCluster)
    }

    // MARK: - Path helpers

    private func normalize(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Directory resolution

    private func resolveDirectoryCluster(_ path: String = "/") throws -> UInt32 {
        try resolveDirectoryCluster(pathComponents: normalize(path))
    }

    private func resolveDirectoryCluster(pathComponents components: [String]) throws -> UInt32 {
        if components.isEmpty { return fat.bpb.rootCluster }
        guard let entry = try resolveEntry(components: components) else {
            throw AmigaDiskError.pathNotFound(path: components.joined(separator: "/"))
        }
        guard entry.isDirectory else {
            throw AmigaDiskError.notADirectory(path: components.joined(separator: "/"))
        }
        return entry.firstCluster
    }

    private func resolveEntry(components: [String]) throws -> FAT32Entry? {
        var currentCluster = fat.bpb.rootCluster
        var found: FAT32Entry? = nil
        for (idx, name) in components.enumerated() {
            let entries = try readDirectory(cluster: currentCluster)
            guard let match = entries.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                return nil
            }
            found = match
            if idx < components.count - 1 {
                guard match.isDirectory else { return nil }
                currentCluster = match.firstCluster
            }
        }
        return found
    }

    private func readDirectory(cluster: UInt32) throws -> [FAT32Entry] {
        let data = try fat.readChainData(startingAt: cluster)
        return FAT32Entry.parseDirectory(data).filter { !$0.isDot }
    }

    // MARK: - mkdir

    private func makeDirectoryInternal(components: [String]) throws {
        var currentCluster = fat.bpb.rootCluster
        for (i, name) in components.enumerated() {
            let entries = try readDirectory(cluster: currentCluster)
            if let existing = entries.first(where: { $0.name.lowercased() == name.lowercased() }) {
                guard existing.isDirectory else {
                    throw AmigaDiskError.notADirectory(path: components[0...i].joined(separator: "/"))
                }
                currentCluster = existing.firstCluster
            } else {
                // Create this directory component
                let newCluster = try fat.allocateCluster()
                // Zero the cluster, then write . and .. entries
                var dirData = Data(count: fat.bpb.bytesPerCluster)
                let dot    = FAT32Entry.serialize(name: ".", attributes: FAT32Attr.directory,
                                                   firstCluster: newCluster, fileSize: 0)
                let dotDot = FAT32Entry.serialize(name: "..", attributes: FAT32Attr.directory,
                                                   firstCluster: currentCluster, fileSize: 0)
                dirData.replaceSubrange(0 ..< 32, with: dot[0])
                dirData.replaceSubrange(32 ..< 64, with: dotDot[0])
                try fat.writeCluster(newCluster, data: dirData)

                let date = currentFATDate()
                try appendEntries(FAT32Entry.serialize(name: name, attributes: FAT32Attr.directory,
                                                        firstCluster: newCluster, fileSize: 0,
                                                        date: date),
                                   toDirectory: currentCluster)
                currentCluster = newCluster
            }
        }
    }

    private func makeDirectoryIfAbsent(_ path: String) throws {
        guard try !exists(path) else { return }
        try makeDirectory(path)
    }

    // MARK: - File write

    private func writeFile(data: Data, at components: [String]) throws {
        guard !components.isEmpty else { return }
        let name = components.last!
        let parentComps = Array(components.dropLast())
        let parentCluster = try resolveDirectoryCluster(pathComponents: parentComps)
        let entries = try readDirectory(cluster: parentCluster)

        // Remove existing entry if present (free old cluster chain)
        if let existing = entries.first(where: { $0.name.lowercased() == name.lowercased() }) {
            if existing.firstCluster >= 2 {
                try fat.freeChain(startingAt: existing.firstCluster)
            }
            try removeEntry(name: name, from: parentCluster)
        }

        let clusterSize = fat.bpb.bytesPerCluster
        let firstCluster: UInt32
        if data.isEmpty {
            firstCluster = 0
        } else {
            let needed = (data.count + clusterSize - 1) / clusterSize
            firstCluster = try fat.allocateChain(length: needed)
            try fat.writeChainData(startingAt: firstCluster, data: data)
        }

        let date = currentFATDate()
        try appendEntries(FAT32Entry.serialize(name: name, attributes: FAT32Attr.archive,
                                               firstCluster: firstCluster, fileSize: UInt32(data.count),
                                               date: date),
                          toDirectory: parentCluster)
    }

    // MARK: - Directory entry append

    /// Find `blocks.count` consecutive free slots in `dirCluster` and write the entry blocks.
    private func appendEntries(_ blocks: [Data], toDirectory dirCluster: UInt32) throws {
        let needed = blocks.count
        let clusterSize = fat.bpb.bytesPerCluster
        let chain = try fat.clusterChain(startingAt: dirCluster)

        // Read all directory data into a mutable flat buffer
        var dirData = Data(capacity: chain.count * clusterSize)
        for c in chain { dirData.append(try fat.readCluster(c)) }

        // Locate a run of `needed` consecutive free or deleted slots
        let totalSlots = dirData.count / 32
        var runStart = -1
        var runLen = 0
        var endSentinelIdx = totalSlots  // tracks first 0x00 slot (end-of-dir)

        for i in 0 ..< totalSlots {
            let first = dirData[dirData.startIndex + i * 32]
            if first == 0x00 {
                if endSentinelIdx == totalSlots { endSentinelIdx = i }
                if runStart == -1 { runStart = i }
                runLen += 1
                if runLen >= needed { break }
            } else if first == 0xE5 {
                if runStart == -1 { runStart = i }
                runLen += 1
                if runLen >= needed { break }
            } else {
                runStart = -1
                runLen = 0
            }
        }

        if runLen >= needed {
            // Write blocks into found run
            for (i, block) in blocks.enumerated() {
                let off = dirData.startIndex + (runStart + i) * 32
                dirData.replaceSubrange(off ..< off + 32, with: block)
            }
            // No explicit sentinel needed: the 0x00 end-of-directory is already present
            // past the last live entry (either from cluster zero-init or a prior extension).
            // Writing 0x00 here when reusing a deleted-entry gap would corrupt the next
            // live entry's LFN sequence byte.
            // Write back affected clusters
            for (ci, c) in chain.enumerated() {
                let off = ci * clusterSize
                let slice = Data(dirData[dirData.startIndex + off ..< dirData.startIndex + off + clusterSize])
                try fat.writeCluster(c, data: slice)
            }
        } else {
            // No room — extend the directory chain with a new cluster
            let newCluster = try fat.allocateCluster(chainAfter: chain.last!)
            var newData = Data(count: clusterSize)
            for (i, block) in blocks.enumerated() {
                newData.replaceSubrange(i * 32 ..< i * 32 + 32, with: block)
            }
            try fat.writeCluster(newCluster, data: newData)
        }
    }

    // MARK: - Directory entry removal

    private func removeEntry(name: String, from dirCluster: UInt32) throws {
        let clusterSize = fat.bpb.bytesPerCluster
        let chain = try fat.clusterChain(startingAt: dirCluster)

        var dirData = Data(capacity: chain.count * clusterSize)
        for c in chain { dirData.append(try fat.readCluster(c)) }

        let totalSlots = dirData.count / 32
        var pendingLFNIndices: [Int] = []
        var found = false

        for i in 0 ..< totalSlots {
            let base = dirData.startIndex + i * 32
            let first = dirData[base]
            if first == 0x00 { break }
            if first == 0xE5 { pendingLFNIndices.removeAll(); continue }

            let attr = dirData[base + 11]

            if attr == FAT32Attr.lfn {
                pendingLFNIndices.append(i)
                continue
            }

            // SFN: determine the effective name (LFN if available, else 8.3)
            let effectiveName: String
            if !pendingLFNIndices.isEmpty {
                var parts: [(seq: Int, chars: String)] = []
                for idx in pendingLFNIndices {
                    let lb = dirData.startIndex + idx * 32
                    parts.append((Int(dirData[lb] & 0x3F), FAT32Entry.lfnCharsAt(dirData, base: lb)))
                }
                effectiveName = parts.sorted { $0.seq < $1.seq }.map(\.chars).joined()
            } else {
                effectiveName = FAT32Entry.decodeSFNAt(dirData, base: base)
            }

            if effectiveName.lowercased() == name.lowercased() {
                dirData[base] = 0xE5
                for idx in pendingLFNIndices { dirData[dirData.startIndex + idx * 32] = 0xE5 }
                found = true
                break
            }
            pendingLFNIndices.removeAll()
        }

        guard found else { return }

        for (ci, c) in chain.enumerated() {
            let off = ci * clusterSize
            let slice = Data(dirData[dirData.startIndex + off ..< dirData.startIndex + off + clusterSize])
            try fat.writeCluster(c, data: slice)
        }
    }

    // MARK: - Utility

    private func currentFATDate() -> UInt16 {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let y = max(0, cal.component(.year, from: now) - 1980)
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        return UInt16((y << 9) | (m << 5) | d)
    }
}
