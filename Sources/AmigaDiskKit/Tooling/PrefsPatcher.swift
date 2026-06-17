//
//  PrefsPatcher.swift
//  AmigaDiskKit
//
//  IFF PREF and HUNK-binary patching, moved verbatim from amiga-tools'
//  main.swift (the CLI remains a thin shim).
//

import Foundation

public enum PrefsPatcher {

    // MARK: - WBPattern (PTRN chunk)

    /// Rewrite the first PTRN chunk in an IFF FORM/PREF file with a new
    /// backdrop path. Preserves the 23-byte header (flags + type fields);
    /// replaces the BCPL path string.
    public static func patchWBPattern(path: String, backdropPath: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let original = try? Data(contentsOf: url) else {
            throw ToolingError.cannotRead(path)
        }

        guard original.count >= 12,
              original[0..<4] == Data([0x46, 0x4F, 0x52, 0x4D]),  // "FORM"
              original[8..<12] == Data([0x50, 0x52, 0x45, 0x46])  // "PREF"
        else {
            throw ToolingError.invalidFormat("Not a valid PREF IFF file: \(path)")
        }

        let formSize = Int(toolingReadBE32(original, at: 4))

        // Locate first PTRN chunk
        var pos = 12
        var ptrnPos: Int? = nil
        while pos + 8 <= original.count, pos < 8 + formSize {
            let chunkSize = Int(toolingReadBE32(original, at: pos + 4))
            if original[pos..<pos+4] == Data([0x50, 0x54, 0x52, 0x4E]) { // "PTRN"
                ptrnPos = pos
                break
            }
            let padded = chunkSize + (chunkSize % 2)
            pos += 8 + padded
        }

        guard let ptrnPos else {
            throw ToolingError.invalidFormat("No PTRN chunk found in: \(path)")
        }

        let oldChunkSize = Int(toolingReadBE32(original, at: ptrnPos + 4))
        guard oldChunkSize >= 24 else {
            throw ToolingError.invalidFormat("PTRN chunk too small (\(oldChunkSize))")
        }

        let oldPadded = 8 + oldChunkSize + (oldChunkSize % 2)
        let header = original[(ptrnPos + 8)..<(ptrnPos + 31)]  // 23 bytes of flags/type

        let newPathBytes = backdropPath.data(using: .isoLatin1) ?? Data(backdropPath.utf8)
        let newChunkSize = 24 + newPathBytes.count
        let newPadded = 8 + newChunkSize + (newChunkSize % 2)

        var newChunk = Data()
        newChunk += Data([0x50, 0x54, 0x52, 0x4E])   // "PTRN"
        newChunk += toolingBEBytes(UInt32(newChunkSize))
        newChunk += header
        newChunk.append(UInt8(newPathBytes.count))     // BCPL length byte
        newChunk += newPathBytes
        if newChunkSize % 2 == 1 { newChunk.append(0) } // IFF pad

        var newData = original[..<ptrnPos] + newChunk + original[(ptrnPos + oldPadded)...]

        let delta = newPadded - oldPadded
        toolingWriteBE32(&newData, at: 4, value: UInt32(formSize + delta))

        do {
            try newData.write(to: url)
        } catch {
            throw ToolingError.cannotWrite(path)
        }
    }

    // MARK: - Keymap (INPT chunk)

    /// Patch the keymap name inside the INPT chunk of an IFF PREF/input.prefs
    /// file. The field is a 2-byte BE length + name bytes (padded to even
    /// size). Returns the previous keymap name.
    @discardableResult
    public static func patchKeymap(path: String, keymap: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let original = try? Data(contentsOf: url) else {
            throw ToolingError.cannotRead(path)
        }

        let inptMagic = Data([0x49, 0x4E, 0x50, 0x54]) // "INPT"
        guard let inptRange = original.range(of: inptMagic) else {
            throw ToolingError.invalidFormat("INPT chunk not found in: \(path)")
        }

        let inptPos   = inptRange.lowerBound
        let csSizeOff = inptPos + 4
        let cdOff     = csSizeOff + 4

        guard original.count >= cdOff + 2 else {
            throw ToolingError.invalidFormat("INPT chunk too small")
        }

        let oldCS  = Int(toolingReadBE32(original, at: csSizeOff))
        let oldLen = Int(UInt16(original[cdOff]) << 8 | UInt16(original[cdOff + 1]))
        let oldPadded = oldLen + (oldLen % 2)
        let oldFieldSize = 2 + oldPadded

        let oldName = String(bytes: original[(cdOff + 2)..<min(cdOff + 2 + oldLen, original.count)],
                             encoding: .ascii) ?? "?"

        let newKeyBytes = Data(keymap.utf8)
        let newLen = newKeyBytes.count
        var newField = Data()
        newField.append(UInt8(newLen >> 8))
        newField.append(UInt8(newLen & 0xFF))
        newField += newKeyBytes
        if newLen % 2 == 1 { newField.append(0) } // pad to even

        var newData = original[..<cdOff] + newField + original[(cdOff + oldFieldSize)...]

        let newCS = UInt32(oldCS - oldFieldSize + newField.count)
        toolingWriteBE32(&newData, at: csSizeOff, value: newCS)
        toolingWriteBE32(&newData, at: 4, value: UInt32(newData.count - 8))

        do {
            try newData.write(to: url)
        } catch {
            throw ToolingError.cannotWrite(path)
        }
        return oldName
    }

    // MARK: - HUNK library ln_Name patching

    /// Patch an Amiga HUNK-format library so its ln_Name registers as
    /// `newName` instead of the name embedded at compile time. Needed when
    /// copying P96 emulation.library as cybergraphics.library: the original
    /// binary registers as "emulation.library", so
    /// OpenLibrary("cybergraphics.library") does a second FindName after
    /// InitLib, finds nothing (wrong name in list), and returns NULL.
    ///
    /// Algorithm:
    ///   1. Parse HUNK_HEADER → locate HUNK_CODE block and its size field.
    ///   2. Scan HUNK_RELOC32 table for code→code relocatable sites whose
    ///      stored longword matches the current name-string offset (found by
    ///      reading the rt_Name field of the RomTag at code offset +14 from
    ///      the 4AFC word).
    ///   3. Append the new name string (padded to longword boundary) directly
    ///      before the RELOC32 block (end of code hunk data in the file).
    ///   4. Rewrite all matching reloc sites with the new code offset.
    ///   5. Update HUNK_CODE size field. RELOC32 entries need no change.
    ///
    /// Info diagnostics go to `onInfo`, errors to `onError` (the CLI shim
    /// passes stdout/stderr printers, preserving historical output exactly).
    /// Returns true on success.
    @discardableResult
    public static func patchLibraryName(
        path: String,
        newName: String,
        onInfo: (String) -> Void = { _ in },
        onError: (String) -> Void = { _ in }
    ) -> Bool {
        guard var data = FileManager.default.contents(atPath: path) else {
            onError("patch-library-name: cannot read '\(path)'"); return false
        }

        // Helpers for big-endian I/O on Data
        func readU32(_ d: Data, _ off: Int) -> UInt32 {
            guard off >= 0, off + 4 <= d.count else { return 0 }
            return (UInt32(d[off]) << 24) | (UInt32(d[off+1]) << 16) | (UInt32(d[off+2]) << 8) | UInt32(d[off+3])
        }
        func writeU32(_ d: inout Data, _ off: Int, _ val: UInt32) {
            var v = val.byteSwapped
            withUnsafeBytes(of: &v) { d.replaceSubrange(off..<off+4, with: $0) }
        }

        let HUNK_HEADER: UInt32 = 0x000003F3
        let HUNK_CODE:    UInt32 = 0x000003E9
        let HUNK_RELOC32: UInt32 = 0x000003EC

        guard readU32(data, 0) == HUNK_HEADER else {
            onError("patch-library-name: not an Amiga HUNK file"); return false
        }

        // Parse HUNK_HEADER: skip table_size, num_hunks, first, last, sizes[]
        var off = 4
        let tableSize = Int(readU32(data, off)); off += 4
        off += tableSize * 4  // named hunks (usually 0)
        let numHunks  = Int(readU32(data, off)); off += 4
        let _         = readU32(data, off); off += 4  // first_hunk
        let lastHunk  = Int(readU32(data, off)); off += 4  // last_hunk
        let numSizes  = lastHunk - 0 + 1
        off += numSizes * 4  // skip size table

        // Find the first HUNK_CODE
        var codeDataOff = -1      // file offset of first code byte
        var codeSizeOff = -1      // file offset of the size longword for HUNK_CODE
        var reloc32Off  = -1      // file offset of HUNK_RELOC32 that follows the code

        var hunkIdx = 0
        while off < data.count && hunkIdx < numHunks {
            let htype = readU32(data, off); off += 4
            if htype == HUNK_CODE {
                codeSizeOff = off
                let sizeLongs = Int(readU32(data, off)); off += 4
                codeDataOff = off
                off += sizeLongs * 4
                // RELOC32 or HUNK_END follows
                if off + 4 <= data.count {
                    let nextType = readU32(data, off)
                    if nextType == HUNK_RELOC32 { reloc32Off = off }
                }
                break
            } else if htype & 0xFFFF == HUNK_CODE & 0xFFFF {
                // Skip non-code hunks
                let sz = Int(readU32(data, off) & 0x3FFFFFFF); off += 4
                off += sz * 4
            } else {
                break
            }
            hunkIdx += 1
        }

        guard codeDataOff > 0, codeSizeOff > 0 else {
            onError("patch-library-name: HUNK_CODE not found"); return false
        }

        let codeSizeLongs = Int(readU32(data, codeSizeOff))
        let codeSizeBytes = codeSizeLongs * 4

        // Find RomTag (0x4AFC) in code — always at code offset +4 (after 4-byte jump)
        var romTagCodeOff = -1
        for i in stride(from: 0, to: codeSizeBytes - 2, by: 2) {
            let w = (UInt16(data[codeDataOff + i]) << 8) | UInt16(data[codeDataOff + i + 1])
            if w == 0x4AFC { romTagCodeOff = i; break }
        }
        guard romTagCodeOff >= 0 else {
            onError("patch-library-name: RomTag (0x4AFC) not found in code"); return false
        }

        // rt_Name is at offset +14 from RomTag — read the stored code offset
        let rtNameFieldOff = romTagCodeOff + 14  // code offset of the rt_Name longword
        let oldNameOffset  = readU32(data, codeDataOff + rtNameFieldOff)

        // Verify we can read the old name at that code offset
        let nameFileOff = codeDataOff + Int(oldNameOffset)
        guard nameFileOff < data.count else {
            onError("patch-library-name: rt_Name offset 0x\(String(oldNameOffset, radix: 16)) out of range")
            return false
        }
        var oldNameLen = 0
        while nameFileOff + oldNameLen < data.count && data[nameFileOff + oldNameLen] != 0 { oldNameLen += 1 }
        let oldName = String(bytes: data[nameFileOff..<nameFileOff+oldNameLen], encoding: .isoLatin1) ?? ""
        onInfo("patch-library-name: old ln_Name = '\(oldName)' at code offset 0x\(String(oldNameOffset, radix: 16))")

        // New name bytes, padded to long boundary
        var newBytes = Array(newName.utf8) + [0]
        while newBytes.count % 4 != 0 { newBytes.append(0) }
        let newNameOffset = UInt32(codeSizeBytes)  // appended after current code end

        // Parse RELOC32 to find all code→code sites storing oldNameOffset.
        // Guard every read — a misidentified reloc32Off (e.g. pointing at
        // HUNK_END = 0x3F2 = 1010) would otherwise loop ~1010 times past
        // end-of-data and SIGTRAP.
        var patchSites: [Int] = []  // code offsets
        if reloc32Off >= 0 {
            var roff = reloc32Off + 4  // skip HUNK_RELOC32 type
            outer: while roff + 8 <= data.count {
                let count = Int(readU32(data, roff)); roff += 4
                if count == 0 { break }
                guard roff + 4 <= data.count else { break outer }
                let hunkRef = readU32(data, roff); roff += 4
                // Ensure all `count` site longwords are present before looping
                guard count > 0, roff + count * 4 <= data.count else { break outer }
                for _ in 0..<count {
                    let site = Int(readU32(data, roff)); roff += 4
                    if hunkRef == 0 {  // code → code
                        let fileOff = codeDataOff + site
                        guard fileOff + 4 <= data.count else { continue }
                        let stored = readU32(data, fileOff)
                        if stored == oldNameOffset { patchSites.append(site) }
                    }
                }
            }
        }

        if patchSites.isEmpty {
            // Fallback: also check rt_Name field directly (in case RELOC32 uses a different hunk)
            patchSites.append(rtNameFieldOff)
        }
        onInfo("patch-library-name: patching \(patchSites.count) site(s): \(patchSites.map { "0x\(String($0, radix: 16))" })")

        // Insert newBytes before reloc32Off (end of code data in the file).
        // All patch sites are within the code block (before insertAt), so their
        // file offsets are unaffected by the insertion.
        let insertAt = reloc32Off >= 0 ? reloc32Off : codeDataOff + codeSizeBytes
        data.insert(contentsOf: newBytes, at: insertAt)

        for site in patchSites {
            writeU32(&data, codeDataOff + site, newNameOffset)
        }

        // Update HUNK_CODE size (the size field is before the code data, unaffected by insert)
        let newSizeLongs = UInt32((codeSizeBytes + newBytes.count) / 4)
        writeU32(&data, codeSizeOff, newSizeLongs)

        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            onError("patch-library-name: failed to write '\(path)': \(error)"); return false
        }
        onInfo("patch-library-name: '\(path)' patched — ln_Name now '\(newName)'")
        return true
    }
}
