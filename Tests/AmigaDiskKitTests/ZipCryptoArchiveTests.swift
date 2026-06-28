import XCTest
@testable import AmigaDiskKit

/// Native ZipCrypto + DEFLATE reader, validated against the AmigaOS 3.9 Boing Bag
/// "AmigaOS-Update" payload (a password-protected ZIP nested in the Boing Bag
/// .lha). Env-gated on the BoingBag39-2.lha fixture so it skips on machines
/// without it. The password is the fixed, widely-known H&P constant for BB2.
final class ZipCryptoArchiveTests: XCTestCase {

    private let bb2Password = "3FB6986B-B0AD6339-4FF3254B"
    private var bbLha: String? { ProcessInfo.processInfo.environment["AMIGADISKKIT_BB39_2_LHA"] }

    /// Pull the nested AmigaOS-Update ZIP out of the Boing Bag .lha natively.
    private func loadUpdateZip() throws -> ZipCryptoArchive {
        guard let lhaPath = bbLha else {
            throw XCTSkip("Set AMIGADISKKIT_BB39_2_LHA to a BoingBag39-2.lha fixture")
        }
        let lha = try LHAArchive(url: URL(fileURLWithPath: lhaPath))
        let member = try XCTUnwrap(lha.members.first { $0.path.hasSuffix("AmigaOS-Update") },
                                   "AmigaOS-Update not found in the Boing Bag .lha")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aos-update-\(UUID().uuidString)")
        try lha.extractMember(member, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try ZipCryptoArchive(data: Data(contentsOf: tmp))
    }

    /// extract() CRC-verifies every entry, so a clean run over the whole archive
    /// is proof that ZipCrypto decryption + DEFLATE are byte-correct.
    func testDecryptsAndInflatesWholeAmigaOSUpdate() throws {
        let zip = try loadUpdateZip()
        XCTAssertFalse(zip.entries.isEmpty, "ZIP central directory parsed no entries")
        XCTAssertTrue(zip.entries.contains { $0.isEncrypted }, "expected encrypted entries")
        XCTAssertTrue(zip.entries.contains { $0.method == 8 }, "expected deflated entries")
        XCTAssertTrue(zip.entries.contains { $0.method == 0 }, "expected stored entries")

        var files = 0
        for e in zip.entries where !e.isDirectory {
            _ = try zip.extract(e, password: bb2Password)   // throws on CRC/inflate/password failure
            files += 1
        }
        XCTAssertGreaterThan(files, 100, "expected the full AmigaOS-Update payload")

        // The ROM-update module must be present and non-trivial.
        let rom = try XCTUnwrap(zip.entries.first { $0.name.hasSuffix("AmigaOS ROM Update.BB39-2") })
        XCTAssertGreaterThan(try zip.extract(rom, password: bb2Password).count, 1000)
    }

    func testWrongPasswordIsRejected() throws {
        let zip = try loadUpdateZip()
        let e = try XCTUnwrap(zip.entries.first { !$0.isDirectory && $0.isEncrypted })
        XCTAssertThrowsError(try zip.extract(e, password: "WRONG-PASSWORD-1234"))
    }
}
