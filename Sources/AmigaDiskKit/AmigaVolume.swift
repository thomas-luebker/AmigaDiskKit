import Foundation

/// True when file content is a binary load file rather than a text script:
/// an AmigaOS hunk executable (0x000003F3) or a foreign ELF (0x7F 'E' 'L' 'F').
///
/// The Amiga script protection bit must never be set on these. A foreign
/// binary (e.g. the PPC/x86 `aget.os4` / `aget.mos` shipped beside 68k tools)
/// fails LoadSeg — and with the script bit set, the shell then interprets the
/// raw binary as a script, spraying "Please insert volume <garbage>"
/// requesters for every byte sequence that looks like `name:`.
func isBinaryLoadFile(_ data: Data) -> Bool {
    guard data.count >= 4 else { return false }
    let magic = data.readBE32(at: 0)
    return magic == 0x0000_03F3 || magic == 0x7F45_4C46
}

/// Filesystem-agnostic view of one RDB partition entry.
public struct AmigaVolumeEntry {
    public let name: String
    public let isDirectory: Bool
    public let byteSize: Int
    /// Raw AmigaDOS protection bits (RWED stored active-low on FFS; raw value
    /// passed through unchanged). 0 when the engine has no protection data.
    public let protection: UInt32
    /// Last-modification (FFS) / creation (PFS3) date; nil when unknown.
    public let modified: Date?
    public let comment: String

    public init(name: String, isDirectory: Bool, byteSize: Int,
                protection: UInt32 = 0, modified: Date? = nil, comment: String = "") {
        self.name = name
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.protection = protection
        self.modified = modified
        self.comment = comment
    }
}

/// Volume-level facts for status displays.
public struct AmigaVolumeInfo {
    public let volumeName: String
    public let totalBytes: Int64
    public let freeBytes: Int64

    public init(volumeName: String, totalBytes: Int64, freeBytes: Int64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

/// Common operations over an RDB partition's filesystem, implemented by both
/// the FFS and PFS3 engines so callers can dispatch on the partition dostype.
public protocol AmigaVolumeOperations: AnyObject {
    func listEntries(path: String) throws -> [AmigaVolumeEntry]
    func listRecursive(path: String) throws -> [String]
    func makeDirectory(path: String) throws
    /// Copy a host file/tree into the partition. When `applyUaeMetadata` is set,
    /// a `<src>.uaem` sidecar (if present) supplies the Amiga protection bits
    /// instead of the POSIX-derived default; `*.uaem` files are not copied.
    func copyFromHost(hostURL: URL, amigaPath: String, applyUaeMetadata: Bool) throws
    func extractToHost(amigaPath: String, hostURL: URL) throws
    func delete(path: String) throws
    /// Rename an entry in place within its own directory. `newName` is a leaf
    /// name (no path separators); the entry's contents are preserved.
    func rename(path: String, to newName: String) throws
    func flush() throws
    func volumeInfo() throws -> AmigaVolumeInfo
}

extension FFSFileSystem: AmigaVolumeOperations {
    public func listEntries(path: String) throws -> [AmigaVolumeEntry] {
        try listDirectory(path: path).map {
            AmigaVolumeEntry(
                name: $0.name, isDirectory: $0.isDirectory, byteSize: Int($0.byteSize),
                protection: $0.protect,
                modified: ($0.days, $0.mins, $0.ticks) == (0, 0, 0)
                    ? nil
                    : AmigaDate(days: $0.days, minutes: $0.mins, ticks: $0.ticks).date,
                comment: $0.comment
            )
        }
    }
}

extension PFS3Volume: AmigaVolumeOperations {
    public func listEntries(path: String) throws -> [AmigaVolumeEntry] {
        try listDirectory(path: path).map {
            AmigaVolumeEntry(
                name: $0.name, isDirectory: $0.isDirectory, byteSize: $0.byteSize,
                protection: $0.protection,
                modified: ($0.creationDay, $0.creationMinute, $0.creationTick) == (0, 0, 0)
                    ? nil
                    : AmigaDate(days: UInt32($0.creationDay), minutes: UInt32($0.creationMinute),
                                ticks: UInt32($0.creationTick)).date,
                comment: $0.comment
            )
        }
    }
}

/// Resolve the RDB slice start: explicit value, or MBR auto-detection
/// (PiStorm images carry the RDB inside an MBR partition of type 0x76).
func resolveRDBSliceLBA(device: BlockDevice, explicit: Int64?) throws -> Int64 {
    if let explicit { return explicit }
    let first = try device.readBlock(at: 0)
    if first.readBE8(at: 510) == 0x55, first.readBE8(at: 511) == 0xAA,
       let mbr = try? MBRPartitionTable(data: first),
       let idx = mbr.partitions.firstIndex(where: { $0.partitionType == 0x76 }) {
        return Int64(mbr.partitions[idx].lbaStart)
    }
    return 0
}

/// Open the partition with the engine matching its dostype (FFS or PFS3),
/// over an already-open device (image file, or a raw device node obtained
/// e.g. via authopen). The device is shared with the returned engine.
public func openAmigaVolume(
    device: BlockDevice,
    partitionName: String,
    sliceStartLBA: Int64? = nil
) throws -> AmigaVolumeOperations {
    let sliceLBA = try resolveRDBSliceLBA(device: device, explicit: sliceStartLBA)
    let rdb = try RigidDiskBlock.scan(device: device, sliceStartLBA: sliceLBA)
    guard let part = rdb.partitionBlocks.first(where: { $0.driveName == partitionName }) else {
        throw AmigaDiskError.pathNotFound(path: partitionName)
    }
    if KnownDosType.isPFS3(part.dosType) {
        return try PFS3Volume(device: device, sliceStartLBA: sliceLBA, partition: part)
    }
    return try FFSFileSystem(device: device, sliceStartLBA: sliceLBA, partition: part, rdb: rdb)
}

/// Open the partition with the engine matching its dostype (FFS or PFS3).
public func openAmigaVolume(
    imageURL: URL,
    partitionName: String,
    sliceStartLBA: Int64? = nil,
    readOnly: Bool = false
) throws -> AmigaVolumeOperations {
    let device = try BlockDevice(url: imageURL, readOnly: readOnly)
    return try openAmigaVolume(device: device, partitionName: partitionName,
                               sliceStartLBA: sliceStartLBA)
}
