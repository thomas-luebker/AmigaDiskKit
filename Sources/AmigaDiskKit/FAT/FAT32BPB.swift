import Foundation

/// FAT32 BIOS Parameter Block (VBR sector 0 of the FAT32 partition).
///
/// All fields are read from the on-disk layout exactly as the Microsoft
/// FAT32 specification defines them.  Byte offsets are partition-relative
/// (i.e. relative to the first sector of the FAT32 partition, not the
/// start of the disk image).
public struct FAT32BPB {

    // MARK: - BPB common fields (offsets 11-35)

    /// Bytes per logical sector.  Always 512 for Emu68/hst-imager images.
    public let bytesPerSector: UInt16       // offset 11

    /// Logical sectors per cluster.  Power of two, 1-128.
    public let sectorsPerCluster: UInt8     // offset 13

    /// Number of reserved sectors before the first FAT (includes the VBR).
    public let reservedSectorCount: UInt16  // offset 14

    /// Number of FAT copies.  Always 2 for Emu68/hst-imager images.
    public let fatCount: UInt8              // offset 16

    /// Total logical sectors in the volume (used when TotSec16 is 0).
    public let totalSectors: UInt32         // offset 32

    // MARK: - FAT32 extended BPB (offsets 36-89)

    /// Sectors per FAT table.
    public let sectorsPerFAT: UInt32        // offset 36

    /// Cluster number of the root directory.  Normally 2.
    public let rootCluster: UInt32          // offset 44

    /// Sector number (within the partition) of the FSInfo structure.
    public let fsInfoSector: UInt16         // offset 48

    /// Sector number of the backup VBR.  Normally 6.
    public let backupBootSector: UInt16     // offset 50

    // MARK: - Boot sector extension (offsets 64-89)

    /// Volume serial number.
    public let volumeID: UInt32             // offset 67

    /// Volume label (11 bytes, space-padded).
    public let volumeLabel: String          // offset 71

    // MARK: - Derived geometry

    /// Byte size of one cluster.
    public var bytesPerCluster: Int {
        Int(bytesPerSector) * Int(sectorsPerCluster)
    }

    /// Sector offset (within the partition) of FAT copy `index` (0-based).
    public func fatSectorOffset(fatIndex: Int = 0) -> UInt32 {
        UInt32(reservedSectorCount) + UInt32(fatIndex) * sectorsPerFAT
    }

    /// First sector of the data region (cluster 2) within the partition.
    public var dataRegionSector: UInt32 {
        UInt32(reservedSectorCount) + UInt32(fatCount) * sectorsPerFAT
    }

    /// Convert a cluster number to a partition-relative byte offset.
    /// Cluster numbers start at 2; clusters 0 and 1 are reserved.
    public func clusterOffset(_ cluster: UInt32) -> UInt64 {
        precondition(cluster >= 2, "cluster numbers below 2 are reserved")
        let sectorInPartition = UInt64(dataRegionSector) + UInt64(cluster - 2) * UInt64(sectorsPerCluster)
        return sectorInPartition * UInt64(bytesPerSector)
    }

    /// Total number of data clusters in the volume.
    public var clusterCount: UInt32 {
        let dataSectors = totalSectors - UInt32(dataRegionSector)
        return dataSectors / UInt32(sectorsPerCluster)
    }

    // MARK: - Parsing

    /// Parse a FAT32 BPB from the first 512 bytes of a FAT32 partition.
    /// `data` must contain at least 512 bytes, starting at the partition VBR.
    public init(data: Data) throws {
        guard data.count >= 512 else {
            throw AmigaDiskError.readFailed(offset: 0, length: 512,
                reason: "FAT32 VBR requires 512 bytes, got \(data.count)")
        }

        // Boot sector signature at bytes 510-511: 0x55 0xAA (LE16 = 0xAA55).
        let sig = data.readLE16(at: 510)
        guard sig == 0xAA55 else {
            throw AmigaDiskError.invalidFAT32Signature(found: sig)
        }

        // Common BPB fields.
        let bps  = data.readLE16(at: 11)
        let spc  = data.readBE8(at: 13)
        let rsc  = data.readLE16(at: 14)
        let nf   = data.readBE8(at: 16)
        let ts32 = data.readLE32(at: 32)

        // FAT32 discriminant checks.
        let rootEntCnt = data.readLE16(at: 17)
        let totSec16   = data.readLE16(at: 19)
        let fatSz16    = data.readLE16(at: 22)
        guard rootEntCnt == 0, totSec16 == 0, fatSz16 == 0 else {
            throw AmigaDiskError.notFAT32(
                reason: "rootEntCnt=\(rootEntCnt) totSec16=\(totSec16) fatSz16=\(fatSz16) — looks like FAT12/FAT16")
        }

        guard bps == 512 || bps == 1024 || bps == 2048 || bps == 4096 else {
            throw AmigaDiskError.invalidFAT32BPB(reason: "invalid bytesPerSector \(bps)")
        }
        guard spc > 0 && (spc & (spc - 1)) == 0 else {
            throw AmigaDiskError.invalidFAT32BPB(reason: "sectorsPerCluster \(spc) is not a power of two")
        }
        guard rsc > 0 else {
            throw AmigaDiskError.invalidFAT32BPB(reason: "reservedSectorCount is zero")
        }
        guard nf == 1 || nf == 2 else {
            throw AmigaDiskError.invalidFAT32BPB(reason: "fatCount \(nf) out of range (expected 1 or 2)")
        }

        bytesPerSector      = bps
        sectorsPerCluster   = spc
        reservedSectorCount = rsc
        fatCount            = nf
        totalSectors        = ts32

        // FAT32 extended BPB.
        sectorsPerFAT   = data.readLE32(at: 36)
        rootCluster     = data.readLE32(at: 44)
        fsInfoSector    = data.readLE16(at: 48)
        backupBootSector = data.readLE16(at: 50)

        guard sectorsPerFAT > 0 else {
            throw AmigaDiskError.invalidFAT32BPB(reason: "sectorsPerFAT is zero")
        }
        guard rootCluster >= 2 else {
            throw AmigaDiskError.invalidFAT32BPB(reason: "rootCluster \(rootCluster) < 2")
        }

        // Volume ID and label (present when BootSig == 0x29).
        volumeID = data.readLE32(at: 67)
        let labelBytes = data[data.startIndex + 71 ..< data.startIndex + 82]
        volumeLabel = String(bytes: labelBytes, encoding: .isoLatin1)?
            .trimmingCharacters(in: .init(charactersIn: " \0")) ?? ""
    }
}
