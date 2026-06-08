import Foundation

/// Verify an Amiga block checksum.
///
/// The Amiga block checksum algorithm requires that the sum of the first
/// `summedLongs` big-endian UInt32 words (including the checksum word at
/// offset 0x08) equals zero under UInt32 wrapping arithmetic.
///
/// `summedLongs` is read from offset 0x04 of the block data.
public func verifyAmigaBlockChecksum(_ data: Data) -> Bool {
    let summedLongs = Int(data.readBE32(at: 4))
    guard data.count >= summedLongs * 4 else { return false }
    var sum: UInt32 = 0
    for i in 0 ..< summedLongs {
        sum = sum &+ data.readBE32(at: i * 4)
    }
    return sum == 0
}

/// Compute the checksum word that should be stored at offset 0x08 so that
/// `verifyAmigaBlockChecksum` would pass.
///
/// The checksum word is the bitwise negation of the sum of all other
/// `summedLongs` words (i.e. the two's-complement negative).
/// Returns the signed interpretation expected at the stored field position.
public func computeAmigaBlockChecksum(_ data: Data) -> Int32 {
    let summedLongs = Int(data.readBE32(at: 4))
    guard data.count >= summedLongs * 4 else { return 0 }
    // Sum all words except the checksum word at index 2 (offset 0x08)
    var sum: UInt32 = 0
    for i in 0 ..< summedLongs where i != 2 {
        sum = sum &+ data.readBE32(at: i * 4)
    }
    // The stored checksum must be -(sum), so that sum + checksum = 0
    return Int32(bitPattern: 0 &- sum)
}

/// Write the Amiga block checksum into `data` at offset 0x08.
/// `summedLongs` (at offset 0x04) must already be set before calling this.
/// After this call, `verifyAmigaBlockChecksum(data)` returns true.
public func embedAmigaChecksum(into data: inout Data) {
    data.writeBE32(UInt32(0), at: 0x08)
    let checksum = computeAmigaBlockChecksum(data)
    data.writeBE32(checksum, at: 0x08)
}

// MARK: - FFS filesystem block checksum (root / dir / file blocks)
// Checksum stored at long index 5 (byte offset 20).
// Valid when the sum of ALL longs in the block equals zero.

public func computeFFSBlockChecksum(_ data: Data) -> UInt32 {
    let longCount = data.count / 4
    var sum: UInt32 = 0
    for i in 0 ..< longCount where i != 5 {
        sum = sum &+ data.readBE32(at: i * 4)
    }
    return 0 &- sum
}

public func embedFFSBlockChecksum(into data: inout Data) {
    precondition(data.count >= 24)
    data.writeBE32(UInt32(0), at: 20)
    data.writeBE32(computeFFSBlockChecksum(data), at: 20)
}

public func verifyFFSBlockChecksum(_ data: Data) -> Bool {
    let longCount = data.count / 4
    guard longCount > 0 else { return false }
    var sum: UInt32 = 0
    for i in 0 ..< longCount {
        sum = sum &+ data.readBE32(at: i * 4)
    }
    return sum == 0
}

// MARK: - FFS bitmap block checksum
// Checksum stored at long index 0 (byte offset 0).
// Valid when the sum of ALL longs in the block equals zero.

public func computeBitmapBlockChecksum(_ data: Data) -> UInt32 {
    let longCount = data.count / 4
    var sum: UInt32 = 0
    for i in 1 ..< longCount {
        sum = sum &+ data.readBE32(at: i * 4)
    }
    return 0 &- sum
}

public func embedBitmapBlockChecksum(into data: inout Data) {
    precondition(data.count >= 4)
    data.writeBE32(UInt32(0), at: 0)
    data.writeBE32(computeBitmapBlockChecksum(data), at: 0)
}

public func verifyBitmapBlockChecksum(_ data: Data) -> Bool {
    let longCount = data.count / 4
    guard longCount > 0 else { return false }
    var sum: UInt32 = 0
    for i in 0 ..< longCount {
        sum = sum &+ data.readBE32(at: i * 4)
    }
    return sum == 0
}

// MARK: - FFS boot block checksum (1024 bytes, end-around carry)
// Checksum stored at byte offset 4.
// Uses ones-complement (end-around carry) addition over 256 BE32 words.
// Valid when the total sum (including checksum word) equals 0xFFFFFFFF.

public func computeFFSBootBlockChecksum(_ data: Data) -> UInt32 {
    precondition(data.count == 1024)
    var sum: UInt32 = 0
    for i in 0 ..< 256 where i != 1 {
        let prev = sum
        sum = sum &+ data.readBE32(at: i * 4)
        if sum < prev { sum = sum &+ 1 }
    }
    return ~sum
}

public func embedFFSBootBlockChecksum(into data: inout Data) {
    precondition(data.count == 1024)
    data.writeBE32(UInt32(0), at: 4)
    data.writeBE32(computeFFSBootBlockChecksum(data), at: 4)
}

public func verifyFFSBootBlockChecksum(_ data: Data) -> Bool {
    guard data.count == 1024 else { return false }
    var sum: UInt32 = 0
    for i in 0 ..< 256 {
        let prev = sum
        sum = sum &+ data.readBE32(at: i * 4)
        if sum < prev { sum = sum &+ 1 }
    }
    return sum == 0xFFFFFFFF
}
