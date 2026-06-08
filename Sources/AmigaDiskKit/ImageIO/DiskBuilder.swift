import Foundation

/// Specification for one RDB partition.
public struct PartitionSpec {
    public let name: String
    public let dosType: UInt32
    /// Number of cylinders to allocate. 0 = fill all remaining space (valid on last spec only).
    public let sizeCylinders: UInt32
    public let isBootable: Bool
    public let bootPriority: Int32
    /// Filesystem granularity: 1 = 512-byte blocks, 2 = 1024, 4 = 2048.
    public let sectorsPerFSBlock: UInt32

    public init(
        name: String,
        dosType: UInt32,
        sizeCylinders: UInt32 = 0,
        isBootable: Bool = false,
        bootPriority: Int32 = 0,
        sectorsPerFSBlock: UInt32 = 1
    ) {
        self.name = name
        self.dosType = dosType
        self.sizeCylinders = sizeCylinders
        self.isBootable = isBootable
        self.bootPriority = bootPriority
        self.sectorsPerFSBlock = sectorsPerFSBlock
    }
}

/// Disk layout variant.
public enum DiskLayout {
    /// Pure RDB — no MBR. Entire image is an RDB volume (Classic / MiSTer).
    case pureRDB(partitions: [PartitionSpec])

    /// MBR + RDB slice (PiStorm / Emu68 layout).
    ///
    /// - fatStartLBA:   First LBA of the FAT32 partition (typically 2048).
    /// - fatSectorCount: Size of the FAT32 partition in 512-byte sectors.
    /// - rdbStartLBA:   First LBA of the RDB slice (= fatStartLBA + fatSectorCount).
    ///                  The RDB geometry is computed over the slice only.
    case mbrPlusRDB(fatStartLBA: UInt32, fatSectorCount: UInt32,
                    rdbStartLBA: UInt32, partitions: [PartitionSpec])
}

/// High-level builder: creates a blank image and writes RDB (and optionally MBR) structures.
/// Filesystem formatting (writing DOS boot blocks) is out of scope — that is Phase 3+.
public enum DiskBuilder {

    // RDSK lives at slice LBA 0; PART blocks start at slice LBA 3.
    private static let firstPartSliceLBA: UInt32 = 3

    /// Build a disk image at `url` with the given layout.
    ///
    /// - Parameters:
    ///   - url:       Destination path (created or overwritten).
    ///   - sizeBytes: Total image size in bytes.
    ///   - layout:    Pure-RDB or MBR+RDB layout with partition specs.
    public static func build(url: URL, sizeBytes: Int64, layout: DiskLayout) throws {
        try BlockDevice.createBlank(url: url, sizeBytes: sizeBytes)
        let device = try BlockDevice(url: url)

        switch layout {
        case .pureRDB(let partitions):
            let geometry = try DiskGeometry(sizeBytes: sizeBytes)
            try writeRDB(device: device, geometry: geometry,
                         sliceStartLBA: 0, partitions: partitions)

        case .mbrPlusRDB(let fatStart, let fatCount, let rdbStart, let partitions):
            let totalSectors = UInt32(sizeBytes / 512)
            let mbrBlock = buildMBR(fatStart: fatStart, fatCount: fatCount,
                                    rdbStart: rdbStart, totalSectors: totalSectors)
            try device.writeBlock(mbrBlock, at: 0)

            let rdbSliceBytes = sizeBytes - Int64(rdbStart) * 512
            let geometry = try DiskGeometry(sizeBytes: rdbSliceBytes)
            try writeRDB(device: device, geometry: geometry,
                         sliceStartLBA: Int64(rdbStart), partitions: partitions)
        }
    }

    // MARK: - Private helpers

    private static func writeRDB(
        device: BlockDevice,
        geometry: DiskGeometry,
        sliceStartLBA: Int64,
        partitions: [PartitionSpec]
    ) throws {
        // Assign cylinder ranges to each partition spec.
        var resolved: [(spec: PartitionSpec, lowCyl: UInt32, highCyl: UInt32)] = []
        var nextLow: UInt32 = geometry.loCylinder
        for (i, spec) in partitions.enumerated() {
            let lowCyl = nextLow
            let isLast = (i == partitions.count - 1)
            let highCyl: UInt32
            if spec.sizeCylinders == 0 || isLast {
                highCyl = geometry.hiCylinder
            } else {
                let candidate = lowCyl + spec.sizeCylinders - 1
                guard candidate <= geometry.hiCylinder else {
                    throw AmigaDiskError.invalidGeometry(
                        reason: "partition '\(spec.name)' highCyl \(candidate) exceeds disk hiCylinder \(geometry.hiCylinder)")
                }
                highCyl = candidate
            }
            guard highCyl >= lowCyl else {
                throw AmigaDiskError.invalidGeometry(
                    reason: "partition '\(spec.name)' has zero-length cylinder range [\(lowCyl)–\(highCyl)]")
            }
            resolved.append((spec, lowCyl, highCyl))
            nextLow = highCyl + 1
        }

        // Compute slice-relative LBAs for each PART block.
        let partLBAs: [UInt32] = (0..<partitions.count).map { firstPartSliceLBA + UInt32($0) }

        // Write PART blocks (forward order; next-LBA pointer is known for all).
        for i in 0..<partitions.count {
            let (spec, lowCyl, highCyl) = resolved[i]
            let nextPartLBA: UInt32 = i < partitions.count - 1 ? partLBAs[i + 1] : 0xFFFFFFFF
            let part = PartitionBlock(
                name: spec.name, dosType: spec.dosType,
                lowCyl: lowCyl, highCyl: highCyl,
                geometry: geometry,
                isBootable: spec.isBootable, bootPriority: spec.bootPriority,
                sectorsPerFSBlock: spec.sectorsPerFSBlock
            )
            let blockData = part.serialize(next: nextPartLBA)
            try device.writeBlock(blockData, at: sliceStartLBA + Int64(partLBAs[i]))
        }

        // Write RDSK block at slice LBA 0.
        let rdsk = RigidDiskBlock(geometry: geometry)
        let partitionListLBA: UInt32 = partitions.isEmpty ? 0xFFFFFFFF : partLBAs[0]
        let rdskData = rdsk.serialize(partitionListLBA: partitionListLBA)
        try device.writeBlock(rdskData, at: sliceStartLBA)
    }

    /// Reinitialise the RDB partition layout in an existing image without touching other content.
    ///
    /// Writes fresh RDSK and PART blocks at `sliceStartLBA`. The rest of the image
    /// (e.g. a FAT partition before the RDB slice) is left untouched.
    /// Use this to replace hst-imager's `rdb part delete` + `rdb part add` sequence
    /// on images whose outer MBR/FAT was already created by another tool.
    ///
    /// - Parameters:
    ///   - url:            Path to the existing image file.
    ///   - sliceStartLBA:  First 512-byte block of the RDB slice within the image.
    ///   - sliceSizeBytes: Byte size of the RDB slice (image file size minus slice start).
    ///   - partitions:     Partition specs to write.
    public static func reinitPartitions(
        url: URL,
        sliceStartLBA: Int64,
        sliceSizeBytes: Int64,
        partitions: [PartitionSpec]
    ) throws {
        let device = try BlockDevice(url: url)
        let geometry = try DiskGeometry(sizeBytes: sliceSizeBytes)
        try writeRDB(device: device, geometry: geometry,
                     sliceStartLBA: sliceStartLBA, partitions: partitions)
    }

    private static func buildMBR(
        fatStart: UInt32,
        fatCount: UInt32,
        rdbStart: UInt32,
        totalSectors: UInt32
    ) -> Data {
        let rdbCount = totalSectors > rdbStart ? totalSectors - rdbStart : 0
        let entries: [MBREntrySpec] = [
            MBREntrySpec(status: 0x80, partitionType: 0x0C,
                         lbaStart: fatStart, lbaSectors: fatCount),       // FAT32 (bootable)
            MBREntrySpec(status: 0x00, partitionType: 0x76,
                         lbaStart: rdbStart, lbaSectors: rdbCount),       // Amiga RDB slice
        ]
        return MBRPartitionTable.serialize(entries: entries)
    }
}
