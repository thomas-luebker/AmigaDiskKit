public enum AmigaDiskError: Error, CustomStringConvertible {
    // ImageIO
    case readFailed(offset: Int64, length: Int, reason: String)
    case writeFailed(offset: Int64, length: Int, reason: String)
    case imageTooSmall(required: Int64, actual: Int64)

    // MBR
    case invalidMBRSignature(found: UInt16)
    case mbrPartitionOutOfBounds(index: Int)

    // RDB
    case rdskNotFound
    case rdskChecksumMismatch(block: Int, expected: Int32, calculated: Int32)
    case partitionBlockChecksumMismatch(block: UInt32)
    case rdskBlockOutOfRange(block: UInt32, rdbBlockHi: UInt32)

    // FFS
    case invalidBootBlock(dosType: [UInt8])
    case invalidRootBlock(offset: UInt32)
    case rootBlockChecksumMismatch(offset: UInt32, expected: Int32, calculated: Int32)
    case pathNotFound(path: String)
    case notADirectory(path: String)
    case notAFile(path: String)
    case entryExists(path: String)
    case unsupportedDosType(UInt32)

    // Geometry
    case partitionOffsetOverflow(lowCyl: UInt32, blocksPerCylinder: UInt32, blockSize: UInt32)
    case invalidGeometry(reason: String)

    public var description: String {
        switch self {
        case .readFailed(let offset, let length, let reason):
            return "read failed at offset \(offset), length \(length): \(reason)"
        case .writeFailed(let offset, let length, let reason):
            return "write failed at offset \(offset), length \(length): \(reason)"
        case .imageTooSmall(let required, let actual):
            return "image too small: required \(required) bytes, actual \(actual) bytes"
        case .invalidMBRSignature(let found):
            return "invalid MBR signature: 0x\(String(found, radix: 16, uppercase: true)) (expected 0xAA55)"
        case .mbrPartitionOutOfBounds(let index):
            return "MBR partition \(index) extends outside image bounds"
        case .rdskNotFound:
            return "RDSK block not found in first 16 sectors"
        case .rdskChecksumMismatch(let block, let expected, let calculated):
            return "RDSK checksum mismatch at block \(block): expected \(expected), calculated \(calculated)"
        case .partitionBlockChecksumMismatch(let block):
            return "partition block checksum mismatch at block \(block)"
        case .rdskBlockOutOfRange(let block, let rdbBlockHi):
            return "RDB block \(block) exceeds RDB block hi \(rdbBlockHi)"
        case .invalidBootBlock(let dosType):
            let hex = dosType.map { String(format: "%02x", $0) }.joined()
            return "invalid FFS boot block dos type: 0x\(hex) (expected 'DOS' prefix)"
        case .invalidRootBlock(let offset):
            return "invalid root block at offset \(offset)"
        case .rootBlockChecksumMismatch(let offset, let expected, let calculated):
            return "root block checksum mismatch at offset \(offset): expected \(expected), calculated \(calculated)"
        case .pathNotFound(let path):
            return "path not found: \(path)"
        case .notADirectory(let path):
            return "not a directory: \(path)"
        case .notAFile(let path):
            return "not a file: \(path)"
        case .entryExists(let path):
            return "entry already exists: \(path)"
        case .unsupportedDosType(let dosType):
            return "unsupported DOS type: 0x\(String(dosType, radix: 16, uppercase: true))"
        case .partitionOffsetOverflow(let lowCyl, let blocksPerCylinder, let blockSize):
            return "partition start offset overflows Int64: lowCyl=\(lowCyl) blocksPerCylinder=\(blocksPerCylinder) blockSize=\(blockSize)"
        case .invalidGeometry(let reason):
            return "invalid geometry: \(reason)"
        }
    }
}
