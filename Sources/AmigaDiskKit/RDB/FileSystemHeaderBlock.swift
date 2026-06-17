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

    /// Handler name stored at offset 0xAC (hst-imager extension; not part of the
    /// AmigaOS FileSysHeaderBlock spec, which leaves this area reserved).
    public let name: String

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
        name       = data.readAmigaString(at: 0xAC, length: 84)
    }

    /// Create an FSHD descriptor for writing. Defaults match hst-imager output
    /// (patchFlags 0x180 = dn_SegList + dn_GlobalVec valid, globalVec -1).
    public init(
        dosType: UInt32,
        version: UInt32,
        name: String = "",
        segListBlock: UInt32 = 0xFFFFFFFF,
        nextFileSystemHeaderBlock: UInt32 = 0xFFFFFFFF,
        hostId: UInt32 = 7,
        flags: UInt32 = 0,
        patchFlags: UInt32 = 0x0180,
        stackSize: UInt32 = 0,
        priority: Int32 = 0,
        startup: Int32 = 0,
        globalVec: UInt32 = 0xFFFFFFFF
    ) {
        self.dosType = dosType
        self.version = version
        self.name = name
        self.segListBlock = segListBlock
        self.nextFileSystemHeaderBlock = nextFileSystemHeaderBlock
        self.hostId = hostId
        self.flags = flags
        self.patchFlags = patchFlags
        self.stackSize = stackSize
        self.priority = priority
        self.startup = startup
        self.globalVec = globalVec
        self.type_ = 0
        self.task = 0
        self.lock = 0
        self.handler = 0
    }

    /// Serialize to a 512-byte FSHD block with a valid Amiga checksum.
    public func serialize() -> Data {
        var block = Data(count: 512)
        block.writeBE32(FileSystemHeaderBlock.identifier, at: 0x00)
        block.writeBE32(UInt32(64), at: 0x04)   // summedLongs
        // 0x08: checksum — written by embedAmigaChecksum below
        block.writeBE32(hostId,     at: 0x0C)
        block.writeBE32(nextFileSystemHeaderBlock, at: 0x10)
        block.writeBE32(flags,      at: 0x14)
        block.writeBE32(dosType,    at: 0x20)
        block.writeBE32(version,    at: 0x24)
        block.writeBE32(patchFlags, at: 0x28)
        block.writeBE32(type_,      at: 0x2C)
        block.writeBE32(task,       at: 0x30)
        block.writeBE32(lock,       at: 0x34)
        block.writeBE32(handler,    at: 0x38)
        block.writeBE32(stackSize,  at: 0x3C)
        block.writeBE32(UInt32(bitPattern: priority), at: 0x40)
        block.writeBE32(UInt32(bitPattern: startup),  at: 0x44)
        block.writeBE32(segListBlock, at: 0x48)
        block.writeBE32(globalVec,  at: 0x4C)
        block.writeAmigaString(name, at: 0xAC, length: 84)
        embedAmigaChecksum(into: &block)
        return block
    }
}

/// LSEG block — one segment of the filesystem binary.
/// Multiple LSEG blocks form a linked list that reconstructs the loadable binary.
public struct LoadSegBlock {
    public static let identifier: UInt32 = 0x4C534547  // "LSEG"

    /// Payload bytes per 512-byte LSEG block: 512 − 20-byte header
    /// (id, summedLongs, checksum, hostId, next).
    public static let payloadBytesPerBlock = 492

    public let hostId: UInt32
    public let nextLoadSegBlock: UInt32  // next LSEG, or 0xFFFFFFFF
    public let data: Data               // filesystem binary segment

    /// Serialize one LSEG block with a valid Amiga checksum.
    /// `summedLongs` covers only the header plus the actual payload longs, so a
    /// partial final block checksums exactly like hst-imager writes it.
    public static func serialize(payload: Data, next: UInt32, hostId: UInt32 = 7) -> Data {
        precondition(payload.count <= payloadBytesPerBlock, "LSEG payload exceeds 492 bytes")
        var block = Data(count: 512)
        let payloadLongs = (payload.count + 3) / 4
        block.writeBE32(LoadSegBlock.identifier, at: 0x00)
        block.writeBE32(UInt32(5 + payloadLongs), at: 0x04)
        // 0x08: checksum — written by embedAmigaChecksum below
        block.writeBE32(hostId, at: 0x0C)
        block.writeBE32(next,   at: 0x10)
        block.replaceSubrange(block.startIndex + 0x14 ..< block.startIndex + 0x14 + payload.count,
                              with: payload)
        embedAmigaChecksum(into: &block)
        return block
    }
}
