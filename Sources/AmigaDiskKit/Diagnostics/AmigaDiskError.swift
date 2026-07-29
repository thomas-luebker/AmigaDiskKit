import Foundation

/// - Note: `LocalizedError` matters here. Without it, Cocoa formats a thrown
///   AmigaDiskError as "The operation couldn't be completed.
///   (AmigaDiskKit.AmigaDiskError error 0.)" — the case INDEX, with the real
///   reason discarded. Every one of these cases already carries a precise
///   `description`; this is what makes users and testers actually see it.
public enum AmigaDiskError: Error, CustomStringConvertible, LocalizedError {
    // ImageIO
    /// The image or device could not be opened at all (missing, moved, or no
    /// permission). Distinct from readFailed so the message does not talk
    /// about offsets and lengths that mean nothing for an open failure.
    case cannotOpen(path: String, reason: String)
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
    case invalidName(name: String, reason: String)
    case unsupportedDosType(UInt32)
    /// The filesystem/backend cannot perform this operation (e.g. comments on a
    /// long-filename volume, metadata edits on a read-only archive).
    case unsupportedOperation(String)

    // FAT32
    case invalidFAT32Signature(found: UInt16)
    case invalidFAT32BPB(reason: String)
    case notFAT32(reason: String)

    // Geometry
    case partitionOffsetOverflow(lowCyl: UInt32, blocksPerCylinder: UInt32, blockSize: UInt32)
    case invalidGeometry(reason: String)

    // Capacity
    case diskFull(requiredBlocks: Int, freeBlocks: Int)
    case fileTooLarge(path: String, size: Int, maxSize: UInt64)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let reason):
            return reason.isEmpty ? "cannot open \(path)" : "cannot open \(path): \(reason)"
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
        case .invalidName(let name, let reason):
            return "invalid name '\(name)': \(reason)"
        case .unsupportedDosType(let dosType):
            return "unsupported DOS type: 0x\(String(dosType, radix: 16, uppercase: true))"
        case .unsupportedOperation(let why):
            return "unsupported operation: \(why)"
        case .partitionOffsetOverflow(let lowCyl, let blocksPerCylinder, let blockSize):
            return "partition start offset overflows Int64: lowCyl=\(lowCyl) blocksPerCylinder=\(blocksPerCylinder) blockSize=\(blockSize)"
        case .invalidGeometry(let reason):
            return "invalid geometry: \(reason)"
        case .invalidFAT32Signature(let found):
            return "invalid FAT32 boot sector signature: 0x\(String(found, radix: 16, uppercase: true)) (expected 0xAA55)"
        case .invalidFAT32BPB(let reason):
            return "invalid FAT32 BPB: \(reason)"
        case .notFAT32(let reason):
            return "volume is not FAT32: \(reason)"
        case .diskFull(let requiredBlocks, let freeBlocks):
            return "partition is full: need \(requiredBlocks) block(s), \(freeBlocks) free"
        case .fileTooLarge(let path, let size, let maxSize):
            return "file too large for filesystem: '\(path)' is \(size) bytes (max \(maxSize))"
        }
    }

    /// What Cocoa shows in an alert. Same text as `description` — one wording,
    /// whether the error is printed to a log or put in front of a person.
    public var errorDescription: String? { description }
}
