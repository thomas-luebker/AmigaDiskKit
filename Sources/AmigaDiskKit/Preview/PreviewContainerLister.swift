//
//  PreviewContainerLister.swift
//  AmigaDiskKit
//
//  Produces a bounded volume/file tree for an Amiga *container* — a hard-disk
//  image (.hdf/.img), floppy ADF, or LHA archive — so the system Quick Look
//  extension can preview "what's inside" without extracting anything.
//
//  Mirrors the disk-browser's own enumeration (BlockDevice → MBR → RDB →
//  FFS/PFS3/FAT32; ADF → FFS; LHA → member list). Walks are entry- and
//  depth-bounded so a huge image yields a fast, finite preview.
//
//  Pure Foundation; the appex renders the returned `PreviewListing` to text.
//

import Foundation

public struct PreviewListing {
    public struct Node {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
        public let children: [Node]
    }

    public struct Volume {
        public let name: String
        public let kind: String          // "FFS", "PFS3", "FAT32", "ADF", "LHA"
        public let root: [Node]
        public let note: String?         // e.g. "unreadable" or "(truncated)"
        public let sizeBytes: Int64      // partition/volume capacity (0 if unknown)
        public let bootable: Bool
        public let volumeName: String?   // AmigaDOS volume label (e.g. "Workbench")
        public let freeBytes: Int64?     // free space when computable (FFS/PFS3)

        public init(name: String, kind: String, root: [Node], note: String? = nil,
                    sizeBytes: Int64 = 0, bootable: Bool = false,
                    volumeName: String? = nil, freeBytes: Int64? = nil) {
            self.name = name
            self.kind = kind
            self.root = root
            self.note = note
            self.sizeBytes = sizeBytes
            self.bootable = bootable
            self.volumeName = volumeName
            self.freeBytes = freeBytes
        }
    }

    public let title: String
    public let volumes: [Volume]
    public let truncated: Bool
}

/// High-level metadata for a rich (Suspicious Package-style) preview header:
/// what the file is, its partitions, and counts — without the full tree.
public struct PreviewInfo {
    public enum Category {
        case hardDiskImage     // Amiga RDB / PiStorm .hdf / .img
        case floppy            // .adf
        case archive           // .lha / .lzh
        case foreignDiskImage  // .img / .dmg that isn't an Amiga image
    }

    public struct Partition {
        public let name: String
        public let fsKind: String
        public let sizeBytes: Int64
        public let bootable: Bool
        public let itemCount: Int
        public let note: String?
        public let volumeName: String?
        public let freeBytes: Int64?
        public var usedBytes: Int64? { freeBytes.map { max(0, sizeBytes - $0) } }
    }

    public let category: Category
    public let fileName: String
    public let typeName: String       // "Amiga Hard Disk File", "LHA Archive", …
    public let layoutSummary: String  // "RDB · 2 partitions", "MBR + RDB (PiStorm)", …
    public let partitions: [Partition]
    public let totalItems: Int
    public let capacityBytes: Int64   // sum of partition capacities (0 if N/A)
    public let fileSizeBytes: Int64   // size of the file on disk
    public let truncated: Bool
    public let listing: PreviewListing?
}

public enum PreviewContainerLister {

    /// File extensions this lister can open.
    public static let containerExtensions: Set<String> = ["adf", "hdf", "img", "dmg", "lha", "lzh"]

    public static func isContainer(_ url: URL) -> Bool {
        containerExtensions.contains(url.pathExtension.lowercased())
    }

    /// Open `url` and produce a bounded listing. Throws only if nothing at all
    /// could be read; individual unreadable partitions are reported in-line.
    public static func list(url: URL, maxEntries: Int = 4000, maxDepth: Int = 12) throws -> PreviewListing {
        var budget = maxEntries
        let title = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "lha", "lzh":
            return listLHA(url: url, title: title, budget: &budget)
        case "adf":
            return try listADF(url: url, title: title, budget: &budget, maxDepth: maxDepth)
        default: // hdf, img
            return try listBlockImage(url: url, title: title, budget: &budget, maxDepth: maxDepth)
        }
    }

    /// Inspect a container and return rich header metadata plus a bounded
    /// listing. For `.img`/`.dmg` that isn't an Amiga image, returns a
    /// `.foreignDiskImage` info card instead of throwing.
    public static func inspect(url: URL, maxEntries: Int = 6000, maxDepth: Int = 12) throws -> PreviewInfo {
        let fileName = url.lastPathComponent
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                        as? NSNumber)?.int64Value ?? 0
        let ext = url.pathExtension.lowercased()
        let isImage = (ext == "img" || ext == "hdf" || ext == "dmg")

        let listing: PreviewListing
        do {
            listing = try list(url: url, maxEntries: maxEntries, maxDepth: maxDepth)
        } catch {
            // A .img/.dmg with no RDB/FAT is a non-Amiga disk image.
            if isImage {
                return PreviewInfo(category: .foreignDiskImage, fileName: fileName,
                                   typeName: "Disk Image", layoutSummary: "Not an Amiga disk image",
                                   partitions: [], totalItems: 0, capacityBytes: 0,
                                   fileSizeBytes: fileSize, truncated: false, listing: nil)
            }
            throw error
        }

        let parts = listing.volumes.map { vol in
            PreviewInfo.Partition(name: vol.name, fsKind: vol.kind, sizeBytes: vol.sizeBytes,
                                  bootable: vol.bootable, itemCount: countNodes(vol.root),
                                  note: vol.note, volumeName: vol.volumeName,
                                  freeBytes: vol.freeBytes)
        }
        let totalItems = parts.reduce(0) { $0 + $1.itemCount }
        let capacity = listing.volumes.reduce(Int64(0)) { $0 + $1.sizeBytes }

        let category: PreviewInfo.Category
        let typeName: String
        let layout: String
        switch ext {
        case "lha", "lzh":
            category = .archive; typeName = "LHA Archive"
            layout = "LHA archive · \(totalItems) items"
        case "adf":
            category = .floppy; typeName = "Amiga Disk (ADF)"
            layout = listing.volumes.first.map { "\($0.kind) floppy" } ?? "Amiga floppy"
        default:
            category = .hardDiskImage
            typeName = ext == "img" ? "Amiga Disk Image" : "Amiga Hard Disk File"
            let hasFAT = listing.volumes.contains { $0.kind == "FAT32" }
            let n = listing.volumes.count
            layout = hasFAT ? "MBR + RDB · \(n) partition\(n == 1 ? "" : "s") (PiStorm)"
                            : "RDB · \(n) partition\(n == 1 ? "" : "s")"
        }

        return PreviewInfo(category: category, fileName: fileName, typeName: typeName,
                           layoutSummary: layout, partitions: parts, totalItems: totalItems,
                           capacityBytes: capacity, fileSizeBytes: fileSize,
                           truncated: listing.truncated, listing: listing)
    }

    private static func countNodes(_ nodes: [Node]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes($1.children) }
    }

    // MARK: - ADF

    private static func listADF(url: URL, title: String, budget: inout Int,
                                maxDepth: Int) throws -> PreviewListing {
        let fs = try FFSFileSystem.openADF(url: url, readOnly: true)
        let info = try? fs.volumeInfo()
        let name = info?.volumeName ?? url.deletingPathExtension().lastPathComponent
        let root = walkAmiga(fs, path: "", depth: 0, budget: &budget, maxDepth: maxDepth)
        return PreviewListing(title: title,
                              volumes: [.init(name: name, kind: "ADF", root: root, note: nil,
                                              sizeBytes: info?.totalBytes ?? 0,
                                              volumeName: info?.volumeName,
                                              freeBytes: info?.freeBytes)],
                              truncated: budget <= 0)
    }

    // MARK: - Hard-disk image

    private static func listBlockImage(url: URL, title: String, budget: inout Int,
                                       maxDepth: Int) throws -> PreviewListing {
        let device = try BlockDevice(url: url, readOnly: true)
        var volumes: [PreviewListing.Volume] = []

        // MBR (PiStorm layout): FAT32 boot partitions + the RDB slice location.
        var sliceLBA: Int64 = 0
        let first = try device.readBlock(at: 0)
        if first.readBE8(at: 510) == 0x55, first.readBE8(at: 511) == 0xAA,
           let mbr = try? MBRPartitionTable(data: first) {
            for (index, entry) in mbr.partitions.enumerated() where !entry.isEmpty {
                switch entry.partitionType {
                case 0x0B, 0x0C:
                    volumes.append(listFAT(device: device, mbrIndex: index,
                                           sizeBytes: Int64(entry.lbaSectors) * 512,
                                           budget: &budget, maxDepth: maxDepth))
                case 0x76:
                    sliceLBA = Int64(entry.lbaStart)
                default:
                    break
                }
            }
        }

        // RDB Amiga partitions.
        if let rdb = try? RigidDiskBlock.scan(device: device, sliceStartLBA: sliceLBA) {
            for part in rdb.partitionBlocks {
                let size = Int64(part.highCyl - part.lowCyl + 1)
                    * Int64(rdb.blocksPerCylinder) * Int64(rdb.blockSize)
                let kind = KnownDosType.isPFS3(part.dosType) ? "PFS3"
                         : (KnownDosType.isFFS(part.dosType) || KnownDosType.isOFS(part.dosType)) ? "FFS"
                         : nil
                guard let kind else {
                    volumes.append(.init(name: part.driveName, kind: part.dosTypeFormatted,
                                         root: [], note: "unsupported filesystem",
                                         sizeBytes: size, bootable: part.isBootable))
                    continue
                }
                do {
                    let vol = try openAmigaVolume(device: device, partitionName: part.driveName,
                                                  sliceStartLBA: sliceLBA)
                    let vinfo = try? vol.volumeInfo()
                    let root = walkAmiga(vol, path: "", depth: 0, budget: &budget, maxDepth: maxDepth)
                    volumes.append(.init(name: part.driveName, kind: kind, root: root, note: nil,
                                         sizeBytes: size, bootable: part.isBootable,
                                         volumeName: vinfo?.volumeName, freeBytes: vinfo?.freeBytes))
                } catch {
                    volumes.append(.init(name: part.driveName, kind: kind, root: [],
                                         note: "unreadable", sizeBytes: size,
                                         bootable: part.isBootable))
                }
            }
        }

        guard !volumes.isEmpty else {
            throw AmigaDiskError.rdskNotFound
        }
        return PreviewListing(title: title, volumes: volumes, truncated: budget <= 0)
    }

    private static func listFAT(device: BlockDevice, mbrIndex: Int, sizeBytes: Int64,
                                budget: inout Int, maxDepth: Int) -> PreviewListing.Volume {
        do {
            let volume = try FAT32Volume(device: device, mbrIndex: mbrIndex)
            let root = walkFAT(volume, path: "/", depth: 0, budget: &budget, maxDepth: maxDepth)
            return .init(name: "BOOT", kind: "FAT32", root: root, note: nil, sizeBytes: sizeBytes)
        } catch {
            return .init(name: "BOOT", kind: "FAT32", root: [], note: "unreadable", sizeBytes: sizeBytes)
        }
    }

    // MARK: - LHA

    private static func listLHA(url: URL, title: String, budget: inout Int) -> PreviewListing {
        guard let archive = try? LHAArchive(url: url) else {
            return PreviewListing(title: title,
                                  volumes: [.init(name: title, kind: "LHA", root: [], note: "unreadable")],
                                  truncated: false)
        }
        let root = buildTree(fromLHA: archive.members, budget: &budget)
        let total = archive.members.reduce(Int64(0)) { $0 + Int64($1.originalSize) }
        return PreviewListing(title: title,
                              volumes: [.init(name: title, kind: "LHA", root: root, note: nil,
                                              sizeBytes: total)],
                              truncated: budget <= 0)
    }

    /// Synthesize a directory tree from the archive's flat member list.
    private static func buildTree(fromLHA members: [LHAMember], budget: inout Int) -> [Node] {
        final class Dir {
            var children: [String: Dir] = [:]
            var isFile = false
            var size: Int64 = 0
        }
        let rootDir = Dir()
        for m in members {
            let parts = m.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var cur = rootDir
            for (i, comp) in parts.enumerated() {
                let child = cur.children[comp] ?? { let d = Dir(); cur.children[comp] = d; return d }()
                if i == parts.count - 1, !m.isDirectory {
                    child.isFile = true
                    child.size = Int64(m.originalSize)
                }
                cur = child
            }
        }
        func convert(_ dir: Dir) -> [Node] {
            var nodes: [Node] = []
            for name in dir.children.keys.sorted(by: nameSort) {
                if budget <= 0 { break }
                budget -= 1
                let d = dir.children[name]!
                let isDir = !d.isFile || !d.children.isEmpty
                nodes.append(Node(name: name, isDirectory: isDir, size: d.size,
                                  children: isDir ? convert(d) : []))
            }
            return nodes
        }
        return convert(rootDir)
    }

    // MARK: - Generic walks

    private typealias Node = PreviewListing.Node

    private static func walkAmiga(_ vol: AmigaVolumeOperations, path: String, depth: Int,
                                  budget: inout Int, maxDepth: Int) -> [Node] {
        guard depth <= maxDepth, budget > 0,
              let entries = try? vol.listEntries(path: path) else { return [] }
        var nodes: [Node] = []
        for e in entries.sorted(by: entrySort) {
            if budget <= 0 { break }
            budget -= 1
            let childPath = path.isEmpty ? e.name : path + "/" + e.name
            let children = e.isDirectory
                ? walkAmiga(vol, path: childPath, depth: depth + 1, budget: &budget, maxDepth: maxDepth)
                : []
            nodes.append(Node(name: e.name, isDirectory: e.isDirectory,
                              size: Int64(e.byteSize), children: children))
        }
        return nodes
    }

    private static func walkFAT(_ vol: FAT32Volume, path: String, depth: Int,
                                budget: inout Int, maxDepth: Int) -> [Node] {
        guard depth <= maxDepth, budget > 0,
              let entries = try? vol.listDirectory(path) else { return [] }
        var nodes: [Node] = []
        for e in entries.sorted(by: { fatSort($0, $1) }) {
            if budget <= 0 { break }
            budget -= 1
            let childPath = path == "/" ? "/" + e.name : path + "/" + e.name
            let children = e.isDirectory
                ? walkFAT(vol, path: childPath, depth: depth + 1, budget: &budget, maxDepth: maxDepth)
                : []
            nodes.append(Node(name: e.name, isDirectory: e.isDirectory,
                              size: Int64(e.fileSize), children: children))
        }
        return nodes
    }

    // MARK: - Sorting

    private static func nameSort(_ a: String, _ b: String) -> Bool {
        a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
    private static func entrySort(_ a: AmigaVolumeEntry, _ b: AmigaVolumeEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return nameSort(a.name, b.name)
    }
    private static func fatSort(_ a: FAT32Entry, _ b: FAT32Entry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return nameSort(a.name, b.name)
    }
}

// MARK: - Rendering

public extension PreviewListing {
    /// An indented plain-text rendering of the tree, suitable for a text-based
    /// Quick Look reply.
    var plainText: String {
        var out = ""
        for volume in volumes {
            out += "📁 \(volume.name)  [\(volume.kind)]"
            if let note = volume.note { out += "  — \(note)" }
            out += "\n"
            appendNodes(volume.root, indent: 1, into: &out)
            out += "\n"
        }
        if truncated { out += "… listing truncated …\n" }
        return out.isEmpty ? "(empty)" : out
    }

    private func appendNodes(_ nodes: [Node], indent: Int, into out: inout String) {
        let pad = String(repeating: "    ", count: indent)
        for node in nodes {
            if node.isDirectory {
                out += "\(pad)\(node.name)/\n"
                appendNodes(node.children, indent: indent + 1, into: &out)
            } else {
                let size = ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
                out += "\(pad)\(node.name)  (\(size))\n"
            }
        }
    }

    /// A compact top-level overview: each volume's root entries only, with
    /// directories annotated by their immediate child count instead of being
    /// expanded. Quick Look previews are static, so a full recursive dump is
    /// overwhelming — this gives an at-a-glance summary and points users to the
    /// Disk Browser to explore. Needs the listing built with `maxDepth >= 1`
    /// so the per-folder counts are populated.
    var summaryText: String {
        var out = ""
        for volume in volumes {
            out += "\(volume.name)  [\(volume.kind)]"
            if let note = volume.note { out += "  — \(note)" }
            out += "\n"
            let dirs = volume.root.filter { $0.isDirectory }
            let files = volume.root.filter { !$0.isDirectory }
            for node in dirs {
                let n = node.children.count
                out += "    \(node.name)/" + (n > 0 ? "   (\(n) items)" : "") + "\n"
            }
            for node in files {
                let size = ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
                out += "    \(node.name)   (\(size))\n"
            }
            if dirs.isEmpty && files.isEmpty { out += "    (empty)\n" }
            out += "\n"
        }
        out += "Open in Amiga Imager’s Disk Browser to explore further."
        return out
    }
}
