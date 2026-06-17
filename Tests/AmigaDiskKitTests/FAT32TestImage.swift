import Foundation
@testable import AmigaDiskKit

/// Builds a minimal valid FAT32 disk image (≈ 1 MB) for integration tests.
///
/// Layout:
///   Sector 0           — MBR (one FAT32 partition at LBA 2048)
///   Sectors 1-2047     — padding (zeroes)
///   Partition start    — VBR / BPB
///   Sectors +1         — FSInfo (stub, all zeroes)
///   Sectors +4..+11    — FAT copies 1 and 2 (4 sectors each)
///   Sector +12         — cluster 2 = root directory (one cluster)
///   Sectors +13..+111  — clusters 3-101 (100 free data clusters)
///
/// BPB values:
///   bytesPerSector   = 512
///   sectorsPerCluster= 1
///   reservedSectors  = 4
///   numFATs          = 2
///   sectorsPerFAT    = 4     (4 * 128 entries = room for 128 clusters)
///   rootCluster      = 2
///   totalSectors     = 112   (4 + 2*4 + 100 data clusters)
enum FAT32TestImage {

    static let partitionLBA:    UInt32 = 2048
    static let bytesPerSector:  UInt32 = 512
    static let sectorsPerCluster: UInt32 = 1
    static let reservedSectors: UInt32 = 4
    static let numFATs:         UInt32 = 2
    static let sectorsPerFAT:   UInt32 = 4
    static let dataRegionSector: UInt32 = reservedSectors + numFATs * sectorsPerFAT  // 12
    static let clusterCount:    UInt32 = 100
    static let totalSectors:    UInt32 = dataRegionSector + clusterCount * sectorsPerCluster // 112

    static var imageSize: Int64 { Int64(partitionLBA + totalSectors) * Int64(bytesPerSector) }
    static var partitionStart: Int64 { Int64(partitionLBA) * Int64(bytesPerSector) }

    // MARK: - Factory

    /// Create a fresh minimal FAT32 image in a temporary file and return its URL.
    static func create() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fat32-test-\(ProcessInfo.processInfo.processIdentifier)-\(arc4random()).img")

        try BlockDevice.createBlank(url: url, sizeBytes: imageSize)
        let dev = try BlockDevice(url: url, readOnly: false)

        try writeMBR(to: dev)
        try writeVBR(to: dev)
        try writeFAT(to: dev)
        // Root directory cluster is already zeroed (0x00 end sentinel)

        return url
    }

    // MARK: - MBR

    private static func writeMBR(to dev: BlockDevice) throws {
        let spec = MBREntrySpec(status: 0x80, partitionType: 0x0C,
                                lbaStart: partitionLBA, lbaSectors: totalSectors)
        let block = MBRPartitionTable.serialize(entries: [spec])
        try dev.write(block, at: 0)
    }

    // MARK: - VBR / BPB

    private static func writeVBR(to dev: BlockDevice) throws {
        var vbr = Data(count: 512)

        // Jump boot
        vbr[0] = 0xEB; vbr[1] = 0x58; vbr[2] = 0x90
        // OEM name
        for (i, b) in "MSDOS5.0".utf8.enumerated() { vbr[3 + i] = b }

        // BPB common
        vbr.writeLE16(UInt16(bytesPerSector),  at: 11)
        vbr[13] = UInt8(sectorsPerCluster)
        vbr.writeLE16(UInt16(reservedSectors), at: 14)
        vbr[16] = UInt8(numFATs)
        vbr.writeLE16(0, at: 17)   // rootEntCnt = 0 (FAT32)
        vbr.writeLE16(0, at: 19)   // totSec16 = 0 (FAT32)
        vbr[21] = 0xF8              // media type
        vbr.writeLE16(0, at: 22)   // fatSz16 = 0 (FAT32)
        vbr.writeLE16(63,  at: 24) // sectorsPerTrack
        vbr.writeLE16(255, at: 26) // numHeads
        vbr.writeLE32(0, at: 28)   // hiddenSectors
        vbr.writeLE32(totalSectors, at: 32)  // TotSec32

        // FAT32 extended BPB
        vbr.writeLE32(sectorsPerFAT, at: 36) // BPB_FATSz32
        vbr.writeLE16(0, at: 40)   // extFlags
        vbr.writeLE16(0, at: 42)   // fsVersion 0.0
        vbr.writeLE32(2, at: 44)   // rootCluster = 2
        vbr.writeLE16(1, at: 48)   // fsInfoSector = 1
        vbr.writeLE16(0, at: 50)   // backupBootSector = 0 (none)

        // Boot signature + volume info
        vbr[64]  = 0x00  // driveNumber
        vbr[65]  = 0x00  // reserved1
        vbr[66]  = 0x29  // bootSig (present)
        vbr.writeLE32(0x12345678, at: 67)  // volumeID
        for (i, b) in "TEST       ".utf8.prefix(11).enumerated() { vbr[71 + i] = b }
        for (i, b) in "FAT32   ".utf8.prefix(8).enumerated()  { vbr[82 + i] = b }

        // Boot sector signature
        vbr[510] = 0x55; vbr[511] = 0xAA

        try dev.write(vbr, at: partitionStart)
    }

    // MARK: - FAT table

    private static func writeFAT(to dev: BlockDevice) throws {
        let fatBytes = Int(sectorsPerFAT) * Int(bytesPerSector)
        var fat = Data(count: fatBytes)
        // Entry 0: media type marker
        fat.writeLE32(0x0FFFFFF8, at: 0)
        // Entry 1: EOC (reserved)
        fat.writeLE32(0x0FFFFFFF, at: 4)
        // Entry 2: root directory, currently one cluster (EOC)
        fat.writeLE32(0x0FFFFFFF, at: 8)
        // Entries 3+: free (0x00000000) — already zeroed

        let fat1Offset = partitionStart + Int64(reservedSectors) * Int64(bytesPerSector)
        let fat2Offset = fat1Offset + Int64(sectorsPerFAT) * Int64(bytesPerSector)
        try dev.write(fat, at: fat1Offset)
        try dev.write(fat, at: fat2Offset)
    }
}
