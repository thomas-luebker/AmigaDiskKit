//
//  ToolingSupport.swift
//  AmigaDiskKit
//
//  Shared error type and byte helpers for the Tooling namespaces
//  (IconPatcher, PrefsPatcher, TextTransform, FilenameSanitizer).
//
//  The byte helpers are bounds-TOLERANT (out-of-range reads return 0, writes
//  no-op) — moved verbatim from amiga-tools' main.swift, where years of field
//  hardening relied on these semantics. Do not replace them with the module's
//  assertive Data extensions.
//

import Foundation

/// Errors thrown by the Tooling namespaces. Descriptions match the historical
/// amiga-tools CLI error strings so the CLI shim can print them verbatim.
public enum ToolingError: Error, CustomStringConvertible {
    case cannotRead(String)
    case cannotWrite(String)
    case invalidFormat(String)
    case invalidPattern(String)
    case enumerationFailed(String)

    public var description: String {
        switch self {
        case .cannotRead(let path):       return "Cannot read: \(path)"
        case .cannotWrite(let path):      return "Cannot write: \(path)"
        case .invalidFormat(let message): return message
        case .invalidPattern(let p):      return "invalid pattern: \(p)"
        case .enumerationFailed(let dir): return "Cannot enumerate: \(dir)"
        }
    }
}

// MARK: - Text reading (UTF-8 first, Latin-1 fallback — historical CLI behavior)

func toolingReadTextFile(_ path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
    return try? String(contentsOf: url, encoding: .isoLatin1)
}

// MARK: - Bounds-tolerant big-endian helpers

func toolingReadBE16(_ data: Data, at offset: Int) -> UInt16 {
    guard data.count >= offset + 2 else { return 0 }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

func toolingWriteBE16(_ data: inout Data, at offset: Int, value: UInt16) {
    guard data.count >= offset + 2 else { return }
    data[offset]     = UInt8((value >> 8) & 0xFF)
    data[offset + 1] = UInt8(value & 0xFF)
}

func toolingReadBE32(_ data: Data, at offset: Int) -> UInt32 {
    guard data.count >= offset + 4 else { return 0 }
    return UInt32(data[offset])     << 24
         | UInt32(data[offset + 1]) << 16
         | UInt32(data[offset + 2]) << 8
         | UInt32(data[offset + 3])
}

func toolingBEBytes(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8)  & 0xFF),
        UInt8(value         & 0xFF)
    ])
}

func toolingWriteBE32(_ data: inout Data, at offset: Int, value: UInt32) {
    guard data.count >= offset + 4 else { return }
    data[offset]     = UInt8((value >> 24) & 0xFF)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8)  & 0xFF)
    data[offset + 3] = UInt8(value         & 0xFF)
}
