import Foundation

/// Embeds filesystem handler binaries into the RDB FSHD/LSEG chain so AmigaOS
/// can load them at boot (the native replacement for `hst-imager rdb fs add`).
///
/// Layout matches hst-imager: the FSHD block is written first, immediately
/// followed by its contiguous LSEG chain. The RDSK block is patched raw —
/// fields this library does not model (vendor strings written by other tools,
/// etc.) are preserved byte-for-byte.
public enum FileSystemRegistrar {

    public struct Result {
        public let fshdLBA: UInt32
        public let lsegCount: Int
        /// True when the dosType was already registered and nothing was written.
        public let alreadyRegistered: Bool
    }

    /// Register a filesystem handler binary in the image's RDB.
    ///
    /// - Same dosType already present: no-op (matches hst-imager, whose second
    ///   `rdb fs add` leaves the RDB area byte-identical) unless `replaceExisting`
    ///   is set, in which case a fresh LSEG chain is written and the existing
    ///   FSHD is repointed at it (the old chain becomes unreachable orphans).
    /// - `version` nil: parsed from the binary's `$VER:` string, 0 if absent.
    public static func addFileSystem(
        device: BlockDevice,
        sliceStartLBA: Int64,
        binary: Data,
        dosType: UInt32,
        name: String = "",
        version: UInt32? = nil,
        replaceExisting: Bool = false
    ) throws -> Result {
        var rdsk = try device.readBlock(at: sliceStartLBA)
        guard rdsk.count >= 512, rdsk.readBE32(at: 0) == RigidDiskBlock.identifier else {
            throw AmigaDiskError.rdskNotFound
        }
        let partitionList  = rdsk.readBE32(at: 0x1C)
        let fileSysHdrList = rdsk.readBE32(at: 0x20)
        let rdbBlockHi     = rdsk.readBE32(at: 0x84)
        let highRDSKBlock  = rdsk.readBE32(at: 0x98)

        // Existing registration check + chain tail discovery.
        var existingFSHD: (lba: UInt32, block: Data)? = nil
        var chainTail: (lba: UInt32, block: Data)? = nil
        var current = fileSysHdrList
        var guardCount = 0
        while current != 0xFFFFFFFF && guardCount < 64 {
            guard current > 0,
                  let block = try? device.readBlock(at: sliceStartLBA + Int64(current)),
                  block.count >= 512,
                  block.readBE32(at: 0) == FileSystemHeaderBlock.identifier else { break }
            if block.readBE32(at: 0x20) == dosType && existingFSHD == nil {
                existingFSHD = (current, block)
            }
            chainTail = (current, block)
            let next = block.readBE32(at: 0x10)
            if next == current { break }
            current = next
            guardCount += 1
        }

        if let existing = existingFSHD, !replaceExisting {
            return Result(fshdLBA: existing.lba, lsegCount: 0, alreadyRegistered: true)
        }

        // Free-LBA scan: everything after the highest occupied RDB-area block.
        var occupied: Set<Int> = [0]
        occupied.formUnion(partChainLBAs(device: device, sliceStartLBA: sliceStartLBA,
                                         partHead: partitionList))
        occupied.formUnion(occupiedFSHDChainLBAs(device: device, sliceStartLBA: sliceStartLBA,
                                                 fshdHead: fileSysHdrList))
        let firstFree = (occupied.max() ?? 0) + 1

        let payloads = stride(from: 0, to: binary.count, by: LoadSegBlock.payloadBytesPerBlock).map {
            binary.subdata(in: $0 ..< min($0 + LoadSegBlock.payloadBytesPerBlock, binary.count))
        }
        guard !payloads.isEmpty else {
            throw AmigaDiskError.invalidGeometry(reason: "filesystem binary is empty")
        }

        // Replacing: only the LSEG chain is appended; the FSHD slot is reused.
        let newFSHDLBA: UInt32? = existingFSHD == nil ? UInt32(firstFree) : nil
        let firstLSEG = existingFSHD == nil ? firstFree + 1 : firstFree
        let lastLSEG  = firstLSEG + payloads.count - 1
        guard lastLSEG <= Int(rdbBlockHi) else {
            throw AmigaDiskError.invalidGeometry(
                reason: "FSHD/LSEG chain end \(lastLSEG) exceeds RDB area limit \(rdbBlockHi) " +
                        "(binary \(binary.count) bytes = \(payloads.count) LSEG blocks)")
        }

        for (i, payload) in payloads.enumerated() {
            let next: UInt32 = i < payloads.count - 1 ? UInt32(firstLSEG + i + 1) : 0xFFFFFFFF
            let block = LoadSegBlock.serialize(payload: payload, next: next)
            try device.writeBlock(block, at: sliceStartLBA + Int64(firstLSEG + i))
        }

        let resolvedVersion = version ?? parseAmigaVersionString(binary) ?? 0
        let fshdLBA: UInt32
        if let existing = existingFSHD {
            // Repoint the existing FSHD at the new chain; refresh version + name.
            var block = existing.block
            block.writeBE32(resolvedVersion,  at: 0x24)
            block.writeBE32(UInt32(firstLSEG), at: 0x48)
            if !name.isEmpty { block.writeAmigaString(name, at: 0xAC, length: 84) }
            embedAmigaChecksum(into: &block)
            try device.writeBlock(block, at: sliceStartLBA + Int64(existing.lba))
            fshdLBA = existing.lba
        } else {
            let fshd = FileSystemHeaderBlock(dosType: dosType, version: resolvedVersion,
                                             name: name, segListBlock: UInt32(firstLSEG))
            try device.writeBlock(fshd.serialize(), at: sliceStartLBA + Int64(newFSHDLBA!))
            fshdLBA = newFSHDLBA!

            // Link in: append to the chain tail, or become the list head.
            if let tail = chainTail {
                var block = tail.block
                block.writeBE32(fshdLBA, at: 0x10)
                embedAmigaChecksum(into: &block)
                try device.writeBlock(block, at: sliceStartLBA + Int64(tail.lba))
            } else {
                rdsk.writeBE32(fshdLBA, at: 0x20)
            }
        }

        rdsk.writeBE32(max(highRDSKBlock, UInt32(lastLSEG)), at: 0x98)
        embedAmigaChecksum(into: &rdsk)
        try device.writeBlock(rdsk, at: sliceStartLBA)

        return Result(fshdLBA: fshdLBA, lsegCount: payloads.count, alreadyRegistered: false)
    }

    /// Slice-relative LBAs of every FSHD block and every LSEG block reachable
    /// from `fshdHead`. Empty set if the head is 0xFFFFFFFF or unreadable.
    static func occupiedFSHDChainLBAs(
        device: BlockDevice,
        sliceStartLBA: Int64,
        fshdHead: UInt32
    ) -> Set<Int> {
        var occupied: Set<Int> = []
        guard fshdHead != 0xFFFFFFFF else { return occupied }
        var currentFSHD = fshdHead
        var fshdGuard = 0
        while currentFSHD != 0xFFFFFFFF && fshdGuard < 64 {
            guard currentFSHD > 0,
                  let fshdData = try? device.readBlock(at: sliceStartLBA + Int64(currentFSHD)),
                  fshdData.count >= 512,
                  fshdData.readBE32(at: 0) == FileSystemHeaderBlock.identifier
            else { break }
            occupied.insert(Int(currentFSHD))
            fshdGuard += 1
            // dn_SegList: first LSEG block pointer at FSHD offset 0x48
            // (DevNode layout in the FileSysHeaderBlock spec places SegList at
            //  offset 0x28 within DevNode, which starts at FSHD offset 0x20).
            var currentLSEG = fshdData.readBE32(at: 0x48)
            var lsegGuard = 0
            while currentLSEG != 0xFFFFFFFF && lsegGuard < 1024 {
                guard currentLSEG > 0,
                      let lsegData = try? device.readBlock(at: sliceStartLBA + Int64(currentLSEG)),
                      lsegData.count >= 512,
                      lsegData.readBE32(at: 0) == LoadSegBlock.identifier
                else { break }
                occupied.insert(Int(currentLSEG))
                lsegGuard += 1
                let lsNext = lsegData.readBE32(at: 0x10)
                if lsNext == currentLSEG { break }
                currentLSEG = lsNext
            }
            let nextFSHD = fshdData.readBE32(at: 0x10)
            if nextFSHD == currentFSHD { break }
            currentFSHD = nextFSHD
        }
        return occupied
    }

    private static func partChainLBAs(
        device: BlockDevice,
        sliceStartLBA: Int64,
        partHead: UInt32
    ) -> Set<Int> {
        var occupied: Set<Int> = []
        var current = partHead
        var guardCount = 0
        while current != 0xFFFFFFFF && guardCount < 256 {
            guard current > 0,
                  let block = try? device.readBlock(at: sliceStartLBA + Int64(current)),
                  block.count >= 512,
                  block.readBE32(at: 0) == PartitionBlock.identifier else { break }
            occupied.insert(Int(current))
            let next = block.readBE32(at: 0x10)
            if next == current { break }
            current = next
            guardCount += 1
        }
        return occupied
    }

    /// Extract the version from an AmigaOS `$VER: <name> <major>.<minor>` string
    /// embedded in a handler binary, encoded as (major << 16) | minor.
    static func parseAmigaVersionString(_ binary: Data) -> UInt32? {
        let marker: [UInt8] = Array("$VER:".utf8)
        guard let markerStart = binary.firstRange(of: Data(marker)) else { return nil }
        let tail = binary[markerStart.upperBound ..< min(markerStart.upperBound + 128, binary.endIndex)]
        guard let text = String(bytes: tail, encoding: .isoLatin1) else { return nil }
        // First "<digits>.<digits>" token after the marker.
        var major: UInt32? = nil
        var digits = ""
        for ch in text {
            if ch.isNumber {
                digits.append(ch)
            } else if ch == ".", !digits.isEmpty, major == nil {
                major = UInt32(digits)
                digits = ""
            } else {
                if let maj = major, !digits.isEmpty {
                    return (maj << 16) | (UInt32(digits) ?? 0)
                }
                major = nil
                digits = ""
            }
        }
        if let maj = major, !digits.isEmpty { return (maj << 16) | (UInt32(digits) ?? 0) }
        return nil
    }
}
