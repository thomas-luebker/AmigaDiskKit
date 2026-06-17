import XCTest
@testable import AmigaDiskKit

final class BlockDeviceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockDeviceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeImage(blocks: Int = 8) throws -> URL {
        let url = tmpDir.appendingPathComponent("dev.img")
        var data = Data()
        for b in 0 ..< blocks {
            data.append(Data(repeating: UInt8(b), count: 512))
        }
        try data.write(to: url)
        return url
    }

    func testFileHandleInit_readParityWithURLInit() throws {
        let url = try makeImage()
        let byURL = try BlockDevice(url: url, readOnly: true)
        let byHandle = BlockDevice(fileHandle: try FileHandle(forReadingFrom: url), readOnly: true)

        XCTAssertEqual(try byHandle.size, try byURL.size)
        for lba in [Int64(0), 3, 7] {
            XCTAssertEqual(try byHandle.readBlock(at: lba), try byURL.readBlock(at: lba))
        }
    }

    func testFileHandleInit_writeRoundTrip() throws {
        let url = try makeImage()
        let device = BlockDevice(fileHandle: try FileHandle(forUpdating: url))
        let payload = Data(repeating: 0xCD, count: 512)
        try device.writeBlock(payload, at: 2)
        XCTAssertEqual(try device.readBlock(at: 2), payload)

        let reread = try BlockDevice(url: url, readOnly: true)
        XCTAssertEqual(try reread.readBlock(at: 2), payload)
    }

    func testReadOnly_writeIsRejected() throws {
        let url = try makeImage()
        let byURL = try BlockDevice(url: url, readOnly: true)
        XCTAssertThrowsError(try byURL.writeBlock(Data(count: 512), at: 0))

        // Even on an updatable handle, the readOnly flag must win.
        let byHandle = BlockDevice(fileHandle: try FileHandle(forUpdating: url), readOnly: true)
        XCTAssertThrowsError(try byHandle.writeBlock(Data(count: 512), at: 0))
    }

    func testSize_regularFile() throws {
        let url = try makeImage(blocks: 5)
        XCTAssertEqual(try BlockDevice(url: url, readOnly: true).size, 5 * 512)
        // Cached path returns the same value on repeat access.
        let device = try BlockDevice(url: url, readOnly: true)
        XCTAssertEqual(try device.size, try device.size)
    }
}
