import XCTest
@testable import AmigaDiskKit

final class LHAEncoderTests: XCTestCase {

    private func roundTrip(_ files: [(String, Data)],
                           storeOnly: Bool = false) throws -> LHAArchive {
        var opts = LHAWriter.Options()
        opts.storeOnly = storeOnly
        var w = LHAWriter(options: opts)
        for (p, d) in files { try w.addFile(path: p, data: d) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lhaenc-\(UUID().uuidString).lha")
        try w.finish().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try LHAArchive(url: url)
    }

    private func extractAll(_ a: LHAArchive) throws -> [String: Data] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lhaenc-x-\(UUID().uuidString)")
        try a.extract(to: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var out: [String: Data] = [:]
        for m in a.members where !m.isDirectory {
            out[m.path] = try Data(contentsOf: dir.appendingPathComponent(m.path))
        }
        return out
    }

    func testStoredRoundTrip() throws {
        let payload = Data("Hello, Amiga!".utf8)
        let a = try roundTrip([("readme.txt", payload)], storeOnly: true)
        XCTAssertEqual(a.members.count, 1)
        XCTAssertEqual(a.members[0].method, "-lh0-")
        XCTAssertEqual(try extractAll(a)["readme.txt"], payload)
    }

    func testLH5CompressibleRoundTrip() throws {
        // Highly repetitive: must compress and survive CRC-verified extraction.
        var d = Data()
        for i in 0..<5000 { d.append(contentsOf: [UInt8(i & 7), 0x41, 0x41, 0x42] ) }
        let a = try roundTrip([("data.bin", d)])
        XCTAssertEqual(a.members[0].method, "-lh5-")
        XCTAssertLessThan(a.members[0].compressedSize, d.count / 2)
        XCTAssertEqual(try extractAll(a)["data.bin"], d)
    }

    func testIncompressibleFallsBackToStored() throws {
        var rng = SystemRandomNumberGenerator()
        let d = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let a = try roundTrip([("noise.bin", d)])
        XCTAssertEqual(a.members[0].method, "-lh0-")
        XCTAssertEqual(try extractAll(a)["noise.bin"], d)
    }

    func testTextCorpusRoundTrip() throws {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 800)
            + String(repeating: "AmigaOS 3.2 Workbench Preferences DataTypes ", count: 400)
        let d = Data(text.utf8)
        let a = try roundTrip([("Docs/corpus.txt", d)])
        XCTAssertEqual(a.members[0].method, "-lh5-")
        XCTAssertEqual(a.members[0].path, "Docs/corpus.txt")
        XCTAssertEqual(try extractAll(a)["Docs/corpus.txt"], d)
    }

    func testManyFilesMixed() throws {
        var files: [(String, Data)] = []
        for i in 0..<20 {
            let rep = String(repeating: "member \(i) content line\n", count: 50 + i * 13)
            files.append(("dir\(i % 3)/file\(i).txt", Data(rep.utf8)))
        }
        files.append(("empty.dat", Data()))
        files.append(("tiny.dat", Data([1, 2, 3])))
        let a = try roundTrip(files)
        let out = try extractAll(a)
        XCTAssertEqual(out.count, files.count)
        for (p, d) in files { XCTAssertEqual(out[p], d, "mismatch for \(p)") }
    }

    func testBinaryWithLongMatches() throws {
        // Exercises max-length matches and window-crossing references.
        var d = Data(count: 40_000)
        d.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8((i / 700) & 0xFF) }
        }
        let a = try roundTrip([("long.bin", d)])
        XCTAssertEqual(try extractAll(a)["long.bin"], d)
    }

    func testSystemLhaCanExtract() throws {
        // Interop: if a system lha (lhasa) is installed, it must list and
        // test our archive cleanly. Skipped where unavailable.
        let lha = "/opt/homebrew/bin/lha"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: lha))
        var w = LHAWriter()
        let d = Data(String(repeating: "interop payload — amiga forever. ", count: 300).utf8)
        try w.addFile(path: "interop.txt", data: d)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lhaenc-sys-\(UUID().uuidString).lha")
        try w.finish().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: lha)
        p.arguments = ["t", url.path]      // integrity test incl. CRC
        let sema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sema.signal() }
        try p.run()
        sema.wait()
        XCTAssertEqual(p.terminationStatus, 0, "system lha rejected our archive")
    }
}
