import Foundation

/// Optional per-entry extension fields (MODE_DIR_EXTENSION), packed at the
/// entry tail. Encoded as 11 UWORDs: link(2), uid, gid, prot(2),
/// virtualsize(2), rollpointer(2), fsizex.
struct PFS3ExtraFields: Equatable {
    var link: UInt32 = 0
    var uid: UInt16 = 0
    var gid: UInt16 = 0
    var prot: UInt32 = 0          // protection bytes 1–3
    var virtualsize: UInt32 = 0
    var rollpointer: UInt32 = 0
    var fsizex: UInt16 = 0        // extended file size bits 32–47

    static let wordCount = 11

    var asWords: [UInt16] {
        [UInt16(link >> 16), UInt16(link & 0xFFFF),
         uid, gid,
         UInt16(prot >> 16), UInt16(prot & 0xFFFF),
         UInt16(virtualsize >> 16), UInt16(virtualsize & 0xFFFF),
         UInt16(rollpointer >> 16), UInt16(rollpointer & 0xFFFF),
         fsizex]
    }

    init() {}

    init(words: [UInt16]) {
        link = (UInt32(words[0]) << 16) | UInt32(words[1])
        uid = words[2]
        gid = words[3]
        prot = (UInt32(words[4]) << 16) | UInt32(words[5])
        virtualsize = (UInt32(words[6]) << 16) | UInt32(words[7])
        rollpointer = (UInt32(words[8]) << 16) | UInt32(words[9])
        fsizex = words[10]
    }

    /// On-disk size: one word per nonzero field + the flags word.
    var packedSize: Int {
        (asWords.filter { $0 != 0 }.count + 1) * 2
    }
}

/// One packed directory entry (struct direntry).
///
/// Layout: next(u8) type(i8) anode(u32) fsize(u32) day/min/tick(u16×3)
/// protection(u8) nlength(u8) name… comment-length(u8) comment… [pad] then,
/// with MODE_DIR_EXTENSION, the packed extrafields ending in the flags word.
/// `next` is the total entry size; 0 terminates the dirblock's entry area.
struct PFS3DirEntry {
    static let structSize = 20   // sizeof(struct direntry) incl. startofname + pad
    static let startOfName = 17

    var next: UInt8 = 0
    var type: Int8 = 0
    var anode: UInt32 = 0
    var fsize: UInt32 = 0
    var creationDay: UInt16 = 0
    var creationMinute: UInt16 = 0
    var creationTick: UInt16 = 0
    var protection: UInt8 = 0
    var name: String = ""
    var comment: String = ""
    var extraFields = PFS3ExtraFields()

    var isDirectory: Bool { type > 0 }

    /// Entry size on disk for the current fields.
    static func entrySize(name: String, comment: String, extraFields: PFS3ExtraFields,
                          dirExtension: Bool) -> Int {
        // Latin-1 byte counts must match the bytes written in write(into:) below.
        var size = (structSize + name.amigaLatin1Bytes.count
                              + comment.amigaLatin1Bytes.count) & 0xFFFE
        if dirExtension {
            size += extraFields.packedSize
        }
        return size
    }

    /// Parse the entry at `offset`; nil at the 0-terminator (or out of range).
    static func read(_ data: Data, offset: Int, dirExtension: Bool) throws -> PFS3DirEntry? {
        guard offset < data.count else { return nil }
        let next = data[data.startIndex + offset]
        guard next != 0 else { return nil }
        guard next >= UInt8(structSize), offset + Int(next) <= data.count else {
            throw AmigaDiskError.invalidGeometry(
                reason: "PFS3 direntry at \(offset) has invalid size \(next)")
        }

        var entry = PFS3DirEntry()
        entry.next = next
        entry.type = Int8(bitPattern: data[data.startIndex + offset + 1])
        entry.anode = data.readBE32(at: offset + 2)
        entry.fsize = data.readBE32(at: offset + 6)
        entry.creationDay = data.readBE16(at: offset + 10)
        entry.creationMinute = data.readBE16(at: offset + 12)
        entry.creationTick = data.readBE16(at: offset + 14)
        entry.protection = data[data.startIndex + offset + 16]
        let nameLength = Int(data[data.startIndex + offset + startOfName])
        entry.name = nameLength == 0 ? "" :
            (String(bytes: data.subdata(in: data.startIndex + offset + startOfName + 1
                                          ..< data.startIndex + offset + startOfName + 1 + nameLength),
                    encoding: .isoLatin1) ?? "")
        let commentOffset = offset + startOfName + 1 + nameLength
        let commentLength = Int(data[data.startIndex + commentOffset])
        entry.comment = commentLength == 0 ? "" :
            (String(bytes: data.subdata(in: data.startIndex + commentOffset + 1
                                          ..< data.startIndex + commentOffset + 1 + commentLength),
                    encoding: .isoLatin1) ?? "")

        if dirExtension {
            // flags word at entry end; packed nonzero words precede it in
            // reverse field order.
            var fieldsAt = offset + Int(next) - 2
            var flags = data.readBE16(at: fieldsAt)
            var words = [UInt16](repeating: 0, count: PFS3ExtraFields.wordCount)
            for i in 0 ..< PFS3ExtraFields.wordCount {
                if flags & 1 != 0 {
                    fieldsAt -= 2
                    words[i] = data.readBE16(at: fieldsAt)
                }
                flags >>= 1
            }
            entry.extraFields = PFS3ExtraFields(words: words)
        }
        return entry
    }

    /// Serialize into `data` at `offset`. Computes `next` from the fields.
    /// Returns the entry size written.
    @discardableResult
    func write(into data: inout Data, offset: Int, dirExtension: Bool) -> Int {
        let size = PFS3DirEntry.entrySize(name: name, comment: comment,
                                          extraFields: extraFields, dirExtension: dirExtension)
        data[data.startIndex + offset] = UInt8(size)
        data[data.startIndex + offset + 1] = UInt8(bitPattern: type)
        data.writeBE32(anode, at: offset + 2)
        data.writeBE32(fsize, at: offset + 6)
        data.writeBE16(creationDay, at: offset + 10)
        data.writeBE16(creationMinute, at: offset + 12)
        data.writeBE16(creationTick, at: offset + 14)
        data[data.startIndex + offset + 16] = protection
        let nameBytes = name.amigaLatin1Bytes
        data[data.startIndex + offset + PFS3DirEntry.startOfName] = UInt8(nameBytes.count)
        for (i, byte) in nameBytes.enumerated() {
            data[data.startIndex + offset + PFS3DirEntry.startOfName + 1 + i] = byte
        }
        let commentOffset = offset + PFS3DirEntry.startOfName + 1 + nameBytes.count
        let commentBytes = comment.amigaLatin1Bytes
        data[data.startIndex + commentOffset] = UInt8(commentBytes.count)
        for (i, byte) in commentBytes.enumerated() {
            data[data.startIndex + commentOffset + 1 + i] = byte
        }
        if (commentOffset + 1 + commentBytes.count) & 1 == 1 {
            data[data.startIndex + commentOffset + 1 + commentBytes.count] = 0
        }

        if dirExtension {
            // pack nonzero words (flag bit per field, LSB first), write them
            // in reverse order, flags word last.
            var flags: UInt16 = 0
            var packed: [UInt16] = []
            var orvalue: UInt16 = 1
            for word in extraFields.asWords {
                if word != 0 {
                    packed.append(word)
                    flags |= orvalue
                }
                orvalue <<= 1
            }
            var at = offset + ((PFS3DirEntry.structSize + nameBytes.count + commentBytes.count) & 0xFFFE)
            for word in packed.reversed() {
                data.writeBE16(word, at: at)
                at += 2
            }
            data.writeBE16(flags, at: at)
        }
        return size
    }
}
