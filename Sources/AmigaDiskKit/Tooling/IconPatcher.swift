//
//  IconPatcher.swift
//  AmigaDiskKit
//
//  Amiga Workbench icon (.info / DiskObject) byte-level patching, moved
//  verbatim from amiga-tools' main.swift (the CLI remains a thin shim).
//  The fixed offsets and walk logic are field-hardened across OS1.x,
//  NewIcons, and GlowIcons variants — change with extreme care.
//

import Foundation

public enum IconPatcher {

    // MARK: - Borderless (FACE chunk flag)

    /// Find the "FACE" IFF chunk header, set the borderless flag (bit 0) in the
    /// flags byte at FACE+10. Returns true if the file was actually changed.
    @discardableResult
    public static func patchBorderless(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard var data = try? Data(contentsOf: url) else { return false }

        let face = Data([0x46, 0x41, 0x43, 0x45]) // "FACE"
        guard let range = data.range(of: face) else { return false }

        let flagsOff = range.lowerBound + 10
        guard flagsOff < data.count else { return false }
        guard data[flagsOff] & 0x01 == 0 else { return false } // already borderless

        data[flagsOff] |= 0x01
        try? data.write(to: url)
        return true
    }

    /// Apply patchBorderless to every .info file under a directory tree.
    /// Returns (patched, total) counts.
    @discardableResult
    public static func patchBorderlessDir(dir: String) -> (patched: Int, total: Int) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir, isDirectory: true)

        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [], errorHandler: nil) else { return (0, 0) }
        var patched = 0
        var total = 0

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "info" else { continue }
            total += 1
            if patchBorderless(path: url.path) { patched += 1 }
        }
        return (patched, total)
    }

    // MARK: - Stack size

    /// Write a big-endian UInt32 stack size into the DiskObject at offset 0x4A.
    /// Files smaller than the field are silently left unchanged (historical).
    public static func patchStack(path: String, size: UInt32) throws {
        let url = URL(fileURLWithPath: path)
        guard var data = try? Data(contentsOf: url) else {
            throw ToolingError.cannotRead(path)
        }
        let off = 0x4A
        guard data.count >= off + 4 else { return }
        data[off]     = UInt8((size >> 24) & 0xFF)
        data[off + 1] = UInt8((size >> 16) & 0xFF)
        data[off + 2] = UInt8((size >> 8)  & 0xFF)
        data[off + 3] = UInt8(size & 0xFF)
        try? data.write(to: url)
    }

    // MARK: - do_Type

    /// Patch do_Type (offset 0x30) to WBDRAWER (2). Validates magic bytes first;
    /// silently no-ops on anything that is not a DiskObject (historical).
    public static func patchTypeDrawer(path: String) {
        let url = URL(fileURLWithPath: path)
        guard var data = try? Data(contentsOf: url) else { return }
        guard data.count >= 2, data[0] == 0xE3, data[1] == 0x10 else { return } // DiskObject magic
        guard data.count > 0x30 else { return }
        data[0x30] = 0x02 // WBDRAWER = 2
        try? data.write(to: url)
    }

    /// Read the do_Type field (big-endian UInt16 at offset 0x30).
    public static func infoType(path: String) throws -> UInt16 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw ToolingError.cannotRead(path)
        }
        guard data.count >= 0x32 else {
            throw ToolingError.invalidFormat("File too small: \(path)")
        }
        return UInt16(data[0x30]) << 8 | UInt16(data[0x31])
    }

    // MARK: - DiskObject walking

    /// File offsets into the variable-length section of a DiskObject binary.
    ///
    /// Variable-data layout (after 78-byte header):
    ///   Image1 (if GadgetRender != 0):  20-byte Image struct + pixel data
    ///   Image2 (if SelectRender != 0):  same
    ///   DefaultTool (if ptr != 0):      ULONG len (incl. null) + BYTE[len]
    ///   ToolTypes (if ptr != 0):        ULONG ptrArrayBytes=(n+1)*4, then n×(ULONG len + BYTE[len])
    ///   DrawerData (if ptr != 0):       NewWindow(88 bytes) + dd_CurrentX/Y + optional dd_Flags
    public struct DiskObjectOffsets {
        public let toolTypesStart: Int?   // offset of the ptrArrayBytes ULONG
        public let toolTypesEnd: Int?     // first byte after ToolTypes block
        public let drawerDataStart: Int?  // offset of DrawerData struct
    }

    public static func walkDiskObject(_ data: Data) -> DiskObjectOffsets? {
        guard data.count >= 78, data[0] == 0xE3, data[1] == 0x10 else { return nil }

        let gadgetRender   = toolingReadBE32(data, at: 0x16)
        let selectRender   = toolingReadBE32(data, at: 0x1A)
        let defaultToolPtr = toolingReadBE32(data, at: 0x32)
        let toolTypesPtr   = toolingReadBE32(data, at: 0x36)
        let drawerDataPtr  = toolingReadBE32(data, at: 0x42)

        var off = 78

        func skipImage() -> Bool {
            guard off + 20 <= data.count else { return false }
            let w = Int(toolingReadBE16(data, at: off + 4))
            let h = Int(toolingReadBE16(data, at: off + 6))
            let d = Int(toolingReadBE16(data, at: off + 8))
            off += 20 + ((w + 15) / 16 * 2) * h * d
            return off <= data.count
        }

        if gadgetRender != 0 { guard skipImage() else { return nil } }
        if selectRender != 0 { guard skipImage() else { return nil } }

        if defaultToolPtr != 0 {
            guard off + 4 <= data.count else { return nil }
            let len = Int(toolingReadBE32(data, at: off))
            off += 4 + len
            guard off <= data.count else { return nil }
        }

        var ttStart: Int? = nil
        var ttEnd: Int? = nil
        if toolTypesPtr != 0 {
            guard off + 4 <= data.count else { return nil }
            ttStart = off
            let ptrArrayBytes = Int(toolingReadBE32(data, at: off))
            guard ptrArrayBytes >= 4 else { return nil }
            let n = ptrArrayBytes / 4 - 1
            off += 4
            for _ in 0..<n {
                guard off + 4 <= data.count else { return nil }
                let len = Int(toolingReadBE32(data, at: off))
                off += 4 + len
                guard off <= data.count else { return nil }
            }
            ttEnd = off
        }

        let ddStart: Int? = (drawerDataPtr != 0) ? off : nil
        return DiskObjectOffsets(toolTypesStart: ttStart, toolTypesEnd: ttEnd, drawerDataStart: ddStart)
    }

    // MARK: - DefaultTool

    /// Replace (or add/remove) a project icon's DefaultTool string. The string
    /// lives between the image data and the ToolTypes block, stored as a LONG
    /// byte count (including the terminating NUL) followed by Latin-1 bytes —
    /// so changing it means splicing that region and flipping the
    /// do_DefaultTool pointer field. Everything after it (ToolTypes,
    /// DrawerData, NewIcon/GlowIcon trailers) is preserved verbatim.
    public static func setDefaultTool(path: String, tool: String?) throws {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { throw ToolingError.cannotRead(path) }
        guard data.count >= 78, data[0] == 0xE3, data[1] == 0x10 else {
            throw ToolingError.invalidFormat("Not a valid .info file: \(path)")
        }
        let gadgetRender = toolingReadBE32(data, at: 0x16)
        let selectRender = toolingReadBE32(data, at: 0x1A)
        let hadTool      = toolingReadBE32(data, at: 0x32) != 0

        var off = 78
        func skipImage() -> Bool {
            guard off + 20 <= data.count else { return false }
            let w = Int(toolingReadBE16(data, at: off + 4))
            let h = Int(toolingReadBE16(data, at: off + 6))
            let d = Int(toolingReadBE16(data, at: off + 8))
            off += 20 + ((w + 15) / 16 * 2) * h * d
            return off <= data.count
        }
        if gadgetRender != 0 { guard skipImage() else { throw ToolingError.invalidFormat(path) } }
        if selectRender != 0 { guard skipImage() else { throw ToolingError.invalidFormat(path) } }

        let regionStart = off
        var regionEnd = off
        if hadTool {
            guard off + 4 <= data.count else { throw ToolingError.invalidFormat(path) }
            let len = Int(toolingReadBE32(data, at: off))
            regionEnd = off + 4 + len
            guard regionEnd <= data.count else { throw ToolingError.invalidFormat(path) }
        }

        var replacement = Data()
        let wanted = (tool?.isEmpty == false) ? tool! : nil
        if let wanted {
            let bytes = Array(wanted.unicodeScalars.map { UInt8($0.value & 0xFF) }) + [0]
            replacement += toolingBEBytes(UInt32(bytes.count))
            replacement += Data(bytes)
        }

        var out = Data()
        out += data[0..<regionStart]
        out += replacement
        out += data[regionEnd...]
        // do_DefaultTool: non-zero when a string is present (the value itself is
        // a runtime pointer Workbench rewrites; only zero/non-zero matters).
        let ptr: UInt32 = (wanted != nil) ? 0x0000_0064 : 0
        let p = toolingBEBytes(ptr)
        for i in 0..<4 { out[0x32 + i] = p[i] }
        do { try out.write(to: url) } catch { throw ToolingError.cannotWrite(path) }
    }

    // MARK: - ToolTypes export / import

    /// Export tooltype strings from a .info file to a plain-text file
    /// (one per line, LF, no BOM).
    public static func exportToolTypes(infoPath: String, outputPath: String) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)) else {
            throw ToolingError.cannotRead(infoPath)
        }
        guard let offsets = walkDiskObject(data) else {
            throw ToolingError.invalidFormat("Not a valid .info file: \(infoPath)")
        }
        guard let ttStart = offsets.toolTypesStart else {
            try? Data().write(to: URL(fileURLWithPath: outputPath))
            return
        }

        let ptrArrayBytes = Int(toolingReadBE32(data, at: ttStart))
        let n = max(0, ptrArrayBytes / 4 - 1)
        var off = ttStart + 4
        var lines: [String] = []

        for _ in 0..<n {
            guard off + 4 <= data.count else { break }
            let len = Int(toolingReadBE32(data, at: off)); off += 4
            guard len > 0, off + len <= data.count else { off += len; continue }
            let strBytes = data[off..<(off + len - 1)] // strip null byte
            let s = String(bytes: strBytes, encoding: .isoLatin1) ?? String(bytes: strBytes, encoding: .utf8) ?? ""
            lines.append(s)
            off += len
        }

        let output = lines.map { $0 + "\n" }.joined()
        let outputData = output.data(using: .isoLatin1) ?? Data(output.utf8)
        do {
            try outputData.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            throw ToolingError.cannotWrite(outputPath)
        }
    }

    /// Replace the ToolTypes block in a .info file with strings read from a
    /// plain-text file.
    public static func importToolTypes(infoPath: String, inputPath: String) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)) else {
            throw ToolingError.cannotRead(infoPath)
        }
        guard let offsets = walkDiskObject(data) else {
            throw ToolingError.invalidFormat("Not a valid .info file: \(infoPath)")
        }

        let inputRaw: String
        if let s = try? String(contentsOfFile: inputPath, encoding: .utf8) {
            inputRaw = s
        } else if let s = try? String(contentsOfFile: inputPath, encoding: .isoLatin1) {
            inputRaw = s
        } else {
            throw ToolingError.cannotRead(inputPath)
        }
        var inputStr = inputRaw
        if inputStr.hasPrefix("\u{FEFF}") { inputStr = String(inputStr.dropFirst()) } // strip BOM
        let lines = inputStr.components(separatedBy: "\n").filter { !$0.isEmpty }

        func buildToolTypesBlock(_ lines: [String]) -> Data {
            var block = Data()
            block += toolingBEBytes(UInt32((lines.count + 1) * 4))
            for line in lines {
                let strBytes = (line.data(using: .isoLatin1) ?? Data(line.utf8)) + Data([0])
                block += toolingBEBytes(UInt32(strBytes.count))
                block += strBytes
            }
            return block
        }

        if offsets.toolTypesStart == nil {
            if lines.isEmpty { return }
            // No existing block — create one and patch do_ToolTypes (0x36) to non-zero
            let insertAt = offsets.drawerDataStart ?? data.count
            let newBlock = buildToolTypesBlock(lines)
            var newData = Data(data[..<insertAt]) + newBlock + Data(data[insertAt...])
            toolingWriteBE32(&newData, at: 0x36, value: 1)
            do {
                try newData.write(to: URL(fileURLWithPath: infoPath), options: .atomic)
            } catch {
                throw ToolingError.cannotWrite(infoPath)
            }
            return
        }

        let ttStart = offsets.toolTypesStart!
        let ttEnd = offsets.toolTypesEnd!
        let newBlock = buildToolTypesBlock(lines)
        let newData = Data(data[..<ttStart]) + newBlock + Data(data[ttEnd...])
        do {
            try newData.write(to: URL(fileURLWithPath: infoPath), options: .atomic)
        } catch {
            throw ToolingError.cannotWrite(infoPath)
        }
    }

    // MARK: - icon-update (type, position, drawer geometry)

    /// Patches to apply to a DiskObject; nil fields are left untouched.
    public struct UpdateSpec {
        public var type: UInt8? = nil
        public var currentX: Int32? = nil
        public var currentY: Int32? = nil
        public var drawerX: Int16? = nil
        public var drawerY: Int16? = nil
        public var drawerWidth: Int16? = nil
        public var drawerHeight: Int16? = nil

        public init(type: UInt8? = nil, currentX: Int32? = nil, currentY: Int32? = nil,
                    drawerX: Int16? = nil, drawerY: Int16? = nil,
                    drawerWidth: Int16? = nil, drawerHeight: Int16? = nil) {
            self.type = type
            self.currentX = currentX
            self.currentY = currentY
            self.drawerX = drawerX
            self.drawerY = drawerY
            self.drawerWidth = drawerWidth
            self.drawerHeight = drawerHeight
        }

        var wantsDrawer: Bool {
            drawerX != nil || drawerY != nil || drawerWidth != nil || drawerHeight != nil
        }
    }

    /// Patch icon type, current position, and/or drawer window geometry in a
    /// .info file. Returns warning lines (e.g. drawer patches skipped because
    /// the DiskObject carries no DrawerData) — the CLI prints them to stderr.
    @discardableResult
    public static func update(infoPath: String, spec: UpdateSpec) throws -> [String] {
        guard var data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)) else {
            throw ToolingError.cannotRead(infoPath)
        }
        guard data.count >= 78, data[0] == 0xE3, data[1] == 0x10 else {
            throw ToolingError.invalidFormat("Not a valid .info file: \(infoPath)")
        }

        var warnings: [String] = []

        if let t = spec.type     { data[0x30] = t }
        if let x = spec.currentX { toolingWriteBE32(&data, at: 0x3A, value: UInt32(bitPattern: x)) }
        if let y = spec.currentY { toolingWriteBE32(&data, at: 0x3E, value: UInt32(bitPattern: y)) }

        if spec.wantsDrawer {
            if toolingReadBE32(data, at: 0x42) == 0 {
                warnings.append("icon-update: no DrawerData in '\(infoPath)', skipping drawer patches")
            } else if let ddStart = walkDiskObject(data)?.drawerDataStart, ddStart + 8 <= data.count {
                if let x = spec.drawerX      { toolingWriteBE16(&data, at: ddStart + 0, value: UInt16(bitPattern: x)) }
                if let y = spec.drawerY      { toolingWriteBE16(&data, at: ddStart + 2, value: UInt16(bitPattern: y)) }
                if let w = spec.drawerWidth  { toolingWriteBE16(&data, at: ddStart + 4, value: UInt16(bitPattern: w)) }
                if let h = spec.drawerHeight { toolingWriteBE16(&data, at: ddStart + 6, value: UInt16(bitPattern: h)) }
            }
        }

        do {
            try data.write(to: URL(fileURLWithPath: infoPath))
        } catch {
            throw ToolingError.cannotWrite(infoPath)
        }
        return warnings
    }
}
