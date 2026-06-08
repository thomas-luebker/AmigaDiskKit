import Foundation

/// FSHD block — filesystem header in the RDB linked list.
/// Points to LSEG chain containing the filesystem binary.
public struct FileSystemHeaderBlock {
    public static let identifier: UInt32 = 0x46534844  // "FSHD"

    public let hostId: UInt32
    public let nextFileSystemHeaderBlock: UInt32  // next FSHD, or 0xFFFFFFFF
    public let flags: UInt32

    // Filesystem identification
    public let dosType: UInt32          // matches PartitionBlock.dosType it serves
    public let version: UInt32          // filesystem version (high.low)
    public let patchFlags: UInt32

    // DevNode environ fields
    public let type_: UInt32
    public let task: UInt32
    public let lock: UInt32
    public let handler: UInt32
    public let stackSize: UInt32
    public let priority: Int32
    public let startup: Int32
    public let segListBlock: UInt32     // first LSEG LBA, or 0xFFFFFFFF
    public let globalVec: UInt32

    public var versionMajor: UInt16 { UInt16(version >> 16) }
    public var versionMinor: UInt16 { UInt16(version & 0xFFFF) }
    public var versionFormatted: String { "\(versionMajor).\(versionMinor)" }

    /// Human-readable dosType, e.g. "DOS\3".
    public var dosTypeFormatted: String {
        let bytes = [
            UInt8((dosType >> 24) & 0xFF),
            UInt8((dosType >> 16) & 0xFF),
            UInt8((dosType >>  8) & 0xFF),
            UInt8( dosType        & 0xFF),
        ]
        let prefix = bytes.prefix(3).map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : "." }.joined()
        return "\(prefix)\\\(bytes[3])"
    }

    /// Filesystem name inferred from dosType.
    public var fileSystemName: String {
        switch dosType {
        case 0x444F5300, 0x444F5301, 0x444F5303, 0x444F5305, 0x444F5307: return "FastFileSystem"
        case 0x444F5302, 0x444F5304, 0x444F5306:                          return "OldFileSystem"
        case 0x50445303:                                                   return "PFS3All"
        default:                                                           return "Unknown"
        }
    }

    /// Parse an FSHD block from 512-byte block data.
    public init(data: Data, lba: UInt32) throws {
        guard data.count >= 512 else {
            throw AmigaDiskError.readFailed(offset: Int64(lba) * 512, length: 512,
                                            reason: "FSHD block too short")
        }
        // We do NOT require a valid checksum for FSHD in Phase 1 (just read it).
        // Some fixtures may have truncated LSEG chains.

        hostId                    = data.readBE32(at: 0x0C)
        nextFileSystemHeaderBlock = data.readBE32(at: 0x10)
        flags                     = data.readBE32(at: 0x14)

        dosType    = data.readBE32(at: 0x20)
        version    = data.readBE32(at: 0x24)
        patchFlags = data.readBE32(at: 0x28)
        type_      = data.readBE32(at: 0x2C)
        task       = data.readBE32(at: 0x30)
        lock       = data.readBE32(at: 0x34)
        handler    = data.readBE32(at: 0x38)
        stackSize  = data.readBE32(at: 0x3C)
        priority   = Int32(bitPattern: data.readBE32(at: 0x40))
        startup    = Int32(bitPattern: data.readBE32(at: 0x44))
        segListBlock = data.readBE32(at: 0x48)
        globalVec  = data.readBE32(at: 0x4C)
    }
}

/// LSEG block — one segment of the filesystem binary.
/// Multiple LSEG blocks form a linked list that reconstructs the loadable binary.
public struct LoadSegBlock {
    public static let identifier: UInt32 = 0x4C534547  // "LSEG"

    public let hostId: UInt32
    public let nextLoadSegBlock: UInt32  // next LSEG, or 0xFFFFFFFF
    public let data: Data               // filesystem binary segment
}
