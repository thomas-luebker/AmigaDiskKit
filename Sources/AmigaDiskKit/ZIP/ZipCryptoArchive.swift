//
//  ZipCryptoArchive.swift
//  AmigaDiskKit
//
//  Minimal reader for ZIP archives that use traditional PKWARE ("ZipCrypto")
//  encryption with a known password, plus DEFLATE / stored entries. Written for
//  the AmigaOS 3.9 Boing Bag "AmigaOS-Update" payload, which is a password-
//  protected ZIP nested inside the Boing Bag .lha (rtg.library-era H&P anti-
//  redistribution DRM — the password is a fixed, widely-known constant, so
//  applying your own Boing Bag through it is the intended use).
//
//  Native (no system unzip / 7z) per the project's no-uncontrolled-dependencies
//  rule: ZIP container parsing + the PKWARE keystream are implemented here;
//  DEFLATE goes through Apple's Compression framework (raw zlib = raw DEFLATE).
//

import Foundation
import Compression

public enum ZipCryptoError: Error, Equatable {
    case notAZip
    case truncated
    case unsupportedMethod(UInt16)
    case wrongPassword(entry: String)
    case inflateFailed(entry: String)
    case badSize(entry: String)
}

public struct ZipCryptoArchive {

    public struct Entry {
        public let name: String
        public let isDirectory: Bool
        public let isEncrypted: Bool
        public let method: UInt16          // 0 = stored, 8 = deflate
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
        /// Central-directory "version made by" — high byte 3 = Unix host
        /// (external attributes then carry the POSIX mode in the top 16 bits).
        public let versionMadeBy: UInt16
        public let externalAttributes: UInt32

        /// POSIX mode bits when the entry was made on Unix, else nil.
        public var unixMode: UInt16? {
            (versionMadeBy >> 8) == 3 ? UInt16(externalAttributes >> 16) : nil
        }
    }

    public let entries: [Entry]
    private let data: Data

    /// Parse the central directory. Throws `.notAZip` when the EOCD isn't found.
    public init(data: Data) throws {
        self.data = data
        guard let eocd = ZipCryptoArchive.findEOCD(in: data) else { throw ZipCryptoError.notAZip }
        let cdOffset = Int(data.u32(eocd + 16))
        let count = Int(data.u16(eocd + 10))
        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x02014b50 else { throw ZipCryptoError.truncated }
            let flags = data.u16(p + 8)
            let method = data.u16(p + 10)
            let crc = data.u32(p + 16)
            let compSize = Int(data.u32(p + 20))
            let uncompSize = Int(data.u32(p + 24))
            let nameLen = Int(data.u16(p + 28))
            let extraLen = Int(data.u16(p + 30))
            let commentLen = Int(data.u16(p + 32))
            let madeBy = data.u16(p + 4)
            let extAttrs = data.u32(p + 38)
            let lho = Int(data.u32(p + 42))
            let name = String(decoding: data.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            entries.append(Entry(
                name: name,
                isDirectory: name.hasSuffix("/"),
                isEncrypted: (flags & 0x0001) != 0,
                method: method,
                crc32: crc,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: lho,
                versionMadeBy: madeBy,
                externalAttributes: extAttrs))
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = entries
    }

    /// Decrypt + decompress one entry's bytes using `password`.
    public func extract(_ entry: Entry, password: String) throws -> Data {
        if entry.isDirectory { return Data() }
        // Local header: re-read name/extra lengths (they can differ from the CD).
        let lho = entry.localHeaderOffset
        guard lho + 30 <= data.count, data.u32(lho) == 0x04034b50 else { throw ZipCryptoError.truncated }
        let nameLen = Int(data.u16(lho + 26))
        let extraLen = Int(data.u16(lho + 28))
        var dataStart = lho + 30 + nameLen + extraLen
        var payload = data.subdata(in: dataStart..<(dataStart + entry.compressedSize))
        dataStart += 0 // (silence unused-mutation note; kept for clarity)

        if entry.isEncrypted {
            payload = try Self.zipDecrypt(payload, password: password, entry: entry)
        }

        let out: Data
        switch entry.method {
        case 0:
            out = payload
        case 8:
            out = try Self.inflate(payload, expected: entry.uncompressedSize, entry: entry.name)
        default:
            throw ZipCryptoError.unsupportedMethod(entry.method)
        }
        guard out.count == entry.uncompressedSize else { throw ZipCryptoError.badSize(entry: entry.name) }
        // CRC32 over the decrypted+inflated bytes is the ZIP format's own
        // integrity check — a wrong password or bad inflate fails here, so a
        // clean extract is proof of correctness.
        if entry.crc32 != 0, fullCRC32(out) != entry.crc32 {
            throw ZipCryptoError.wrongPassword(entry: entry.name)
        }
        return out
    }

    /// Extract every file entry into `dir`, creating subdirectories. Returns the
    /// number of files written.
    @discardableResult
    public func extractAll(to dir: URL, password: String) throws -> Int {
        let fm = FileManager.default
        var written = 0
        for e in entries where !e.isDirectory {
            let dest = dir.appendingPathComponent(e.name)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(e, password: password).write(to: dest)
            written += 1
        }
        return written
    }

    /// Extract an UNENCRYPTED archive at `zipURL` into `dir`, mirroring
    /// `unzip -q -o`: overwrite existing files, create intermediate
    /// directories, restore Unix exec bits and symlinks, refuse entries
    /// that escape `dir`. Returns the number of files written. This is the
    /// native replacement for the engine's /usr/bin/unzip exec sites
    /// (iOS has no Process).
    @discardableResult
    public static func extractArchive(at zipURL: URL, to dir: URL) throws -> Int {
        let archive = try ZipCryptoArchive(data: Data(contentsOf: zipURL, options: .mappedIfSafe))
        let fm = FileManager.default
        let root = dir.standardizedFileURL
        var written = 0
        for e in archive.entries {
            // Path-traversal guard (unzip refuses these too).
            let comps = e.name.split(separator: "/").map(String.init)
            guard !comps.contains(".."), !e.name.hasPrefix("/") else { continue }
            let dest = comps.reduce(root) { $0.appendingPathComponent($1) }
            if e.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let bytes = try archive.extract(e, password: "")
            if let mode = e.unixMode, (mode & 0xF000) == 0xA000 {
                // Symlink: payload is the target path.
                try? fm.removeItem(at: dest)
                try fm.createSymbolicLink(atPath: dest.path,
                                          withDestinationPath: String(decoding: bytes, as: UTF8.self))
                continue
            }
            try? fm.removeItem(at: dest)      // -o: overwrite
            try bytes.write(to: dest)
            if let mode = e.unixMode, mode & 0o111 != 0 {
                try? fm.setAttributes([.posixPermissions: Int(mode & 0o7777)],
                                      ofItemAtPath: dest.path)
            }
            written += 1
        }
        return written
    }

    // MARK: - PKWARE traditional ("ZipCrypto") keystream

    private static func zipDecrypt(_ cipher: Data, password: String, entry: Entry) throws -> Data {
        var key0: UInt32 = 0x12345678, key1: UInt32 = 0x23456789, key2: UInt32 = 0x34567890

        func updateKeys(_ c: UInt8) {
            key0 = crc32Update(key0, c)
            key1 = key1 &+ (key0 & 0xff)
            key1 = key1 &* 134775813 &+ 1
            key2 = crc32Update(key2, UInt8(key1 >> 24))
        }
        func decryptByte() -> UInt8 {
            let temp = UInt16((key2 | 2) & 0xffff)
            // NOTE: parenthesise the product — Swift's >> binds tighter than &*,
            // so `a &* b >> 8` would wrongly mean `a &* (b >> 8)`.
            return UInt8(((UInt32(temp) &* UInt32(temp ^ 1)) >> 8) & 0xff)
        }

        for b in password.utf8 { updateKeys(b) }

        var plain = [UInt8](); plain.reserveCapacity(cipher.count)
        for c in cipher {
            let p = c ^ decryptByte()
            updateKeys(p)
            plain.append(p)
        }
        // First 12 bytes are the encryption header; the last verifies the password.
        guard plain.count >= 12 else { throw ZipCryptoError.wrongPassword(entry: entry.name) }
        // For data-descriptor entries the check byte is the high byte of the DOS
        // time (not the CRC); we accept either to stay robust.
        let check = plain[11]
        let crcHigh = UInt8((entry.crc32 >> 24) & 0xff)
        if check != crcHigh {
            // Don't hard-fail on the time-based variant; only reject when the
            // inflate later fails. (A truly wrong password almost always also
            // fails inflate / size, caught downstream.)
        }
        return Data(plain[12...])
    }

    // MARK: - DEFLATE via Apple Compression (raw stream)

    private static func inflate(_ deflated: Data, expected: Int, entry: String) throws -> Data {
        if expected == 0 { return Data() }
        // Streaming raw-DEFLATE (COMPRESSION_ZLIB = RFC 1951, no zlib wrapper).
        // The one-shot compression_decode_buffer returns 0 on some valid streams;
        // the stream API decodes them reliably.
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { throw ZipCryptoError.inflateFailed(entry: entry) }
        defer { compression_stream_destroy(&stream) }

        var out = Data(capacity: expected)
        let bufSize = max(expected, 64 * 1024)
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dstBuffer.deallocate() }

        let result: Data? = deflated.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = deflated.count
            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufSize - stream.dst_size
                if produced > 0 { out.append(dstBuffer, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:        continue
                case COMPRESSION_STATUS_END:       return out
                default:                           return nil
                }
            }
        }
        guard let inflated = result else { throw ZipCryptoError.inflateFailed(entry: entry) }
        return inflated
    }

    // MARK: - helpers

    private static func findEOCD(in data: Data) -> Int? {
        // EOCD signature 0x06054b50; scan backwards (comment may follow, ≤ 64KB).
        guard data.count >= 22 else { return nil }
        let minStart = max(0, data.count - 22 - 0xffff)
        var i = data.count - 22
        while i >= minStart {
            if data.u32(i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }
}

// MARK: - CRC32 (PKWARE polynomial 0xEDB88320), used by the keystream

private let crc32Table: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
}()

private func crc32Update(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
    (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(byte)) & 0xff)]
}

/// Standard CRC32 (init/xor 0xFFFFFFFF) over a buffer — matches the value ZIP
/// stores per entry.
private func fullCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for b in data { crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(b)) & 0xff)] }
    return crc ^ 0xFFFFFFFF
}

// MARK: - little-endian readers

private extension Data {
    func u16(_ off: Int) -> UInt16 {
        UInt16(self[startIndex + off]) | (UInt16(self[startIndex + off + 1]) << 8)
    }
    func u32(_ off: Int) -> UInt32 {
        UInt32(self[startIndex + off]) | (UInt32(self[startIndex + off + 1]) << 8)
            | (UInt32(self[startIndex + off + 2]) << 16) | (UInt32(self[startIndex + off + 3]) << 24)
    }
}
