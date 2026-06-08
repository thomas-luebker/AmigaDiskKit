import Foundation

/// Standard Amiga RDB CHS geometry used by hst-imager and this library.
/// All images are described as 16 heads × 63 sectors/track = 1008 blocks/cylinder.
public struct DiskGeometry {
    public let cylinders: UInt32
    public let heads: UInt32
    public let sectors: UInt32    // physical sectors per track
    public let blockSize: UInt32  // bytes per sector (always 512)

    public static let standardHeads: UInt32 = 16
    public static let standardSectors: UInt32 = 63  // sectors per track
    public static let standardBlockSize: UInt32 = 512

    /// Number of 512-byte blocks in one cylinder.
    public var blocksPerCylinder: UInt32 { heads * sectors }

    /// Total 512-byte blocks on the disk.
    public var totalBlocks: UInt64 { UInt64(cylinders) * UInt64(blocksPerCylinder) }

    /// Total bytes represented by this geometry.
    public var totalBytes: Int64 { Int64(totalBlocks) * Int64(blockSize) }

    /// Number of cylinders reserved for RDB structures (covers RDSK + PART blocks).
    public static let rdbReservedCylinders: UInt32 = 2

    /// First cylinder available for partition data (cylinder 2).
    public var loCylinder: UInt32 { DiskGeometry.rdbReservedCylinders }

    /// Last cylinder available for partition data (cylinders - 1).
    public var hiCylinder: UInt32 { cylinders - 1 }

    /// Last LBA index in the RDB reserved area (inclusive).
    /// rdbBlockHi = loCylinder * blocksPerCylinder - 1 = 2 * 1008 - 1 = 2015.
    public var rdbBlockHi: UInt32 { loCylinder * blocksPerCylinder - 1 }

    /// Derive geometry from a byte size, rounding down to the nearest full cylinder.
    public init(
        sizeBytes: Int64,
        blockSize: UInt32 = standardBlockSize,
        heads: UInt32 = standardHeads,
        sectors: UInt32 = standardSectors
    ) throws {
        guard heads > 0, sectors > 0, blockSize > 0 else {
            throw AmigaDiskError.invalidGeometry(reason: "heads, sectors, and blockSize must be non-zero")
        }
        let blocksPerCyl = Int64(heads) * Int64(sectors)
        let totalBlks = sizeBytes / Int64(blockSize)
        let cyls = totalBlks / blocksPerCyl
        guard cyls >= 3 else {
            throw AmigaDiskError.invalidGeometry(
                reason: "image too small: \(cyls) cylinder(s), minimum is 3")
        }
        guard cyls <= Int64(UInt32.max) else {
            throw AmigaDiskError.invalidGeometry(reason: "cylinder count overflows UInt32")
        }
        self.cylinders = UInt32(cyls)
        self.heads = heads
        self.sectors = sectors
        self.blockSize = blockSize
    }
}
