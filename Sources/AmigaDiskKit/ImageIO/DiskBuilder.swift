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

    // RDSK lives at slice LBA 0; default PART start for fresh builds (no pre-existing metadata).
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

    /// Highest slice-relative LBA occupied by any FSHD or LSEG block reachable
    /// from `fshdSliceLBA`. Returns 0 if the pointer is 0xFFFFFFFF or any read fails.
    private static func highestFSHDChainLBA(
        device: BlockDevice,
        sliceStartLBA: Int64,
        fshdSliceLBA: UInt32
    ) -> Int {
        FileSystemRegistrar.occupiedFSHDChainLBAs(
            device: device, sliceStartLBA: sliceStartLBA, fshdHead: fshdSliceLBA
        ).max() ?? 0
    }

    private static func writeRDB(
        device: BlockDevice,
        geometry: DiskGeometry,
        sliceStartLBA: Int64,
        partitions: [PartitionSpec],
        fileSysHdrListLBA: UInt32 = 0xFFFFFFFF,
        firstPartLBA: UInt32 = firstPartSliceLBA
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

        // Zero orphaned PART blocks in LBAs 1..<firstPartLBA.
        // hst-imager format PiStorm leaves a PART block at slice LBA 1. FSHD/LSEG blocks
        // may occupy LBAs above that — only zero blocks whose magic matches PART.
        let zeroBlock = Data(count: 512)
        for lba in 1..<Int(firstPartLBA) {
            let existing = try device.readBlock(at: sliceStartLBA + Int64(lba))
            if existing.count >= 4 && existing.readBE32(at: 0) == PartitionBlock.identifier {
                try device.writeBlock(zeroBlock, at: sliceStartLBA + Int64(lba))
            }
        }

        // Compute slice-relative LBAs for each PART block.
        let partLBAs: [UInt32] = (0..<partitions.count).map { firstPartLBA + UInt32($0) }

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
        // highRDSKBlock = highest LBA occupied by any RDB structure (FSHD/LSEG chain end is
        // firstPartLBA-1; last PART block is firstPartLBA+numParts-1; take the maximum).
        // AmigaOS uses this as an upper-bound guard when traversing linked-list pointers —
        // a value of 0 causes the ROM to ignore partitionList entries at LBAs > 0.
        let lastPartLBA = partitions.isEmpty ? 0 : partLBAs[partitions.count - 1]
        let fshdChainEnd = firstPartLBA > DiskBuilder.firstPartSliceLBA ? firstPartLBA - 1 : 0
        let highRDSKBlock = UInt32(max(Int(fshdChainEnd), Int(lastPartLBA)))
        let rdsk = RigidDiskBlock(geometry: geometry)
        let partitionListLBA: UInt32 = partitions.isEmpty ? 0xFFFFFFFF : partLBAs[0]
        let rdskData = rdsk.serialize(partitionListLBA: partitionListLBA,
                                      fileSysHdrListLBA: fileSysHdrListLBA,
                                      highRDSKBlock: highRDSKBlock)
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

        // Preserve the fileSysHdrList from the existing RDSK so FSHD/LSEG blocks
        // written by a prior tool (e.g. hst-imager format PiStorm --file-system-path)
        // remain reachable from the new RDSK.  Without this, AmigaOS has no FFS handler
        // and fails to mount the partition with "Not a DOS disk".
        // Read fileSysHdrList directly from the RDSK block — avoids the PART-chain
        // traversal in RigidDiskBlock.scan(), which throws if a hst-imager-written PART
        // block fails our checksum (different summedLongs convention), causing try? to
        // return nil and leaving existingFSHdrList = 0xFFFFFFFF.
        var existingFSHdrList: UInt32 = 0xFFFFFFFF
        if let rdskData = try? device.readBlock(at: sliceStartLBA),
           let rdsk = try? RigidDiskBlock(data: rdskData) {
            existingFSHdrList = rdsk.fileSysHdrList
        }

        // Place PART blocks after the FSHD/LSEG chain so we don't overwrite LSEG blocks.
        // hst-imager format PiStorm writes FSHD at slice LBA 2 and LSEG at LBAs 3–65
        // (63 blocks for FFS v47.4). Placing PART blocks at LBA 3 overwrites LSEGs,
        // breaking the FFS handler load and causing "Not a DOS disk" at boot.
        var firstPartLBA: UInt32 = DiskBuilder.firstPartSliceLBA
        if existingFSHdrList != 0xFFFFFFFF {
            let chainEnd = highestFSHDChainLBA(device: device,
                                               sliceStartLBA: sliceStartLBA,
                                               fshdSliceLBA: existingFSHdrList)
            if chainEnd >= Int(DiskBuilder.firstPartSliceLBA) {
                firstPartLBA = UInt32(chainEnd + 1)
            }
        }

        let geometry = try DiskGeometry(sizeBytes: sliceSizeBytes)
        try writeRDB(device: device, geometry: geometry,
                     sliceStartLBA: sliceStartLBA, partitions: partitions,
                     fileSysHdrListLBA: existingFSHdrList,
                     firstPartLBA: firstPartLBA)
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
