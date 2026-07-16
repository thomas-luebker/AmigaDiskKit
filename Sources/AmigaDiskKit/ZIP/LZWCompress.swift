//
//  LZWCompress.swift
//  AmigaDiskKit
//
//  Native decoder for compress(1) `.Z` files (LZW, magic 1F 9D) — the
//  OS 3.2.x update media ship ~2,800 of them. Replaces the engine's
//  /usr/bin/uncompress exec sites (iOS has no Process; in-process decode
//  is also faster than a process spawn per file).
//
//  Ported from the BSD zopen(3) semantics /usr/bin/uncompress uses:
//  variable 9..maxbits LSB-first codes, block mode (CLEAR = 256), and the
//  bit stream padded to an 8-code group boundary at CLEAR only — never at
//  plain width changes (verified empirically against macOS compress(1)
//  output incl. a ratio-reset stream; matching uncompress is what the
//  engine's byte-parity goldens require). Historical ncompress encoders
//  pad at width changes too; decompress() retries with that variant when
//  the BSD read hits a corrupt code.
//

import Foundation

public enum LZWCompressError: Error, Equatable {
    case notCompressData
    case corrupt(String)
}

public enum LZWCompress {

    public static let magic: [UInt8] = [0x1F, 0x9D]

    /// True when `data` starts with the compress(1) magic.
    public static func isCompressData(_ data: Data) -> Bool {
        data.count >= 3 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x9D
    }

    /// Decompress a whole `.Z` payload. Tries the BSD variant (pad at
    /// CLEAR only) first, then the ncompress variant (pad at width
    /// changes too).
    public static func decompress(_ data: Data) throws -> Data {
        do { return try decompress(data, padAtWidthChange: false) }
        catch let first {
            if let padded = try? decompress(data, padAtWidthChange: true) { return padded }
            throw first
        }
    }

    static func decompress(_ data: Data, padAtWidthChange: Bool) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x1F, bytes[1] == 0x9D else {
            throw LZWCompressError.notCompressData
        }
        let flags = Int(bytes[2])
        let maxBits = flags & 0x1F
        let blockMode = (flags & 0x80) != 0
        guard (9...16).contains(maxBits) else {
            throw LZWCompressError.corrupt("maxbits \(maxBits)")
        }

        let clearCode = 256
        let firstFree = blockMode ? 257 : 256
        let maxMaxCode = 1 << maxBits

        var prefix = [Int](repeating: 0, count: maxMaxCode)
        var suffix = [UInt8](repeating: 0, count: maxMaxCode)
        for i in 0..<256 { suffix[i] = UInt8(i) }

        var nBits = 9
        var maxCode = (1 << nBits) - 1
        var freeEnt = firstFree
        var oldCode = -1
        var finChar: UInt8 = 0

        var out = Data(capacity: bytes.count * 3)
        var stack = [UInt8]()
        stack.reserveCapacity(maxMaxCode)

        let payloadStart = 3
        var posBits = 0                       // bit offset within the payload
        let totalBits = (bytes.count - payloadStart) * 8

        func alignToGroup() {
            // Round posBits up to a multiple of nBits*8 (an 8-code group).
            let group = nBits << 3
            let rem = posBits % group
            if rem != 0 { posBits += group - rem }
        }

        func readCode() -> Int? {
            guard posBits + nBits <= totalBits else { return nil }
            let byteOff = payloadStart + (posBits >> 3)
            var v = 0
            var got = 0
            var off = byteOff
            var shift = posBits & 7
            while got < nBits {
                guard off < bytes.count else { return nil }
                v |= (Int(bytes[off]) >> shift) << got
                got += 8 - shift
                shift = 0
                off += 1
            }
            posBits += nBits
            return v & ((1 << nBits) - 1)
        }

        while true {
            if freeEnt > maxCode {
                if padAtWidthChange { alignToGroup() }
                nBits += 1
                maxCode = nBits == maxBits ? maxMaxCode : (1 << nBits) - 1
            }
            guard var code = readCode() else { break }

            if code == clearCode && blockMode {
                // gzip/ncompress semantics: the table restarts one below
                // FIRST (the next growth writes a dead entry into 256's
                // slot) and oldCode is deliberately NOT reset.
                alignToGroup()
                nBits = 9
                maxCode = (1 << nBits) - 1
                freeEnt = firstFree - 1
                continue
            }

            let inCode = code
            if oldCode == -1 {
                // First code is a literal.
                guard code < 256 else { throw LZWCompressError.corrupt("first code \(code)") }
                finChar = UInt8(code)
                oldCode = code
                out.append(finChar)
                continue
            }

            if code >= freeEnt {
                // KwKwK special case.
                guard code == freeEnt else {
                    throw LZWCompressError.corrupt("code \(code) beyond table \(freeEnt)")
                }
                stack.append(finChar)
                code = oldCode
            }

            while code >= 256 {
                stack.append(suffix[code])
                code = prefix[code]
            }
            finChar = suffix[code]
            stack.append(finChar)
            out.append(contentsOf: stack.reversed())
            stack.removeAll(keepingCapacity: true)

            if freeEnt < maxMaxCode {
                prefix[freeEnt] = oldCode
                suffix[freeEnt] = finChar
                freeEnt += 1
            }
            oldCode = inCode
        }
        return out
    }

    /// Decompress `fileURL` (must end in .Z, any case) IN PLACE the way
    /// `uncompress -f` does: write the decoded bytes to the name minus
    /// `.Z` (overwriting) and remove the `.Z` file. Returns the output URL.
    @discardableResult
    public static func decompressFile(at fileURL: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoded = try decompress(data)
        let dest = fileURL.deletingPathExtension()
        try? FileManager.default.removeItem(at: dest)
        try decoded.write(to: dest)
        try FileManager.default.removeItem(at: fileURL)
        return dest
    }
}
