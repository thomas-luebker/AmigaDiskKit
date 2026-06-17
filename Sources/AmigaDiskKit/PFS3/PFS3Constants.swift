import Foundation

/// PFS3 on-disk constants, transcribed from pfs3aio `blocks.h` and hst-amiga
/// `Constants.cs` (the authoritative references — do not edit from memory).
/// Values verified against hst-imager 1.5.564 PFS3 format fixtures
/// (pfs3-2g-reserved-area.bin / pfs3-8g-reserved-area.bin).
enum PFS3 {

    // MARK: - Disk ids

    /// 'PFS\1' — bootblock and rootblock disktype.
    static let idPFSDisk: UInt32 = 0x5046_5301
    /// 'PFS\2' — experimental large-disk / large-blocksize variant (unsupported here).
    static let idPFS2Disk: UInt32 = 0x5046_5302
    /// 'BUSY'
    static let idBusy: UInt32 = 0x4255_5359

    // MARK: - Reserved block ids (UWORD, two ASCII chars)

    static let dirBlockID: UInt16        = 0x4442  // 'DB'
    static let anodeBlockID: UInt16      = 0x4142  // 'AB'
    static let indexBlockID: UInt16      = 0x4942  // 'IB'
    static let bitmapBlockID: UInt16     = 0x424D  // 'BM'
    static let bitmapIndexBlockID: UInt16 = 0x4D49 // 'MI'
    static let deldirBlockID: UInt16     = 0x4444  // 'DD'
    static let extensionBlockID: UInt16  = 0x4558  // 'EX'
    static let superBlockID: UInt16      = 0x5342  // 'SB'

    // MARK: - Rootblock option flags

    struct Options: OptionSet {
        let rawValue: UInt32
        static let hardDisk       = Options(rawValue: 1)
        static let splittedAnodes = Options(rawValue: 2)
        static let dirExtension   = Options(rawValue: 4)
        static let deldir         = Options(rawValue: 8)
        static let sizeField      = Options(rawValue: 16)
        /// Rootblock extension present.
        static let extensionBlock = Options(rawValue: 32)
        /// Datestamps were enabled at format time.
        static let datestamp      = Options(rawValue: 64)
        static let superIndex     = Options(rawValue: 128)
        static let superDeldir    = Options(rawValue: 256)
        static let extRoving      = Options(rawValue: 512)
        static let longFN         = Options(rawValue: 1024)
        static let largeFile      = Options(rawValue: 2048)
        static let storedGeometry = Options(rawValue: 4096)
    }

    // MARK: - Limits (blocks.h)

    static let maxSmallBitmapIndex = 4
    static let maxBitmapIndex = 103
    /// Max reserved bitmap 256K.
    static let maxNumReserved = 4096 + 255 * 1024 * 8
    static let maxSuper = 15
    static let maxSmallIndexNr = 98
    static let delEntryFNSize = 18

    /// ULONGs of bitmap payload per bitmap block at 1K reserved blocksize.
    static let bitmapPayload1K = 1024 / 4 - 3   // 253
    static let bitmapPayload2K = 2048 / 4 - 3   // 509
    static let bitmapPayload4K = 4096 / 4 - 3   // 1021

    /// Disk-size thresholds in 512-byte sectors (blocks.h).
    /// smalldisk = 10,241,440 sectors ≈ 5 GB; 1K-reserved limit ≈ 104 GB.
    static let maxSmallDisk: Int64 =
        Int64(maxSmallBitmapIndex + 1) * Int64(bitmapPayload1K) * Int64(bitmapPayload1K) * 32
    static let maxDiskSize1K: Int64 =
        Int64(maxBitmapIndex + 1) * Int64(bitmapPayload1K) * Int64(bitmapPayload1K) * 32
    static let maxDiskSize2K: Int64 =
        Int64(maxBitmapIndex + 1) * Int64(bitmapPayload2K) * Int64(bitmapPayload2K) * 32

    // MARK: - Layout fixpoints

    static let bootBlock1: UInt32 = 0
    static let bootBlock2: UInt32 = 1
    static let rootBlockNr: UInt32 = 2

    // MARK: - Anodes

    static let anodeEOF: UInt32 = 0
    static let anodeBadBlocks: UInt32 = 4
    static let anodeRootDir: UInt32 = 5
    static let anodeUserFirst: UInt32 = 6
    /// Reserved anodes per anode block.
    static let reservedAnodes = 6

    // MARK: - Deldir

    static let deldirEntriesPerBlock = 31
    static let maxDeldir = 31
    static let delEntryProt: UInt16 = 0x0005

    // MARK: - Cache / update thresholds (Constants.cs)

    static let rtbfCacheSize = 512
    static let rtbfThreshold = 256
    static let rtbfPostponedTh = 48
    static let resfreeThreshold: UInt32 = 10
    static let reservedBuffer = 10
    static let dataCacheLen = 32

    /// pfs3aio version written into rootblockextension.pfs2version.
    static let verNum: UInt32 = 19
    static let revNum: UInt32 = 2

    // MARK: - Name sizes

    static let dnSize = 32     // diskname
    static let fnSize = 108    // filename buffer (compat)
    static let cmSize = 80     // comment
    /// fnsize written by hst-imager's formatter (fixture-verified; pfs3aio
    /// itself writes 32 — hst-amiga deliberately uses 107 for long filenames).
    static let formattedFNSize: UInt16 = 107

    // MARK: - Entry types

    static let stRoot: Int8 = 1
    static let stUserDir: Int8 = 2
    static let stSoftLink: Int8 = 3
    static let stLinkDir: Int8 = 4
    static let stFile: Int8 = -3
    static let stLinkFile: Int8 = -4
    static let stRolloverFile: Int8 = -16
}
