import Foundation
import AmigaDiskKit

// MARK: - Formatting helpers

private func formatBytes(_ bytes: Int64) -> String {
    let gb  = Double(bytes) / 1_000_000_000
    let gib = Double(bytes) / (1024 * 1024 * 1024)
    if gib >= 1.0 {
        return String(format: "%.1f GiB (%.1f GB)", gib, gb)
    }
    let mib = Double(bytes) / (1024 * 1024)
    return String(format: "%.0f MiB", mib)
}

private func partitionSizeBytes(part: PartitionBlock, rdb: RigidDiskBlock) -> Int64 {
    let cyls = Int64(part.highCyl) - Int64(part.lowCyl) + 1
    return cyls * Int64(rdb.blocksPerCylinder) * Int64(rdb.blockSize)
}

private extension String {
    func padded(to width: Int) -> String {
        if count >= width { return self }
        return self + String(repeating: " ", count: width - count)
    }
}

private func diskInfoCommand(imagePath: String) throws {
    let url    = URL(fileURLWithPath: imagePath)
    let device = try BlockDevice(url: url)
    let totalSize = try device.size

    print("Disk image: \(imagePath)")
    print("Total size: \(formatBytes(totalSize))")

    let firstSector = try device.readBlock(at: 0)
    let b510 = firstSector.readBE8(at: 510)
    let b511 = firstSector.readBE8(at: 511)
    let hasMBR = b510 == 0x55 && b511 == 0xAA

    if hasMBR {
        print("Partition table: MBR")
        let mbr = try MBRPartitionTable(data: firstSector)
        print("")
        print("  #  Type      LBAStart     LBASectors   Size")
        for (i, entry) in mbr.partitions.enumerated() where !entry.isEmpty {
            let sizeBytes = Int64(entry.lbaSectors) * 512
            let typeLabel: String
            switch entry.partitionType {
            case 0x0B, 0x0C: typeLabel = "FAT32"
            case 0x76:       typeLabel = "AmigaRDB"
            default:         typeLabel = String(format: "0x%02X", entry.partitionType)
            }
            let bootMark = entry.isBootable ? "*" : " "
            print("  \(bootMark)\(i + 1)  \(typeLabel.padded(to: 8))  \(String(format: "%12d  %12d", entry.lbaStart, entry.lbaSectors))   \(formatBytes(sizeBytes))")
        }
    } else {
        print("Partition table: none (pure RDB)")
    }
}

private func rdbInfoCommand(imagePath: String) throws {
    let url  = URL(fileURLWithPath: imagePath)
    let info = try DiskImage.open(url: url)
    let rdb  = info.rdb

    print("Rigid Disk Block:")
    print("  Cylinders : \(rdb.cylinders)  Heads: \(rdb.heads)  Sectors: \(rdb.sectors)")
    print("  Block size: \(rdb.blockSize)   RDB block hi: \(rdb.rdbBlockHi)")
    print("  CylBlocks : \(rdb.blocksPerCylinder)  LoCylinder: \(rdb.loCylinder)  HiCylinder: \(rdb.hiCylinder)")
    if !rdb.diskVendor.isEmpty || !rdb.diskProduct.isEmpty {
        print("  Vendor    : \(rdb.diskVendor)  Product: \(rdb.diskProduct)  Revision: \(rdb.diskRevision)")
    }

    if !rdb.fileSystemHeaders.isEmpty {
        print("")
        print("File Systems:")
        print("  #  DosType    Version  Name")
        for (i, fshd) in rdb.fileSystemHeaders.enumerated() {
            print("  \(i + 1)  \(fshd.dosTypeFormatted.padded(to: 10)) \(fshd.versionFormatted.padded(to: 7))  \(fshd.fileSystemName)")
        }
    }

    if !rdb.partitionBlocks.isEmpty {
        print("")
        print("Partitions:")
        print("  #  Name    Size             LowCyl   HighCyl  DosType    FsBlk  Boot  NoMnt  BootPri")
        for (i, part) in rdb.partitionBlocks.enumerated() {
            let sizeBytes = partitionSizeBytes(part: part, rdb: rdb)
            let sizeStr   = formatBytes(sizeBytes)
            let bootStr   = part.isBootable ? "yes" : "no"
            let mountStr  = part.noMount    ? "yes" : "no"
            print("  \(i + 1)  \(part.driveName.padded(to: 6))  \(sizeStr.padded(to: 16))  \(String(format: "%6d   %6d", part.lowCyl, part.highCyl))   \(part.dosTypeFormatted.padded(to: 10)) \(String(format: "%4d", part.fileSystemBlockSize))   \(bootStr.padded(to: 5)) \(mountStr.padded(to: 5))  \(part.bootPriority)")
        }
    }
}

// MARK: - disk rdb-build

private func parseDosTypeName(_ s: String) -> UInt32? {
    switch s.uppercased() {
    case "DOS1": return KnownDosType.dos1
    case "DOS3": return KnownDosType.dos3
    case "DOS5": return KnownDosType.dos5
    case "DOS7": return KnownDosType.dos7
    case "PDS3": return KnownDosType.pds3
    default:
        let hex = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return UInt32(hex, radix: 16)
    }
}

// name:dostype[:sizecyls[:boot[:priority[:sectorsPerFSBlock]]]]
private func parsePartitionSpec(_ s: String) -> PartitionSpec? {
    let fields = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 2, !fields[0].isEmpty else { return nil }
    guard let dosType = parseDosTypeName(fields[1]) else { return nil }
    let sizeCyls: UInt32        = fields.count > 2 ? UInt32(fields[2]) ?? 0 : 0
    let isBootable: Bool        = fields.count > 3 && (fields[3] == "boot" || fields[3] == "1")
    let priority: Int32         = fields.count > 4 ? Int32(fields[4]) ?? 0 : 0
    let sectorsPerFSBlk: UInt32 = fields.count > 5 ? UInt32(fields[5]) ?? 1 : 1
    return PartitionSpec(name: fields[0], dosType: dosType, sizeCylinders: sizeCyls,
                         isBootable: isBootable, bootPriority: priority,
                         sectorsPerFSBlock: sectorsPerFSBlk)
}

private func rdbBuildCommand(buildArgs: [String]) throws {
    guard buildArgs.count >= 2 else {
        fputs("Usage: AmigaDiskCLI disk rdb-build <image> <size-bytes> [--mbr --fat-lba N --fat-sectors N --rdb-lba N] --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]...\n", stderr)
        exit(1)
    }
    let imagePath = buildArgs[0]
    guard let sizeBytes = Int64(buildArgs[1]) else {
        fputs("rdb-build: invalid size '\(buildArgs[1])'\n", stderr); exit(1)
    }

    var isMBR = false
    var fatLBA: UInt32 = 2048
    var fatSectors: UInt32 = 0
    var rdbLBA: UInt32 = 0
    var partSpecs: [PartitionSpec] = []

    var i = 2
    while i < buildArgs.count {
        switch buildArgs[i] {
        case "--mbr":
            isMBR = true; i += 1
        case "--fat-lba":
            i += 1; guard i < buildArgs.count, let v = UInt32(buildArgs[i]) else {
                fputs("--fat-lba needs a value\n", stderr); exit(1)
            }; fatLBA = v; i += 1
        case "--fat-sectors":
            i += 1; guard i < buildArgs.count, let v = UInt32(buildArgs[i]) else {
                fputs("--fat-sectors needs a value\n", stderr); exit(1)
            }; fatSectors = v; i += 1
        case "--rdb-lba":
            i += 1; guard i < buildArgs.count, let v = UInt32(buildArgs[i]) else {
                fputs("--rdb-lba needs a value\n", stderr); exit(1)
            }; rdbLBA = v; i += 1
        case "--part":
            i += 1; guard i < buildArgs.count else {
                fputs("--part needs a spec\n", stderr); exit(1)
            }
            guard let spec = parsePartitionSpec(buildArgs[i]) else {
                fputs("rdb-build: invalid spec '\(buildArgs[i])'\n", stderr); exit(1)
            }; partSpecs.append(spec); i += 1
        default:
            fputs("rdb-build: unknown argument '\(buildArgs[i])'\n", stderr); exit(1)
        }
    }

    guard !partSpecs.isEmpty else {
        fputs("rdb-build: at least one --part is required\n", stderr); exit(1)
    }

    let layout: DiskLayout
    if isMBR {
        guard fatSectors > 0, rdbLBA > 0 else {
            fputs("rdb-build: --mbr requires --fat-sectors and --rdb-lba\n", stderr); exit(1)
        }
        layout = .mbrPlusRDB(fatStartLBA: fatLBA, fatSectorCount: fatSectors,
                              rdbStartLBA: rdbLBA, partitions: partSpecs)
    } else {
        layout = .pureRDB(partitions: partSpecs)
    }

    try DiskBuilder.build(url: URL(fileURLWithPath: imagePath), sizeBytes: sizeBytes, layout: layout)
    print("rdb-build: created \(imagePath) (\(sizeBytes) bytes, \(partSpecs.count) partition(s))")
}

// MARK: - disk rdb-reinit

private func rdbReinitCommand(args: [String]) throws {
    guard !args.isEmpty else {
        fputs("Usage: AmigaDiskCLI disk rdb-reinit <image> [--slice-lba N] --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]...\n", stderr)
        exit(1)
    }
    let imagePath = args[0]
    var explicitSliceLBA: Int64? = nil
    var partSpecs: [PartitionSpec] = []
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--slice-lba":
            i += 1; guard i < args.count, let v = Int64(args[i]) else {
                fputs("--slice-lba needs a value\n", stderr); exit(1)
            }; explicitSliceLBA = v; i += 1
        case "--part":
            i += 1; guard i < args.count else {
                fputs("--part needs a spec\n", stderr); exit(1)
            }
            guard let spec = parsePartitionSpec(args[i]) else {
                fputs("rdb-reinit: invalid spec '\(args[i])'\n", stderr); exit(1)
            }; partSpecs.append(spec); i += 1
        default:
            fputs("rdb-reinit: unknown argument '\(args[i])'\n", stderr); exit(1)
        }
    }
    guard !partSpecs.isEmpty else {
        fputs("rdb-reinit: at least one --part is required\n", stderr); exit(1)
    }

    let url = URL(fileURLWithPath: imagePath)
    let sliceLBA: Int64
    if let explicit = explicitSliceLBA {
        sliceLBA = explicit
    } else {
        let device = try BlockDevice(url: url)
        let first  = try device.readBlock(at: 0)
        if first.readBE8(at: 510) == 0x55 && first.readBE8(at: 511) == 0xAA,
           let mbr = try? MBRPartitionTable(data: first),
           let idx = mbr.partitions.firstIndex(where: { $0.partitionType == 0x76 }) {
            sliceLBA = Int64(mbr.partitions[idx].lbaStart)
        } else {
            sliceLBA = 0
        }
    }
    let fileSize  = try FileManager.default.attributesOfItem(atPath: imagePath)[.size] as! Int64
    let sliceBytes = fileSize - sliceLBA * 512
    guard sliceBytes > 0 else {
        fputs("rdb-reinit: slice-lba \(sliceLBA) leaves no space in image\n", stderr); exit(1)
    }
    try DiskBuilder.reinitPartitions(url: url, sliceStartLBA: sliceLBA,
                                     sliceSizeBytes: sliceBytes, partitions: partSpecs)
    print("rdb-reinit: rewrote RDB at slice LBA \(sliceLBA) with \(partSpecs.count) partition(s)")
}

// MARK: - disk rdb-format

private func rdbFormatCommand(formatArgs: [String]) throws {
    var imagePath  = ""
    var partName   = ""
    var volumeName = ""
    var explicitSliceLBA: Int64? = nil
    var i = 0
    while i < formatArgs.count {
        switch formatArgs[i] {
        case "--slice-lba":
            i += 1
            guard i < formatArgs.count, let v = Int64(formatArgs[i]) else {
                fputs("--slice-lba needs a value\n", stderr); exit(1)
            }; explicitSliceLBA = v; i += 1
        default:
            if imagePath.isEmpty { imagePath = formatArgs[i] }
            else if partName.isEmpty { partName = formatArgs[i] }
            else if volumeName.isEmpty { volumeName = formatArgs[i] }
            else { fputs("rdb-format: unexpected argument '\(formatArgs[i])'\n", stderr); exit(1) }
            i += 1
        }
    }
    guard !imagePath.isEmpty, !partName.isEmpty else {
        fputs("Usage: AmigaDiskCLI disk rdb-format <image> <partition-name> [<volume-name>] [--slice-lba N]\n", stderr)
        exit(1)
    }
    if volumeName.isEmpty { volumeName = partName }

    let url    = URL(fileURLWithPath: imagePath)
    let device = try BlockDevice(url: url)

    // Resolve slice LBA: explicit override, or MBR auto-detect (type 0x76), or 0 for pure RDB.
    let sliceLBA: Int64
    if let explicit = explicitSliceLBA {
        sliceLBA = explicit
    } else {
        let first = try device.readBlock(at: 0)
        if first.readBE8(at: 510) == 0x55 && first.readBE8(at: 511) == 0xAA,
           let mbr = try? MBRPartitionTable(data: first),
           let idx = mbr.partitions.firstIndex(where: { $0.partitionType == 0x76 }) {
            sliceLBA = Int64(mbr.partitions[idx].lbaStart)
        } else {
            sliceLBA = 0
        }
    }

    let rdb  = try RigidDiskBlock.scan(device: device, sliceStartLBA: sliceLBA)
    guard let part = rdb.partitionBlocks.first(where: { $0.driveName == partName }) else {
        fputs("rdb-format: partition '\(partName)' not found in \(imagePath)\n", stderr); exit(1)
    }

    let spec = FFSFormatSpec(volumeName: volumeName)
    try FFSFormatter.format(device: device, sliceStartLBA: sliceLBA, partition: part, rdb: rdb, spec: spec)
    print("rdb-format: formatted '\(partName)' as '\(volumeName)' (\(part.dosTypeFormatted))")
}

// MARK: - disk fs

private func fsFsCommand(subcommand: String, fsArgs: [String]) throws {
    var positionals: [String] = []
    var sliceLBA: Int64? = nil   // nil = auto-detect MBR+RDB; explicit --slice-lba overrides
    var isRecursive = false
    var i = 0
    while i < fsArgs.count {
        if fsArgs[i] == "--slice-lba" {
            i += 1
            guard i < fsArgs.count, let v = Int64(fsArgs[i]) else {
                fputs("disk fs: --slice-lba needs a value\n", stderr); exit(1)
            }
            sliceLBA = v; i += 1
        } else if fsArgs[i] == "--recursive" {
            isRecursive = true; i += 1
        } else { positionals.append(fsArgs[i]); i += 1 }
    }
    guard positionals.count >= 2 else {
        fputs("Usage: AmigaDiskCLI disk fs \(subcommand) <image> <partition> ...\n", stderr); exit(1)
    }
    let imageURL = URL(fileURLWithPath: positionals[0])
    let partName = positionals[1]

    switch subcommand {
    case "dir":
        let amigaPath = positionals.count > 2 ? positionals[2] : ""
        let fs      = try FFSFileSystem.open(imageURL: imageURL, partitionName: partName,
                                             sliceStartLBA: sliceLBA)
        if isRecursive {
            // Recursive listing: one relative path per line (no header).
            // Both files and directories are listed; caller filters by extension.
            let paths = try fs.listRecursive(path: amigaPath)
            for p in paths { print(p) }
        } else {
            // Single-directory listing. Also handles file paths (exit 0 = exists).
            do {
                let entries = try fs.listDirectory(path: amigaPath)
                if entries.isEmpty {
                    print("(empty)")
                } else {
                    print("  Type  Size        Name")
                    for e in entries {
                        let kind = e.isDirectory ? "DIR " : "FILE"
                        let size = e.isDirectory ? "           " : String(format: "%11d", e.byteSize)
                        print("  \(kind)  \(size)  \(e.name)")
                    }
                }
            } catch AmigaDiskError.notADirectory {
                // Path points to a file — look it up in its parent to confirm existence.
                let comps = amigaPath.components(separatedBy: "/").filter { !$0.isEmpty }
                let name  = comps.last ?? amigaPath
                let parentPath = comps.dropLast().joined(separator: "/")
                let parentEntries = (try? fs.listDirectory(path: parentPath)) ?? []
                guard let entry = parentEntries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    fputs("disk fs dir: '\(amigaPath)' not found\n", stderr); exit(1)
                }
                print("  Type  Size        Name")
                let size = String(format: "%11d", entry.byteSize)
                print("  FILE  \(size)  \(entry.name)")
            }
        }

    case "mkdir":
        guard positionals.count >= 3 else {
            fputs("Usage: AmigaDiskCLI disk fs mkdir <image> <partition> <amiga-path>\n", stderr); exit(1)
        }
        let fs = try FFSFileSystem.open(imageURL: imageURL, partitionName: partName,
                                        sliceStartLBA: sliceLBA)
        try fs.makeDirectory(path: positionals[2])
        try fs.flush()
        print("disk fs mkdir: created '\(positionals[2])'")

    case "copy":
        guard positionals.count >= 4 else {
            fputs("Usage: AmigaDiskCLI disk fs copy <image> <partition> <host-src> <amiga-dst>\n", stderr); exit(1)
        }
        let fs = try FFSFileSystem.open(imageURL: imageURL, partitionName: partName,
                                        sliceStartLBA: sliceLBA)
        try fs.copyFromHost(hostURL: URL(fileURLWithPath: positionals[2]),
                            amigaPath: positionals[3])
        try fs.flush()
        print("disk fs copy: '\(positionals[2])' → '\(positionals[3])'")

    case "extract":
        guard positionals.count >= 4 else {
            fputs("Usage: AmigaDiskCLI disk fs extract <image> <partition> <amiga-src> <host-dst>\n", stderr); exit(1)
        }
        let fs = try FFSFileSystem.open(imageURL: imageURL, partitionName: partName,
                                        sliceStartLBA: sliceLBA)
        try fs.extractToHost(amigaPath: positionals[2],
                             hostURL: URL(fileURLWithPath: positionals[3]))
        print("disk fs extract: '\(positionals[2])' → '\(positionals[3])'")

    case "delete":
        guard positionals.count >= 3 else {
            fputs("Usage: AmigaDiskCLI disk fs delete <image> <partition> <amiga-path>\n", stderr); exit(1)
        }
        let fs = try FFSFileSystem.open(imageURL: imageURL, partitionName: partName,
                                        sliceStartLBA: sliceLBA)
        try fs.delete(path: positionals[2])
        try fs.flush()
        print("disk fs delete: '\(positionals[2])'")

    default:
        fputs("disk fs: unknown subcommand '\(subcommand)'\n", stderr); exit(1)
    }
}

// MARK: - Entry point

let args = CommandLine.arguments

func usage() -> Never {
    let prog = URL(fileURLWithPath: args[0]).lastPathComponent
    print("Usage:")
    print("  \(prog) disk info <image-path>                              — disk size and partition table")
    print("  \(prog) disk rdb-info <image-path>                         — RDSK geometry, FSHD, PART list")
    print("  \(prog) disk rdb-build <image> <size> [--mbr ...]          — create blank image with RDB")
    print("         --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]")
    print("  \(prog) disk rdb-reinit <image> [--slice-lba N] --part ... — rewrite RDB in existing image")
    print("  \(prog) disk rdb-format <image> <part> [<vol>] [--slice-lba N]  — FFS format a partition")
    print("  \(prog) disk fs dir     <image> <part> [<path>] [--recursive] [--slice-lba N] — list directory")
    print("  \(prog) disk fs mkdir   <image> <part> <path>  [--slice-lba N] — create directories")
    print("  \(prog) disk fs copy    <image> <part> <host-src> <amiga-dst> [--slice-lba N] — copy to image")
    print("  \(prog) disk fs extract <image> <part> <amiga-src> <host-dst> [--slice-lba N] — extract from image")
    exit(1)
}

guard args.count >= 3 else { usage() }

if args[1] == "adf" && args.count >= 5 && args[2] == "extract" {
    do {
        let fs = try FFSFileSystem.openADF(url: URL(fileURLWithPath: args[3]))
        try fs.extractToHost(amigaPath: "", hostURL: URL(fileURLWithPath: args[4]))
        print("adf extract: '\(args[3])' → '\(args[4])'")
    } catch {
        fputs("adf extract: \(error)\n", stderr); exit(2)
    }
    exit(0)
}

guard args[1] == "disk" else { usage() }

let subcommand = args[2]

do {
    switch subcommand {
    case "info":
        guard args.count >= 4 else { usage() }
        try diskInfoCommand(imagePath: args[3])
    case "rdb-info":
        guard args.count >= 4 else { usage() }
        try rdbInfoCommand(imagePath: args[3])
    case "rdb-build":
        try rdbBuildCommand(buildArgs: Array(args.dropFirst(3)))
    case "rdb-reinit":
        try rdbReinitCommand(args: Array(args.dropFirst(3)))
    case "rdb-format":
        try rdbFormatCommand(formatArgs: Array(args.dropFirst(3)))
    case "fs":
        guard args.count >= 4 else { usage() }
        try fsFsCommand(subcommand: args[3], fsArgs: Array(args.dropFirst(4)))
    default:
        usage()
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(2)
}
