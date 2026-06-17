import XCTest
@testable import AmigaDiskKit

final class FAT32TableTests: XCTestCase {

    private var imageURL: URL!
    private var device: BlockDevice!
    private var table: FAT32Table!

    override func setUpWithError() throws {
        imageURL = try FAT32TestImage.create()
        device = try BlockDevice(url: imageURL, readOnly: false)
        let mbrData = try device.read(at: 0, length: 512)
        let mbr = try MBRPartitionTable(data: mbrData)
        let partStart = Int64(mbr.partitions[0].lbaStart) * 512
        let vbr = try device.read(at: partStart, length: 512)
        let bpb = try FAT32BPB(data: vbr)
        table = FAT32Table(device: device, bpb: bpb, partitionStart: partStart)
    }

    override func tearDownWithError() throws {
        device = nil
        table = nil
        try? FileManager.default.removeItem(at: imageURL)
    }

    // MARK: - Initial state

    func testMediaTypeEntry0() throws {
        // Entry 0: media type marker (0x0FFFFFF8)
        XCTAssertEqual(try table.readEntry(0), 0x0FFFFFF8)
    }

    func testReservedEntry1() throws {
        // Entry 1: always EOC
        let e = try table.readEntry(1)
        XCTAssertGreaterThanOrEqual(e, FAT32Table.eocMin)
    }

    func testRootDirEntry2IsEOC() throws {
        // Root directory cluster 2 is a single-cluster chain (EOC in fresh image)
        let e = try table.readEntry(2)
        XCTAssertGreaterThanOrEqual(e, FAT32Table.eocMin)
    }

    func testFreeClusters() throws {
        // Clusters 3-101 should all be free
        for c: UInt32 in 3 ... 10 {
            XCTAssertEqual(try table.readEntry(c), FAT32Table.free, "cluster \(c) should be free")
        }
    }

    // MARK: - Write / read roundtrip

    func testWriteAndReadEntry() throws {
        try table.writeEntry(3, value: FAT32Table.eoc)
        XCTAssertEqual(try table.readEntry(3), FAT32Table.eoc)
    }

    func testWriteToAllFATCopies() throws {
        // After writeEntry, both FAT copies should have the same value
        try table.writeEntry(4, value: 7)
        let bpb = table.bpb
        let fat1Off = Int64(bpb.fatSectorOffset(fatIndex: 0)) * Int64(bpb.bytesPerSector)
        let fat2Off = Int64(bpb.fatSectorOffset(fatIndex: 1)) * Int64(bpb.bytesPerSector)
        let partStart = table.partitionStart

        let e1 = try device.read(at: partStart + fat1Off + 4 * 4, length: 4).readLE32(at: 0) & 0x0FFFFFFF
        let e2 = try device.read(at: partStart + fat2Off + 4 * 4, length: 4).readLE32(at: 0) & 0x0FFFFFFF
        XCTAssertEqual(e1, 7)
        XCTAssertEqual(e2, 7)
    }

    // MARK: - Chain navigation

    func testNextClusterOnEOCReturnsNil() throws {
        XCTAssertNil(try table.nextCluster(after: 2))
    }

    func testNextClusterOnFreeReturnsNil() throws {
        XCTAssertNil(try table.nextCluster(after: 5))
    }

    func testFollowTwoClusterChain() throws {
        // Build chain: 3 → 4 → EOC
        try table.writeEntry(3, value: 4)
        try table.writeEntry(4, value: FAT32Table.eoc)

        let chain = try table.clusterChain(startingAt: 3)
        XCTAssertEqual(chain, [3, 4])
    }

    func testClusterChainSingleCluster() throws {
        let chain = try table.clusterChain(startingAt: 2)  // root dir = 1 cluster
        XCTAssertEqual(chain, [2])
    }

    // MARK: - Allocation

    func testAllocateSingleCluster() throws {
        let c = try table.allocateCluster()
        XCTAssertGreaterThanOrEqual(c, 3)
        XCTAssertEqual(try table.readEntry(c), FAT32Table.eoc)
    }

    func testAllocateChainAfter() throws {
        let first = try table.allocateCluster()
        let second = try table.allocateCluster(chainAfter: first)
        XCTAssertNotEqual(first, second)
        // first should point to second
        XCTAssertEqual(try table.readEntry(first), second)
        // second should be EOC
        XCTAssertEqual(try table.readEntry(second), FAT32Table.eoc)
    }

    func testAllocateChainLength() throws {
        let first = try table.allocateChain(length: 4)
        let chain = try table.clusterChain(startingAt: first)
        XCTAssertEqual(chain.count, 4)
    }

    // MARK: - Free chain

    func testFreeChain() throws {
        let first = try table.allocateChain(length: 3)
        let chain = try table.clusterChain(startingAt: first)
        XCTAssertEqual(chain.count, 3)

        try table.freeChain(startingAt: first)

        for c in chain {
            XCTAssertEqual(try table.readEntry(c), FAT32Table.free, "cluster \(c) should be free after freeChain")
        }
    }

    // MARK: - Cluster data I/O

    func testReadWriteCluster() throws {
        let cluster: UInt32 = 3
        try table.writeEntry(cluster, value: FAT32Table.eoc)
        let clusterSize = table.bpb.bytesPerCluster
        var payload = Data(count: clusterSize)
        payload[0] = 0xAB; payload[clusterSize - 1] = 0xCD

        try table.writeCluster(cluster, data: payload)
        let read = try table.readCluster(cluster)
        XCTAssertEqual(read[0], 0xAB)
        XCTAssertEqual(read[clusterSize - 1], 0xCD)
    }

    func testReadChainDataWithMaxBytes() throws {
        // Allocate a 2-cluster chain and write known data
        let clusterSize = table.bpb.bytesPerCluster
        let first = try table.allocateChain(length: 2)
        var d1 = Data(count: clusterSize); d1[0] = 0x01
        var d2 = Data(count: clusterSize); d2[0] = 0x02
        let chain = try table.clusterChain(startingAt: first)
        try table.writeCluster(chain[0], data: d1)
        try table.writeCluster(chain[1], data: d2)

        // Read entire chain
        let all = try table.readChainData(startingAt: first)
        XCTAssertEqual(all.count, clusterSize * 2)
        XCTAssertEqual(all[0], 0x01)
        XCTAssertEqual(all[clusterSize], 0x02)

        // Read only first clusterSize bytes
        let partial = try table.readChainData(startingAt: first, maxBytes: clusterSize)
        XCTAssertEqual(partial.count, clusterSize)
        XCTAssertEqual(partial[0], 0x01)
    }

    func testWriteChainData() throws {
        let clusterSize = table.bpb.bytesPerCluster
        let payload = Data((0 ..< clusterSize * 2).map { UInt8($0 & 0xFF) })
        let first = try table.allocateChain(length: 2)
        try table.writeChainData(startingAt: first, data: payload)

        let read = try table.readChainData(startingAt: first)
        XCTAssertEqual(Data(read.prefix(payload.count)), payload)
    }
}
