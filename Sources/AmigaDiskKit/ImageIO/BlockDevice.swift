import Foundation

/// (st_dev, st_ino) identity of a regular file. Two values compare equal exactly
/// when they refer to the same on-disk file, regardless of the path used to reach it.
public struct HostFileIdentity: Equatable {
    public let dev: Int64
    public let ino: UInt64

    /// Nil if `fd` is not open on a regular file.
    public init?(fileDescriptor fd: Int32) {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        self.dev = Int64(st.st_dev)
        self.ino = st.st_ino
    }

    /// Nil if `path` does not resolve to a regular file.
    public init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        self.dev = Int64(st.st_dev)
        self.ino = st.st_ino
    }
}

/// Aligned, Int64-offset block-level I/O over a flat image file.
/// All offsets are Int64 end-to-end — no UInt32 arithmetic anywhere in this layer.
public final class BlockDevice {
    public let blockSize: Int
    public let isReadOnly: Bool
    /// Identity of the regular file backing this device; nil for device nodes.
    /// Lets copy operations refuse to read the image they are writing into.
    public let backingFileID: HostFileIdentity?
    private let handle: FileHandle
    private var cachedSize: Int64?

    public var size: Int64 {
        get throws {
            if let cachedSize { return cachedSize }
            let resolved = try resolveSize()
            cachedSize = resolved
            return resolved
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
        self.isReadOnly = readOnly
        self.backingFileID = HostFileIdentity(fileDescriptor: h.fileDescriptor)
    }

    /// Wrap an already-open descriptor (e.g. obtained via `/usr/libexec/authopen`
    /// for a raw device node the process cannot open by path). Takes ownership:
    /// the handle is closed when the device is deallocated.
    public init(fileHandle: FileHandle, blockSize: Int = 512, readOnly: Bool = false) {
        self.handle = fileHandle
        self.blockSize = blockSize
        self.isReadOnly = readOnly
        self.backingFileID = HostFileIdentity(fileDescriptor: fileHandle.fileDescriptor)
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
        guard !isReadOnly else {
            throw AmigaDiskError.writeFailed(offset: offset, length: data.count,
                                             reason: "device opened read-only")
        }
        try handle.seek(toOffset: UInt64(bitPattern: offset))
        try handle.write(contentsOf: data)
    }

    public func writeBlock(_ data: Data, at lba: Int64) throws {
        precondition(data.count == blockSize, "block must be exactly \(blockSize) bytes")
        try write(data, at: lba * Int64(blockSize))
    }

    // MARK: - Size resolution

    // From <sys/disk.h>: _IOR('d', 24, uint32_t) and _IOR('d', 25, uint64_t).
    // Swift cannot evaluate the _IOR macro; values verified against the header.
    private static let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
    private static let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419

    /// Regular files report their size via seek-to-end; character/block device
    /// nodes (e.g. /dev/rdiskN) report 0 there and need the disk ioctls.
    private func resolveSize() throws -> Int64 {
        let fd = handle.fileDescriptor

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw AmigaDiskError.readFailed(offset: 0, length: 0, reason: "fstat failed: \(String(cString: strerror(errno)))")
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFCHR || mode == S_IFBLK {
            var devBlockSize: UInt32 = 0
            var devBlockCount: UInt64 = 0
            guard ioctl(fd, Self.DKIOCGETBLOCKSIZE, &devBlockSize) == 0,
                  ioctl(fd, Self.DKIOCGETBLOCKCOUNT, &devBlockCount) == 0 else {
                throw AmigaDiskError.readFailed(offset: 0, length: 0,
                                                reason: "disk size ioctl failed: \(String(cString: strerror(errno)))")
            }
            return Int64(devBlockCount) * Int64(devBlockSize)
        }

        let end = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        return Int64(bitPattern: end)
    }
}
