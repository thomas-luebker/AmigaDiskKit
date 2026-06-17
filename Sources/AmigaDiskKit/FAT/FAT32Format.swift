import Foundation

/// FAT32 formatter (mkfs), ported from hst-imager's
/// `Hst.Imager.Core.FileSystems.Fat32.Fat32Formatter` (itself following the
/// Ridgecrop fat32format algorithm). Output is byte-compatible with the FAT
/// volumes hst-imager's PiStorm preset creates, modulo volume id and the
/// volume-label entry timestamp (wall clock).
public enum FAT32Formatter {

    public static let reservedSectorCount: UInt32 = 32
    public static let numberOfFats: UInt32 = 2
    public static let backupBootSector: UInt32 = 6

    /// Format the byte range [partitionOffset, partitionOffset+sizeBytes) as FAT32.
    ///
    /// - Parameters:
    ///   - sectorsPerTrack/numberOfHeads: CHS values stored in the BPB only;
    ///     ignored by LBA-era consumers (fat95, Linux, macOS).
    ///   - volumeId: nil derives one from `now` (DOS serial-number recipe).
    ///   - clusterSize: bytes per cluster; 0 picks the size-based optimum.
    public static func format(
        device: BlockDevice,
        partitionOffset: Int64,
        sizeBytes: Int64,
        volumeLabel: String,
        now: Date = Date(),
        volumeId: UInt32? = nil,
        sectorsPerTrack: UInt16 = 63,
        numberOfHeads: UInt16 = 255,
        clusterSize: Int = 0
    ) throws {
        let bytesPerSector = 512
        guard clusterSize >= 0, clusterSize <= 65536, clusterSize % 512 == 0 else {
            throw AmigaDiskError.invalidGeometry(reason: "FAT32 format: invalid cluster size \(clusterSize)")
        }
        let sectorCount = UInt64(sizeBytes) / UInt64(bytesPerSector)
        guard sectorCount >= 65536 else {
            throw AmigaDiskError.invalidGeometry(
                reason: "FAT32 requires at least 65536 sectors (got \(sectorCount))")
        }
        guard sectorCount < 0xFFFF_FFFF else {
            throw AmigaDiskError.invalidGeometry(reason: "FAT32 supports at most 2^32-1 sectors")
        }

        let sectorsPerCluster = UInt32(clusterSize > 0
            ? clusterSize / bytesPerSector
            : optimalSectorsPerCluster(sizeBytes: sizeBytes))
        let fatSizeInSectors = calculateFatSizeSectors(
            sectorCount: UInt32(sectorCount), reservedSectorCount: reservedSectorCount,
            sectorsPerCluster: sectorsPerCluster, numFats: numberOfFats,
            bytesPerSector: UInt32(bytesPerSector))

        let dataAreaSize = UInt32(sectorCount) - reservedSectorCount - numberOfFats * fatSizeInSectors
        let clusterCount = dataAreaSize / sectorsPerCluster
        guard clusterCount >= 65536 else {
            throw AmigaDiskError.invalidGeometry(
                reason: "FAT32 requires at least 65536 clusters (got \(clusterCount)); use a smaller cluster size")
        }
        guard clusterCount <= 0x0FFF_FFFF else {
            throw AmigaDiskError.invalidGeometry(
                reason: "FAT32 supports at most 2^28 clusters (got \(clusterCount)); use a larger cluster size")
        }
        let fatSectorsRequired = (clusterCount * 4 + UInt32(bytesPerSector) - 1) / UInt32(bytesPerSector)
        guard fatSectorsRequired <= fatSizeInSectors else {
            throw AmigaDiskError.invalidGeometry(reason: "FAT32 format: partition too large to handle")
        }

        let label = makeValidVolumeLabel(volumeLabel)

        // boot sector (BPB)
        var boot = Data(count: bytesPerSector)
        boot[boot.startIndex + 0] = 0xEB; boot[boot.startIndex + 1] = 0x58; boot[boot.startIndex + 2] = 0x90
        boot.replaceSubrange(boot.startIndex + 3 ..< boot.startIndex + 11, with: "MSWIN4.1".data(using: .ascii)!)
        boot.writeLE16(UInt16(bytesPerSector), at: 0x0B)
        boot[boot.startIndex + 0x0D] = UInt8(sectorsPerCluster)
        boot.writeLE16(UInt16(reservedSectorCount), at: 0x0E)
        boot[boot.startIndex + 0x10] = UInt8(numberOfFats)
        // wRootEntCnt(0x11), wTotSec16(0x13), wFATSz16(0x16) stay 0 for FAT32
        boot[boot.startIndex + 0x15] = 0xF8                       // media
        boot.writeLE16(sectorsPerTrack, at: 0x18)
        boot.writeLE16(numberOfHeads, at: 0x1A)
        boot.writeLE32(UInt32(partitionOffset / Int64(bytesPerSector)), at: 0x1C)  // hidden sectors
        boot.writeLE32(UInt32(sectorCount), at: 0x20)
        boot.writeLE32(fatSizeInSectors, at: 0x24)
        // wExtFlags(0x28), wFSVer(0x2A) stay 0
        boot.writeLE32(2, at: 0x2C)                               // root dir cluster
        boot.writeLE16(1, at: 0x30)                               // FSInfo sector
        boot.writeLE16(UInt16(backupBootSector), at: 0x32)
        boot[boot.startIndex + 0x40] = 0x80                       // drive number
        boot[boot.startIndex + 0x42] = 0x29                       // boot signature
        boot.writeLE32(volumeId ?? deriveVolumeId(now: now), at: 0x43)
        // BPB label is zero-padded (hst-imager parity); the root-directory
        // volume entry below is space-padded per the FAT spec.
        let bpbLabel = Array(label.utf8)
        boot.replaceSubrange(boot.startIndex + 0x47 ..< boot.startIndex + 0x47 + bpbLabel.count,
                             with: bpbLabel)
        var labelBytes = bpbLabel
        while labelBytes.count < 11 { labelBytes.append(0x20) }
        boot.replaceSubrange(boot.startIndex + 0x52 ..< boot.startIndex + 0x5A,
                             with: "FAT32   ".data(using: .ascii)!)
        boot[boot.startIndex + 0x1FE] = 0x55; boot[boot.startIndex + 0x1FF] = 0xAA

        // FSInfo sector
        var fsInfo = Data(count: bytesPerSector)
        fsInfo.writeLE32(0x4161_5252, at: 0x000)                  // lead signature
        fsInfo.writeLE32(0x6141_7272, at: 0x1E4)                  // struc signature
        fsInfo.writeLE32(clusterCount - 1, at: 0x1E8)             // free count (root uses one)
        fsInfo.writeLE32(3, at: 0x1EC)                            // next free
        fsInfo.writeLE32(0xAA55_0000, at: 0x1FC)                  // trail signature
        fsInfo[fsInfo.startIndex + 0x1FE] = 0x55; fsInfo[fsInfo.startIndex + 0x1FF] = 0xAA

        // first FAT sector: reserved clusters 0/1 + root dir EOC
        var firstFat = Data(count: bytesPerSector)
        firstFat.writeLE32(0x0FFF_FFF8, at: 0x0)
        firstFat.writeLE32(0xFFFF_FFFF, at: 0x4)
        firstFat.writeLE32(0x0FFF_FFFF, at: 0x8)

        // zero the system area (reserved + FATs + root dir cluster)
        let systemAreaSectors = Int(reservedSectorCount + numberOfFats * fatSizeInSectors + sectorsPerCluster)
        let zeroChunk = Data(count: 128 * bytesPerSector)
        var sectorsLeft = systemAreaSectors
        var writeOffset = partitionOffset
        while sectorsLeft > 0 {
            let sectors = min(sectorsLeft, 128)
            try device.write(zeroChunk.prefix(sectors * bytesPerSector), at: writeOffset)
            writeOffset += Int64(sectors * bytesPerSector)
            sectorsLeft -= sectors
        }

        // boot + FSInfo (primary and backup)
        for sectorStart in [UInt32(0), backupBootSector] {
            try device.write(boot, at: partitionOffset + Int64(sectorStart) * Int64(bytesPerSector))
            try device.write(fsInfo, at: partitionOffset + Int64(sectorStart + 1) * Int64(bytesPerSector))
        }
        // first sector of each FAT
        for i in 0 ..< numberOfFats {
            let sectorStart = reservedSectorCount + i * fatSizeInSectors
            try device.write(firstFat, at: partitionOffset + Int64(sectorStart) * Int64(bytesPerSector))
        }

        // volume-label entry in the root directory
        var volumeEntry = Data(count: 32)
        volumeEntry.replaceSubrange(volumeEntry.startIndex ..< volumeEntry.startIndex + 11,
                                    with: labelBytes)
        volumeEntry[volumeEntry.startIndex + 0x0B] = 0x08         // ATTR_VOLUME_ID
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone.current, from: now)
        let time = UInt16((c.hour! << 11) | (c.minute! << 5) | (c.second! / 2))
        let date = UInt16(((c.year! - 1980) << 9) | (c.month! << 5) | c.day!)
        volumeEntry.writeLE16(time, at: 0x16)
        volumeEntry.writeLE16(date, at: 0x18)
        let rootDirSector = reservedSectorCount + numberOfFats * fatSizeInSectors
        try device.write(volumeEntry, at: partitionOffset + Int64(rootDirSector) * Int64(bytesPerSector))
    }

    static func calculateFatSizeSectors(sectorCount: UInt32, reservedSectorCount: UInt32,
                                        sectorsPerCluster: UInt32, numFats: UInt32,
                                        bytesPerSector: UInt32) -> UInt32 {
        let numerator = UInt64(4) * UInt64(sectorCount - reservedSectorCount)
        let denominator = UInt64(sectorsPerCluster * bytesPerSector) + UInt64(4 * numFats)
        return UInt32(numerator / denominator) + 1
    }

    static func optimalSectorsPerCluster(sizeBytes: Int64) -> Int {
        let sizeMB = sizeBytes / (1024 * 1024)
        if sizeMB > 32768 { return 64 }   // 32 KB clusters
        if sizeMB > 16384 { return 32 }   // 16 KB
        if sizeMB > 8192 { return 16 }    // 8 KB
        if sizeMB > 512 { return 8 }      // 4 KB
        return 1
    }

    /// DOS volume-serial recipe (date/time scramble).
    static func deriveVolumeId(now: Date) -> UInt32 {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: TimeZone.current, from: now)
        let millis = Int((now.timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1000))
        let lo = (c.day! + (c.month! << 8)) + ((millis / 10) + (c.second! << 8))
        let hi = (c.minute! + (c.hour! << 8)) + c.year!
        return UInt32(truncatingIfNeeded: lo) | (UInt32(truncatingIfNeeded: hi) << 16)
    }

    static func makeValidVolumeLabel(_ label: String) -> String {
        let valid = label.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "!#$%&'()-@^_`{}~ ".unicodeScalars.contains($0)
        }
        return String(String.UnicodeScalarView(valid.prefix(11)))
    }
}
