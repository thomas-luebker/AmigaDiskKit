import XCTest
@testable import AmigaDiskKit

/// PFS3 block codec tests against hst-imager 1.5.564 format fixtures.
///
/// Fixtures (captured from `hst-imager rdb part format` on PDS3 partitions,
/// partition-relative sectors, lowCyl 2 → partition start LBA 2016):
///   pfs3-2g-reserved-area.bin — first 1024 sectors of a 1.9 GB partition
///   pfs3-8g-reserved-area.bin — first 4096 sectors of a 7.8 GB partition (supermode)
final class PFS3BlocksTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("binary").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func sector(_ data: Data, _ nr: Int, count: Int = 1) -> Data {
        data.subdata(in: nr * 512 ..< (nr + count) * 512)
    }

    func testBootBlock2G() throws {
        let area = try fixture("pfs3-2g-reserved-area.bin")
        XCTAssertEqual(sector(area, 0).readBE32(at: 0), PFS3.idPFSDisk)
        // rest of the two boot sectors is zero
        XCTAssertTrue(sector(area, 0).dropFirst(4).allSatisfy { $0 == 0 })
        XCTAssertTrue(sector(area, 1).allSatisfy { $0 == 0 })
    }

    func testRootBlock2GParseAndRoundTrip() throws {
        let area = try fixture("pfs3-2g-reserved-area.bin")
        let raw = sector(area, Int(PFS3.rootBlockNr))
        let root = try PFS3RootBlock(data: raw)

        XCTAssertEqual(root.diskType, PFS3.idPFSDisk)
        XCTAssertEqual(root.options.rawValue, 0x77F)   // all standard modes, no SUPERINDEX
        XCTAssertTrue(root.options.contains(.deldir))
        XCTAssertTrue(root.options.contains(.longFN))
        XCTAssertFalse(root.options.contains(.superIndex))
        XCTAssertEqual(root.datestamp, 3)
        XCTAssertEqual(root.protection, 0xF0)
        XCTAssertEqual(root.diskName, "Workbench")
        XCTAssertEqual(root.firstReserved, 2)
        XCTAssertEqual(root.lastReserved, 83329)
        XCTAssertEqual(root.reservedBlksize, 1024)
        XCTAssertEqual(root.rblkCluster, 12)
        XCTAssertEqual(root.blocksFree, 3_901_294)
        XCTAssertEqual(root.alwaysFree, root.blocksFree / 20)
        XCTAssertEqual(root.diskSize, 3_984_624)
        XCTAssertEqual(root.extension_, 996)
        XCTAssertEqual(root.deldir, 0)

        XCTAssertEqual(root.serialize(), raw, "rootblock must round-trip byte-identically")
    }

    func testRootBlock8GSupermodeParseAndRoundTrip() throws {
        let area = try fixture("pfs3-8g-reserved-area.bin")
        let raw = sector(area, Int(PFS3.rootBlockNr))
        let root = try PFS3RootBlock(data: raw)

        XCTAssertEqual(root.options.rawValue, 0x7FF)
        XCTAssertTrue(root.options.contains(.superIndex))
        XCTAssertEqual(root.diskName, "Work")
        XCTAssertEqual(root.reservedBlksize, 1024)   // 8 GB still below the 1K limit
        XCTAssertEqual(root.firstReserved, 2)
        // supermode: idx union holds bitmapindex[104]
        XCTAssertEqual(root.largeBitmapIndex(0), 0x26)
        XCTAssertEqual(root.largeBitmapIndex(1), 0x222)

        XCTAssertEqual(root.serialize(), raw)
    }

    func testRootBlockExtensionParseAndRoundTrip() throws {
        let area = try fixture("pfs3-2g-reserved-area.bin")
        let root = try PFS3RootBlock(data: sector(area, 2))
        let raw = sector(area, Int(root.extension_), count: Int(root.reservedBlksize) / 512)
        let rext = PFS3RootBlockExtension(data: raw)

        XCTAssertEqual(rext.pfs2version, (19 << 16) | 2)
        XCTAssertEqual(rext.fnsize, 107)
        XCTAssertEqual(rext.deldirSize, 2)
        XCTAssertEqual(rext.rootDate.day, root.creationDay)
        XCTAssertEqual(rext.rootDate.minute, root.creationMinute)
        XCTAssertEqual(rext.rootDate.tick, root.creationTick)
        XCTAssertEqual(rext.tobedone.operationID, 0)
        // deldirsize 2 → two deldir block pointers allocated
        XCTAssertNotEqual(rext.deldir[0], 0)
        XCTAssertNotEqual(rext.deldir[1], 0)
        XCTAssertEqual(rext.deldir[2], 0)

        XCTAssertEqual(rext.serialize(size: Int(root.reservedBlksize)), raw,
                       "rootblockextension must round-trip byte-identically")
    }

    func testReservedBitmapBehindRootBlock() throws {
        let area = try fixture("pfs3-2g-reserved-area.bin")
        let root = try PFS3RootBlock(data: sector(area, 2))
        // Reserved bitmap starts directly behind the 512-byte rootblock within
        // the rblkCluster (12 sectors): sector 3 begins with the 'BM' header.
        let raw = sector(area, 3)
        XCTAssertEqual(raw.readBE16(at: 0), PFS3.bitmapBlockID)

        // numreserved = (lastReserved − firstReserved + 1) / rescluster
        let rescluster = Int(root.reservedBlksize) / 512
        let numReserved = (Int(root.lastReserved) - Int(root.firstReserved) + 1) / rescluster
        XCTAssertEqual(numReserved, 41664)
        // Post-format allocation state: blocks 0–5 hold the rootblock cluster,
        // block 6 was the extension's INITIAL position (firstreserved + cluster)
        // and was freed when UpdateDisk reallocated the dirty extension block to
        // a fresh location (PFS3 never overwrites reserved blocks in place), and
        // blocks 7+ were consumed by bitmap/anode/index/dirblock/deldir blocks.
        // Net result: only bit 6 of the first bitmap long is free.
        let firstLong = raw.readBE32(at: 12)
        XCTAssertEqual(firstLong, 0x0200_0000)
    }

    func testSeqBlocksInFixtureParse() throws {
        let area = try fixture("pfs3-2g-reserved-area.bin")
        let root = try PFS3RootBlock(data: sector(area, 2))
        let resSize = Int(root.reservedBlksize)
        let longs = root.longsPerBmb

        // small-mode union: bitmapindex[0] / indexblocks[0] point to reserved
        // blocks (sector numbers within the partition).
        let bmIndexNr = Int(root.smallBitmapIndex(0))
        XCTAssertGreaterThan(bmIndexNr, 0)
        let bmIndexRaw = sector(area, bmIndexNr, count: resSize / 512)
        XCTAssertEqual(bmIndexRaw.readBE16(at: 0), PFS3.bitmapIndexBlockID)
        let bmIndex = PFS3IndexBlock(id: PFS3.bitmapIndexBlockID, data: bmIndexRaw, longs: longs)
        XCTAssertEqual(bmIndex.serialize(size: resSize), bmIndexRaw)

        let anIndexNr = Int(root.smallIndexBlock(0))
        XCTAssertGreaterThan(anIndexNr, 0)
        let anIndexRaw = sector(area, anIndexNr, count: resSize / 512)
        XCTAssertEqual(anIndexRaw.readBE16(at: 0), PFS3.indexBlockID)

        // First anode block: indexblocks[0].index[0]
        let anIndex = PFS3IndexBlock(id: PFS3.indexBlockID, data: anIndexRaw, longs: longs)
        let anodeBlockNr = Int(anIndex.index[0])
        XCTAssertGreaterThan(anodeBlockNr, 0)
        let anodeRaw = sector(area, anodeBlockNr, count: resSize / 512)
        XCTAssertEqual(anodeRaw.readBE16(at: 0), PFS3.anodeBlockID)
        let anodeBlock = PFS3AnodeBlock(data: anodeRaw,
                                        slots: PFS3AnodeBlock.anodesPerBlock(reservedBlksize: resSize))
        XCTAssertEqual(anodeBlock.serialize(size: resSize), anodeRaw)
        // Root directory anode (nr 5, slot 5) must exist and point at the root dirblock.
        let rootAnode = anodeBlock.anodes[Int(PFS3.anodeRootDir)]
        XCTAssertEqual(rootAnode.clustersize, 1)
        XCTAssertGreaterThan(rootAnode.blocknr, 0)
        XCTAssertEqual(rootAnode.next, 0)

        // Root dirblock: empty, anodenr 5, parent 0.
        let dirRaw = sector(area, Int(rootAnode.blocknr), count: resSize / 512)
        XCTAssertEqual(dirRaw.readBE16(at: 0), PFS3.dirBlockID)
        let dirBlock = PFS3DirBlock(data: dirRaw,
                                    entrySpace: PFS3DirBlock.entrySpace(reservedBlksize: resSize))
        XCTAssertEqual(dirBlock.anodenr, PFS3.anodeRootDir)
        XCTAssertEqual(dirBlock.parent, 0)
        XCTAssertEqual(dirBlock.entries.first, 0, "root directory must be empty")
        XCTAssertEqual(dirBlock.serialize(size: resSize), dirRaw)

        // Deldir block 0 from the extension.
        let rext = PFS3RootBlockExtension(
            data: sector(area, Int(root.extension_), count: resSize / 512))
        let deldirRaw = sector(area, Int(rext.deldir[0]), count: resSize / 512)
        XCTAssertEqual(deldirRaw.readBE16(at: 0), PFS3.deldirBlockID)
        let deldirBlock = PFS3DelDirBlock(data: deldirRaw)
        XCTAssertEqual(deldirBlock.seqnr, 0)
        XCTAssertEqual(deldirBlock.serialize(size: resSize), deldirRaw)
    }
}
