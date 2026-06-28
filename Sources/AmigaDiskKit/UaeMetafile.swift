import Foundation

/// UAE per-file metadata sidecar (`<name>.uaem`, "UaeMetafile" mode).
///
/// hst-imager preserves Amiga file protection (and date/comment) across a
/// host round-trip via these sidecars: `hst-imager fs extract` writes them and
/// `hst-imager fs copy --uaemetadata UaeMetafile` reads them back. amiga-tools
/// mirrors that format so the native build path preserves protection bits — in
/// particular the Pure bit on `L/System-startup` that `LoadModule ROMUPDATE`
/// needs — instead of flattening every file to the POSIX-derived default.
///
/// Line format (matches the sidecars build-classic.sh fed to hst-imager):
///
///     <HSPARWED-mask> <YYYY-MM-DD HH:MM:SS.ss> [comment]
///
/// The mask is 8 characters in AmigaDOS display order `h s p a r w e d`:
/// `hspa` are letters when the raw bit is **set**; `rwed` are letters when the
/// raw bit is **clear** (RWED is active-low — a clear bit means the action is
/// permitted). A dash means the opposite. This is the same string `list` shows
/// and the same one hst-imager's `fs dir` prints (lower-cased).
public struct UaeMetafile {
    /// Raw AmigaDOS protection longword (FFS convention; PFS3 uses the low byte).
    public var protection: UInt32
    public var date: Date?
    public var comment: String

    public init(protection: UInt32, date: Date? = nil, comment: String = "") {
        self.protection = protection
        self.date = date
        self.comment = comment
    }

    // MARK: - Mask <-> raw protection

    /// HSPA bits are stored active-high; RWED (bits 0–3) active-low.
    private static let highFlags: [(idx: Int, bit: UInt32, ch: Character)] = [
        (0, 0x80, "h"), (1, 0x40, "s"), (2, 0x20, "p"), (3, 0x10, "a"),
    ]
    private static let rwedFlags: [(idx: Int, bit: UInt32, ch: Character)] = [
        (4, 0x08, "r"), (5, 0x04, "w"), (6, 0x02, "e"), (7, 0x01, "d"),
    ]

    /// Render the 8-character `hsparwed` mask for a raw protection value.
    public static func maskString(from protection: UInt32) -> String {
        var chars = Array(repeating: Character("-"), count: 8)
        for f in highFlags where (protection & f.bit) != 0 { chars[f.idx] = f.ch }
        for f in rwedFlags where (protection & f.bit) == 0 { chars[f.idx] = f.ch } // active-low
        return String(chars)
    }

    /// Parse an 8-character `hsparwed` mask back to a raw protection value.
    /// Case-insensitive; characters other than the expected letter are treated
    /// as "dash" for that position. Returns nil if the string isn't 8 chars.
    public static func protection(fromMask mask: String) -> UInt32? {
        let chars = Array(mask.lowercased())
        guard chars.count == 8 else { return nil }
        var prot: UInt32 = 0
        for f in highFlags where chars[f.idx] == f.ch { prot |= f.bit }        // set when letter present
        for f in rwedFlags where chars[f.idx] != f.ch { prot |= f.bit }        // active-low: set when dash
        return prot
    }

    // MARK: - Serialization

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS"
        return f
    }()

    /// One sidecar line (no trailing newline). Mirrors the build script's
    /// `printf '%s %s \n'` shape: mask, space, date, trailing space, comment.
    public func serialized() -> String {
        let stamp = Self.dateFormatter.string(from: date ?? Date(timeIntervalSince1970: 0))
        return "\(Self.maskString(from: protection)) \(stamp) \(comment)"
    }

    /// Parse a sidecar file's contents. Only the leading mask token is required;
    /// the date/comment are best-effort.
    public static func parse(_ text: String) -> UaeMetafile? {
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
        let tokens = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard let maskTok = tokens.first, let prot = protection(fromMask: String(maskTok)) else {
            return nil
        }
        var date: Date? = nil
        if tokens.count >= 3 {
            date = dateFormatter.date(from: "\(tokens[1]) \(tokens[2].split(separator: " ").first ?? "")")
        }
        let comment = tokens.count >= 3
            ? tokens[2].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                .dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            : ""
        return UaeMetafile(protection: prot, date: date, comment: comment)
    }

    /// Sidecar URL for a given extracted host file (`Foo` → `Foo.uaem`).
    public static func sidecarURL(for hostFile: URL) -> URL {
        hostFile.appendingPathExtension("uaem")
    }

    public static let fileExtension = "uaem"
}

public extension AmigaVolumeOperations {
    /// Walk the volume tree under `amigaPath` (whose contents were just extracted
    /// to `hostURL`) and write a `<file>.uaem` sidecar for every file with a
    /// non-default protection mask. Default-protection files are skipped to match
    /// hst-imager's behaviour and keep the extracted tree clean — the copy side
    /// falls back to its POSIX-derived default for files without a sidecar.
    func writeUaeSidecars(amigaPath: String, hostURL: URL) throws {
        for entry in try listEntries(path: amigaPath) {
            let childAmiga = amigaPath.isEmpty ? entry.name : "\(amigaPath)/\(entry.name)"
            let childHost = hostURL.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try writeUaeSidecars(amigaPath: childAmiga, hostURL: childHost)
            } else if entry.protection != 0 {
                let meta = UaeMetafile(protection: entry.protection,
                                       date: entry.modified, comment: entry.comment)
                try (meta.serialized() + "\n").write(
                    to: UaeMetafile.sidecarURL(for: childHost),
                    atomically: true, encoding: .utf8)
            }
        }
    }

    /// Extract and, when requested, write `.uaem` sidecars carrying each file's
    /// Amiga protection bits.
    func extractToHost(amigaPath: String, hostURL: URL, writeUaeMetadata: Bool) throws {
        try extractToHost(amigaPath: amigaPath, hostURL: hostURL)
        if writeUaeMetadata {
            try writeUaeSidecars(amigaPath: amigaPath, hostURL: hostURL)
        }
    }

    /// Default implementation so existing 2-argument callers keep the previous
    /// (no-metadata) behaviour while engines implement the metadata-aware form.
    func copyFromHost(hostURL: URL, amigaPath: String) throws {
        try copyFromHost(hostURL: hostURL, amigaPath: amigaPath, applyUaeMetadata: false)
    }
}

/// Read a `.uaem` sidecar next to `hostFile` if present, returning its parsed
/// protection. Returns nil when there is no sidecar (caller falls back to its
/// POSIX-derived default).
func uaeSidecarProtection(for hostFile: URL) -> UInt32? {
    let url = UaeMetafile.sidecarURL(for: hostFile)
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let meta = UaeMetafile.parse(text) else { return nil }
    return meta.protection
}
