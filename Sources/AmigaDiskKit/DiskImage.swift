import Foundation

/// The partition layout of an opened disk image.
public struct DiskInfo {
    public enum Layout {
        /// MBR present; the RDB slice is at the given MBR slot index.
        case mbrPlusRDB(mbr: MBRPartitionTable, rdbSlotIndex: Int, rdb: RigidDiskBlock)
        /// No MBR; RDB starts at LBA 0 (pure-RDB / HDF / Classic image).
        case pureRDB(rdb: RigidDiskBlock)
    }

    public let layout: Layout

    /// Convenience accessor — the RDB regardless of layout.
    public var rdb: RigidDiskBlock {
        switch layout {
        case .mbrPlusRDB(_, _, let rdb): return rdb
        case .pureRDB(let rdb):          return rdb
        }
    }
}

/// Top-level disk image reader.  Opens a flat image file and auto-detects whether
/// it has an MBR (PiStorm FAT32 + RDB layout) or is a pure-RDB image (Classic /
/// MiSTer HDF).
public struct DiskImage {

    /// Open a disk image file and parse its partition structure.
    ///
    /// Detection logic:
    /// 1. Read first 512 bytes.  If bytes 510-511 == 0x55 0xAA → MBR present.
    /// 2. If MBR: find first partition entry with type 0x76 (Amiga RDB slice).
    ///    The RDB starts at `lbaStart` of that entry.
    /// 3. If no MBR (or no 0x76 entry): treat as pure-RDB, sliceStartLBA = 0.
    public static func open(url: URL) throws -> DiskInfo {
        let device = try BlockDevice(url: url)

        // Read first sector to check for MBR
        let firstSector = try device.readBlock(at: 0)

        let byte510 = firstSector.readBE8(at: 510)
        let byte511 = firstSector.readBE8(at: 511)
        let hasMBR  = byte510 == 0x55 && byte511 == 0xAA

        if hasMBR {
            let mbr = try MBRPartitionTable(data: firstSector)
            // Find first Amiga RDB partition (type 0x76)
            if let rdbIdx = mbr.partitions.firstIndex(where: { $0.partitionType == 0x76 }) {
                let rdbEntry   = mbr.partitions[rdbIdx]
                let sliceLBA   = Int64(rdbEntry.lbaStart)
                let rdb        = try RigidDiskBlock.scan(device: device, sliceStartLBA: sliceLBA)
                return DiskInfo(layout: .mbrPlusRDB(mbr: mbr, rdbSlotIndex: rdbIdx, rdb: rdb))
            }
            // MBR present but no 0x76 slot — fall through to pure-RDB scan at LBA 0
        }

        let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: 0)
        return DiskInfo(layout: .pureRDB(rdb: rdb))
    }
}
