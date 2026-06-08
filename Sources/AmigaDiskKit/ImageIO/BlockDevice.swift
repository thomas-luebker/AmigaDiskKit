import Foundation

/// Aligned, Int64-offset block-level I/O over a flat image file.
/// All offsets are Int64 end-to-end — no UInt32 arithmetic anywhere in this layer.
public final class BlockDevice {
    public let blockSize: Int
    private let handle: FileHandle

    public var size: Int64 {
        get throws {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            return Int64(bitPattern: end)
        }
    }

    public init(url: URL, blockSize: Int = 512, readOnly: Bool = false) throws {
        let h: FileHandle? = readOnly
            ? (try? FileHandle(forReadingFrom: url))
            : (try? FileHandle(forUpdating: url))
        guard let h else {
            throw AmigaDiskError.readFailed(offset: 0, length: 0, reason: "cannot open \(url.path)")
        }
        self.handle = h
        self.blockSize = blockSize
    }

    deinit { try? handle.close() }

    /// Create a new blank (zero-filled) image file of exactly `sizeBytes`.
    /// Throws if the file cannot be created or sized.
    public static func createBlank(url: URL, sizeBytes: Int64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AmigaDiskError.writeFailed(offset: 0, length: Int(sizeBytes),
                                             reason: "cannot create file at \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bitPattern: sizeBytes))
    }

    public func read(at offset: Int64, length: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(bitPattern: offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw AmigaDiskError.readFailed(offset: offset, length: length, reason: "short read")
        }
        return data
    }

    public func readBlock(at lba: Int64) throws -> Data {
        try read(at: lba * Int64(blockSize), length: blockSize)
    }

    public func write(_ data: Data, at offset: Int64) throws {
        try handle.seek(toOffset: UInt64(bitPattern: offset))
        try handle.write(contentsOf: data)
    }

    public func writeBlock(_ data: Data, at lba: Int64) throws {
        precondition(data.count == blockSize, "block must be exactly \(blockSize) bytes")
        try write(data, at: lba * Int64(blockSize))
    }
}
