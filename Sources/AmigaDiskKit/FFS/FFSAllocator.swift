import Foundation

/// Bitmap-based block allocator for a mounted FFS partition.
/// Loads all bitmap blocks on init; callers must invoke `flush(device:)` after all allocations.
final class FFSAllocator {

    private let layout: FFSLayout
    private let partAbsByte: Int64
    private let bitmapFSBlocks: [Int]  // actual FS-block numbers read from root block
    private var bitmaps: [Data]        // one Data per bitmap block
    private var dirty:   Set<Int>      // indices into bitmaps[] that need flushing

    // Cursor: resume bitmap scan from here instead of always starting at 0.
    private var cursorBitmapIdx: Int = 0
    private var cursorLongIdx:   Int = 1

    // MARK: - Init

    /// - Parameters:
    ///   - bitmapFSBlocks: Partition-relative FS-block numbers of the bitmap blocks,
    ///     as read from the root block (and its extension chain). Must not be empty.
    init(device: BlockDevice, bitmapFSBlocks: [Int], layout: FFSLayout, partAbsByte: Int64) throws {
        self.layout         = layout
        self.partAbsByte    = partAbsByte
        self.bitmapFSBlocks = bitmapFSBlocks
        let fsSize = layout.fsBlockSize
        bitmaps = []
        dirty   = []
        for fsBlock in bitmapFSBlocks {
            let byteOff = partAbsByte + Int64(fsBlock) * Int64(fsSize)
            let data = try device.read(at: byteOff, length: fsSize)
            bitmaps.append(data)
        }
    }

    // MARK: - Allocation

    /// Allocate one free FS block, mark it as used, and return its partition-relative number.
    /// Throws `AmigaDiskError.readFailed` (disk full) when no free block exists.
    ///
    /// Bit-to-block mapping follows the canonical Amiga FFS bitmap convention — confirmed
    /// byte-for-byte against hst-imager's `Bitmap.AdfSetBlockUsed`/`AdfIsBlockFree`
    /// (`sectOfMap = nSect - Reserved`; bit `sectOfMap % 32` via `1 << k`, i.e. LSB = lowest
    /// block number in each group of 32; word `sectOfMap / 32`, 0 = first word after the
    /// checksum). Bit set (1) = free, bit clear (0) = used.
    ///
    /// A previous version of this allocator used a mirrored mapping (`31 - (fsBlock %
    /// bitsPerBitmap)`, MSB-first, no `reserved` offset): internally self-consistent — its
    /// own format/mount round-trip tests passed — but byte-incompatible with every bitmap
    /// hst-imager reads or writes. Sharing a partition with hst-imager (`DISK_ENGINE=
    /// amigadiskkit` interleaved with raw `hst-imager fs copy`) meant every "free"/"used"
    /// bit one engine wrote was misread by the other as describing a *different* block —
    /// guaranteeing eventual cross-engine overwrite of live directory/file headers
    /// (observed as `Invalid entry block type` in hst-imager during Aminet package installs).
    func allocate() throws -> UInt32 {
        let totalBitmaps = bitmaps.count
        let totalMapBits = layout.totalFSBlocks - layout.reserved
        // Two-pass scan: start at cursor, wrap around once so we don't miss earlier free blocks.
        for pass in 0 ..< 2 {
            let startBitmapIdx = pass == 0 ? cursorBitmapIdx : 0
            let endBitmapIdx   = pass == 0 ? totalBitmaps    : cursorBitmapIdx + 1
            for bitmapIdx in startBitmapIdx ..< endBitmapIdx {
                let rangeStart = bitmapIdx * layout.bitsPerBitmapBlock
                if rangeStart >= totalMapBits { break }
                let longCount = bitmaps[bitmapIdx].count / 4

                let startLong = (bitmapIdx == cursorBitmapIdx && pass == 0) ? cursorLongIdx : 1
                // long[0] = checksum (skip); long[1..] = bitmap data words
                for longIdx in startLong ..< longCount {
                    let wordBitBase = rangeStart + (longIdx - 1) * 32
                    if wordBitBase >= totalMapBits { break }
                    let word = bitmaps[bitmapIdx].readBE32(at: longIdx * 4)
                    guard word != 0 else { continue }
                    // LSB-first: bit 0 = lowest sectOfMap (= lowest block number) in this word.
                    for bitPos in 0 ..< 32 {
                        let sectOfMap = wordBitBase + bitPos
                        if sectOfMap >= totalMapBits { break }
                        if (word >> UInt32(bitPos)) & 1 == 1 {
                            // Clear bit → mark block as used
                            let newWord = word & ~(UInt32(1) << UInt32(bitPos))
                            bitmaps[bitmapIdx].writeBE32(newWord, at: longIdx * 4)
                            dirty.insert(bitmapIdx)
                            cursorBitmapIdx = bitmapIdx
                            cursorLongIdx   = longIdx
                            return UInt32(layout.reserved + sectOfMap)
                        }
                    }
                }
            }
        }
        throw AmigaDiskError.readFailed(offset: 0, length: 0, reason: "partition is full (no free blocks)")
    }

    /// Allocate `count` FS blocks and return their partition-relative numbers.
    func allocate(count: Int) throws -> [UInt32] {
        var blocks: [UInt32] = []
        blocks.reserveCapacity(count)
        for _ in 0 ..< count { blocks.append(try allocate()) }
        return blocks
    }

    // MARK: - Deallocation

    /// Mark a previously-allocated FS block as free.
    /// See `allocate()` for the canonical bit-to-block mapping this must match.
    func free(_ fsBlock: UInt32) {
        guard fsBlock >= UInt32(layout.reserved) else { return }
        let sectOfMap = Int(fsBlock) - layout.reserved
        let bitmapIdx = sectOfMap / layout.bitsPerBitmapBlock
        guard bitmapIdx < bitmaps.count else { return }
        let localBit = sectOfMap % layout.bitsPerBitmapBlock
        let longIdx  = 1 + localBit / 32
        let bitPos   = localBit % 32
        guard longIdx * 4 + 3 < bitmaps[bitmapIdx].count else { return }
        let word = bitmaps[bitmapIdx].readBE32(at: longIdx * 4)
        bitmaps[bitmapIdx].writeBE32(word | (UInt32(1) << UInt32(bitPos)), at: longIdx * 4)
        dirty.insert(bitmapIdx)
    }

    /// Mark an FS block as used regardless of what the bitmap currently says.
    /// Silently ignored for out-of-range / reserved blocks.
    /// See `allocate()` for the canonical bit-to-block mapping this must match.
    func markUsed(_ fsBlock: UInt32) {
        guard fsBlock >= UInt32(layout.reserved) else { return }
        let sectOfMap = Int(fsBlock) - layout.reserved
        let bitmapIdx = sectOfMap / layout.bitsPerBitmapBlock
        guard bitmapIdx < bitmaps.count else { return }
        let localBit = sectOfMap % layout.bitsPerBitmapBlock
        let longIdx  = 1 + localBit / 32
        let bitPos   = localBit % 32
        guard longIdx * 4 + 3 < bitmaps[bitmapIdx].count else { return }
        let word = bitmaps[bitmapIdx].readBE32(at: longIdx * 4)
        let newWord = word & ~(UInt32(1) << UInt32(bitPos))
        guard newWord != word else { return }
        bitmaps[bitmapIdx].writeBE32(newWord, at: longIdx * 4)
        dirty.insert(bitmapIdx)
    }

    // MARK: - Flush

    /// Write all dirty bitmap blocks back to disk with updated checksums.
    func flush(device: BlockDevice) throws {
        let fsSize = layout.fsBlockSize
        for idx in dirty.sorted() {
            var data = bitmaps[idx]
            embedBitmapBlockChecksum(into: &data)
            let fsBlock = bitmapFSBlocks[idx]
            let byteOff = partAbsByte + Int64(fsBlock) * Int64(fsSize)
            try device.write(data, at: byteOff)
            bitmaps[idx] = data
        }
        dirty = []
    }
}
