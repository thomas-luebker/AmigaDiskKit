//
//  IconMetadata.swift
//  AmigaDiskKit
//
//  Parses the METADATA of a classic Amiga Workbench icon (.info /
//  DiskObject): icon type, default tool, tool types, stack size and the
//  snapshotted position — the textual half IconImageDecoder deliberately
//  skips. Layout per the RKM DiskObject structure (all big-endian):
//
//    0x00 magic 0xE310, 0x02 version
//    0x04 Gadget (44 bytes; GadgetRender ptr @0x16, SelectRender @0x1A)
//    0x30 type, 0x32 DefaultTool*, 0x36 ToolTypes*, 0x3A/0x3E CurrentX/Y,
//    0x42 DrawerData*, 0x46 ToolWindow*, 0x4A StackSize   (header = 78)
//
//  After the header: DrawerData (56 bytes, when present), the planar
//  image(s), then the DefaultTool string, the ToolTypes array and the
//  ToolWindow string — each string is a LONG byte count (including the
//  terminating NUL) followed by that many Latin-1 bytes; the ToolTypes
//  array starts with a LONG holding (count + 1) * 4.
//

import Foundation

public struct IconMetadata {
    public enum IconType: Int {
        case disk = 1, drawer = 2, tool = 3, project = 4, garbage = 5, device = 6, kick = 7, appIcon = 8
        public var displayName: String {
            switch self {
            case .disk: return "Disk"
            case .drawer: return "Drawer"
            case .tool: return "Tool"
            case .project: return "Project"
            case .garbage: return "Trashcan"
            case .device: return "Device"
            case .kick: return "Kickstart"
            case .appIcon: return "AppIcon"
            }
        }
    }

    public let type: IconType?
    public let defaultTool: String?
    public let toolTypes: [String]
    public let stackSize: Int
    public let currentX: Int32
    public let currentY: Int32
    public let hasDrawerData: Bool
}

public enum IconMetadataParser {

    public static func parse(_ raw: Data) -> IconMetadata? {
        let data = (raw.startIndex == 0) ? raw : Data(raw)
        guard data.count >= 78, data[0] == 0xE3, data[1] == 0x10 else { return nil }

        let typeRaw       = Int(data[0x30])
        let hasDefault    = toolingReadBE32(data, at: 0x32) != 0
        let hasToolTypes  = toolingReadBE32(data, at: 0x36) != 0
        let currentX      = Int32(bitPattern: toolingReadBE32(data, at: 0x3A))
        let currentY      = Int32(bitPattern: toolingReadBE32(data, at: 0x3E))
        let hasDrawerData = toolingReadBE32(data, at: 0x42) != 0
        let hasToolWindow = toolingReadBE32(data, at: 0x46) != 0
        let stackSize     = Int(toolingReadBE32(data, at: 0x4A))
        let hasImage1     = toolingReadBE32(data, at: 0x16) != 0
        let hasImage2     = toolingReadBE32(data, at: 0x1A) != 0
        _ = hasToolWindow

        var off = 78
        if hasDrawerData { off += 56 }
        if hasImage1 { guard skipImage(data, &off) else { return metadataOnly(typeRaw, stackSize, currentX, currentY, hasDrawerData) } }
        if hasImage2 { guard skipImage(data, &off) else { return metadataOnly(typeRaw, stackSize, currentX, currentY, hasDrawerData) } }

        var defaultTool: String?
        if hasDefault { defaultTool = readString(data, &off) }

        var toolTypes: [String] = []
        if hasToolTypes, off + 4 <= data.count {
            let field = Int(toolingReadBE32(data, at: off)); off += 4
            let count = max(0, field / 4 - 1)
            for _ in 0..<min(count, 256) {
                guard let s = readString(data, &off) else { break }
                toolTypes.append(s)
            }
        }

        return IconMetadata(type: IconMetadata.IconType(rawValue: typeRaw),
                            defaultTool: defaultTool, toolTypes: toolTypes,
                            stackSize: stackSize, currentX: currentX, currentY: currentY,
                            hasDrawerData: hasDrawerData)
    }

    private static func metadataOnly(_ typeRaw: Int, _ stack: Int,
                                     _ x: Int32, _ y: Int32, _ drawer: Bool) -> IconMetadata {
        IconMetadata(type: IconMetadata.IconType(rawValue: typeRaw), defaultTool: nil,
                     toolTypes: [], stackSize: stack, currentX: x, currentY: y,
                     hasDrawerData: drawer)
    }

    /// Skip a 20-byte Image struct + its planar data (same geometry math as
    /// IconImageDecoder.decodeImage — keep in sync).
    private static func skipImage(_ data: Data, _ off: inout Int) -> Bool {
        guard off + 20 <= data.count else { return false }
        let width  = Int(toolingReadBE16(data, at: off + 4))
        let height = Int(toolingReadBE16(data, at: off + 6))
        let depth  = Int(toolingReadBE16(data, at: off + 8))
        guard width > 0, height > 0, depth > 0, depth <= 8,
              width <= 4096, height <= 4096 else { return false }
        let planeSize = ((width + 15) / 16) * 2 * height
        let end = off + 20 + planeSize * depth
        guard end <= data.count else { return false }
        off = end
        return true
    }

    /// LONG length (including NUL) + Latin-1 bytes.
    private static func readString(_ data: Data, _ off: inout Int) -> String? {
        guard off + 4 <= data.count else { return nil }
        let len = Int(toolingReadBE32(data, at: off)); off += 4
        guard len > 0, len <= 4096, off + len <= data.count else { return nil }
        let bytes = data[data.index(data.startIndex, offsetBy: off)
                         ..< data.index(data.startIndex, offsetBy: off + len)]
        off += len
        let s = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        return s.components(separatedBy: "\0").first ?? s
    }
}
