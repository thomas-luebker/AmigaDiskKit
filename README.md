# AmigaDiskKit

A native Swift library for reading and writing Amiga disk images — no external tools, no Python runtime, no third-party dependencies.

AmigaDiskKit parses and creates MBR + RDB disk layouts; formats, mounts, and does full file I/O on FFS/OFS and PFS3 partitions; writes FAT32; reads and writes ADF floppies (including raw flux via Greaseweazle/SCP); reads LHA archives; and decodes Amiga artwork (ILBM/IFF, icons) to RGBA for previews. Every byte-offset calculation is `Int64` end-to-end, so partitions far beyond the 4 GiB mark behave identically to small ones (validated past 150 GiB).

![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange) ![Platform macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-blue) ![License Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-green)

## Features

| Area | Capabilities |
|---|---|
| **Disk layouts** | MBR parse + write (PiStorm layout) · pure-RDB parse + write (Classic / MiSTer HDF) · RDSK / PART / FSHD / LSEG parse · create blank image with RDB · rewrite RDB in an existing image |
| **FFS / OFS** | Format FFS / FFS2 (DOS\0/\1/\3/\5/\7) · directory listing & `mkdir -p` · file read/write · host↔image copy (file or tree) · delete · on-mount bitmap repair |
| **PFS3** | Format / mount / read / write PFS3 (PDS\3) partitions |
| **FAT32** | Native FAT32 format + file I/O (BPB, FAT table, dir entries) |
| **Floppies** | Read/write ADF (FFS & OFS, DD & HD) · Amiga MFM encode/decode · raw flux (SCP images, Greaseweazle protocol) |
| **Archives** | LHA reader — header levels 0/1/2, methods lh0/lh5/lh6/lh7, CRC-16 verified |
| **Previews** | Decode ILBM/IFF and Amiga icons (`.info`) to RGBA · container listing for Quick Look |
| **Tooling** | Filename sanitizing, icon/prefs patching, text transforms |
| **RDB FS registration** | Embed FFS / pfs3aio handler binaries into the FSHD/LSEG chain (`rdb-fs-add`) |
| **Cross-engine safety** | Canonical Amiga FFS bitmap convention (LSB-first, reserved-offset) |

## Installation

Add AmigaDiskKit as a Swift Package Manager dependency:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/thomas-luebker/AmigaDiskKit.git", branch: "main")
]
```

Then add it to your target:

```swift
.target(name: "YourApp", dependencies: ["AmigaDiskKit"])
```

The package also builds a standalone CLI, `AmigaDiskCLI` (see [CLI reference](#cli-reference)).

## Quick start

```swift
import AmigaDiskKit

// Inspect a disk image (auto-detects MBR+RDB or pure-RDB)
let info = try DiskImage.open(url: imageURL)
for part in info.rdb.partitionBlocks {
    print(part.driveName, part.dosTypeFormatted)   // e.g. "DH0  DOS\7"
}

// Mount a partition and list a directory
let fs = try FFSFileSystem.open(imageURL: imageURL, partitionName: "DH0")
for entry in try fs.listDirectory(path: "S") {
    print(entry.name, entry.isDirectory ? "<dir>" : "\(entry.byteSize) bytes")
}

// Copy a host file in, then commit the bitmap (always flush after writes)
try fs.copyFromHost(hostURL: localFile, amigaPath: "S/Startup-Sequence")
try fs.flush()

// Read an ADF floppy
let adf = try FFSFileSystem.openADF(url: adfURL)
let data = try adf.readFile(path: "C/Dir")

// Read an LHA archive
let archive = try LHAArchive(url: lhaURL)
try archive.extract(to: destinationDirectory)
```

Create a blank image with an RDB partition table:

```swift
let layout = DiskLayout.pureRDB(partitions: [
    PartitionSpec(name: "DH0", dosType: KnownDosType.dos3, sizeCylinders: 4165,
                  isBootable: true, bootPriority: 0, sectorsPerFSBlock: 4),
    PartitionSpec(name: "DH1", dosType: KnownDosType.dos7, sizeCylinders: 0,   // 0 = fill
                  isBootable: false, bootPriority: 0, sectorsPerFSBlock: 4),
])
try DiskBuilder.build(url: imageURL, sizeBytes: 8_589_934_592, layout: layout)

// build() writes the partition table only — format each partition separately
let disk = try DiskImage.open(url: imageURL)
let dh0 = disk.rdb.partitionBlocks[0]
try FFSFormatter.format(device: BlockDevice(url: imageURL), partition: dh0, rdb: disk.rdb,
                        spec: FFSFormatSpec(volumeName: "Workbench"))
```

## Package layout

```
Sources/
  AmigaDiskKit/
    ImageIO/        BlockDevice (raw Int64 I/O) · DiskGeometry (CHS) · DiskBuilder
    MBR/            MBRPartitionTable — parse + serialize
    RDB/            RigidDiskBlock · PartitionBlock · FileSystemHeaderBlock · FileSystemRegistrar
    FFS/            FFSFormat · FFSAllocator · FFSFileSystem · FFSEntry · FFSVolume
    PFS3/           PFS3Format · PFS3Volume · PFS3Core · PFS3Blocks · PFS3DirEntry · PFS3Constants
    FAT/            FAT32Format · FAT32Volume · FAT32Table · FAT32BPB · FAT32DirEntry
    Floppy/         ADFFloppyImage · AmigaMFM · FluxMFM · FluxStreamCodec · SCPImage · GreaseweazleProtocol
    Preview/        AmigaPreviewRenderer · PreviewContainerLister · IFF/ · Icon/
    LHA/            LHAArchive · LHDecoder
    Tooling/        FilenameSanitizer · IconPatcher · PrefsPatcher · TextTransform
    Parsing/        AmigaChecksum · Data+Parsing · Data+Writing · AmigaDate
    Diagnostics/    AmigaDiskError (typed error enum)
    AmigaVolume.swift   DiskImage.swift   (top-level auto-detect open)
  AmigaDiskCLI/
    main.swift      standalone CLI (disk / fs / adf subcommands)
Tests/
  AmigaDiskKitTests/   237 tests across 26 files; binary + golden fixtures
```

## Architecture

### Layers (bottom to top)

```
BlockDevice          — raw I/O; Int64 offsets everywhere
  ↓
MBRPartitionTable    — parse / write MBR first sector
RigidDiskBlock       — scan first 16 LBAs for RDSK; traverse PART + FSHD lists
DiskGeometry         — CHS geometry from byte size (16 heads × 63 sectors = 1008 blocks/cyl)
DiskBuilder          — orchestrate: blank file → MBR → RDSK → PART chain
  ↓
FFSFormatter / PFS3Formatter / FAT32Format   — write filesystem metadata onto a partition
FFSAllocator         — load live bitmap; allocate / free / markUsed; flush
FFSFileSystem / PFS3Volume / FAT32Volume     — high-level list, mkdir, read/write, copy, extract, delete
  ↓
AmigaDiskCLI         — CLI front-end (disk / fs / adf subcommands)
```

### Key invariant: Int64 offsets

Every byte-offset calculation uses `Int64`, including partition start (`lowCyl × blocksPerCylinder × 512`). No `UInt32` arithmetic appears in any I/O path. This is what lets partitions starting well past the 4 GiB / cylinder-8320 mark be formatted, mounted, and copied to identically to partitions at 1 GiB.

```swift
// RigidDiskBlock
public func byteOffset(forCylinder cylinder: UInt32) -> Int64 {
    Int64(cylinder) * Int64(blocksPerCylinder) * Int64(blockSize)
}
```

### Bitmap convention

The canonical Amiga FFS bitmap convention:

- Domain: `sectOfMap = blockNum - reserved` (blocks below `reserved` have no bitmap representation)
- Word index: `sectOfMap / 32` (word 0 = long immediately after the checksum at long[0])
- Bit position: `sectOfMap % 32`, LSB-first (`1 << bitPos`)
- Bit value: `1` = free, `0` = used

This is byte-for-byte compatible with the canonical adflib/Amiga layout. An LSB-first, reserved-offset bitmap is required for cross-engine safety: a misaligned bitmap causes one engine to misread another's "free"/"used" bits and overwrite live directory headers. The convention lives in `FFSAllocator` and `FFSFormatter.makeBitmapBlock`.

### On-mount bitmap repair

`FFSFileSystem.init` walks the full reachable directory tree and calls `allocator.markUsed()` on every entry block (directory headers, file headers, extension blocks). File data blocks are skipped — those are tracked correctly in the on-disk bitmap. This defense-in-depth pass ensures the allocator starts each session from a safe ground-truth state even if the on-disk bitmap is stale after a cross-engine write sequence.

## API reference

### BlockDevice

```swift
public final class BlockDevice {
    public let blockSize: Int
    public var size: Int64 { get throws }

    public init(url: URL, blockSize: Int = 512, readOnly: Bool = false) throws
    public static func createBlank(url: URL, sizeBytes: Int64) throws

    public func read(at offset: Int64, length: Int) throws -> Data
    public func readBlock(at lba: Int64) throws -> Data
    public func write(_ data: Data, at offset: Int64) throws
    public func writeBlock(_ data: Data, at lba: Int64) throws
}
```

The only I/O primitive. All higher layers take a `BlockDevice`; none open files directly.

### DiskGeometry

```swift
public struct DiskGeometry {
    public let cylinders: UInt32
    public let heads: UInt32     // always 16
    public let sectors: UInt32   // always 63 (sectors per track)
    public let blockSize: UInt32 // always 512

    public var blocksPerCylinder: UInt32  // 16 × 63 = 1008
    public var totalBlocks: UInt64
    public var totalBytes: Int64
    public var loCylinder: UInt32         // 2 (first usable cylinder)
    public var hiCylinder: UInt32         // cylinders - 1
    public var rdbBlockHi: UInt32         // 2015 (last RDB-reserved LBA)

    public init(sizeBytes: Int64, blockSize: UInt32 = 512,
                heads: UInt32 = 16, sectors: UInt32 = 63) throws
}
```

Geometry is derived from byte size by rounding down to the nearest full cylinder (standard Amiga RDB geometry, 16 × 63). Minimum 3 cylinders.

### DiskBuilder

```swift
public struct PartitionSpec {
    public let name: String
    public let dosType: UInt32          // use KnownDosType constants
    public let sizeCylinders: UInt32    // 0 = fill remaining space (last partition only)
    public let isBootable: Bool
    public let bootPriority: Int32
    public let sectorsPerFSBlock: UInt32 // 1=512B, 4=2048B FS blocks
}

public enum DiskLayout {
    case pureRDB(partitions: [PartitionSpec])
    case mbrPlusRDB(fatStartLBA: UInt32, fatSectorCount: UInt32,
                    rdbStartLBA: UInt32, partitions: [PartitionSpec])
}

public enum DiskBuilder {
    // Create a new blank image file and write the MBR (if MBR layout) + RDSK + PART chain.
    public static func build(url: URL, sizeBytes: Int64, layout: DiskLayout) throws

    // Rewrite RDSK + PART blocks in an existing image without touching other content.
    public static func reinitPartitions(
        url: URL,
        sliceStartLBA: Int64,
        sliceSizeBytes: Int64,
        partitions: [PartitionSpec]
    ) throws
}
```

`build` creates a zero-filled file and writes the partition table structure. It does not format the filesystems — call `FFSFormatter.format` (or the PFS3/FAT32 formatter) separately for each partition.

`reinitPartitions` rewrites only the RDSK + PART blocks at `sliceStartLBA`, leaving everything else (an existing FAT partition, pre-existing data) intact.

### DiskImage (auto-detect open)

```swift
public struct DiskInfo {
    public enum Layout {
        case mbrPlusRDB(mbr: MBRPartitionTable, rdbSlotIndex: Int, rdb: RigidDiskBlock)
        case pureRDB(rdb: RigidDiskBlock)
    }
    public let layout: Layout
    public var rdb: RigidDiskBlock { get }
}

public struct DiskImage {
    public static func open(url: URL) throws -> DiskInfo
}
```

Detection: read the first 512 bytes; if bytes 510–511 == `0x55 0xAA` → MBR present. Find the first MBR entry with type `0x76` (Amiga RDB slice) and scan RDSK at that LBA. If no MBR (or no `0x76` entry), treat the image as pure-RDB at LBA 0.

### RigidDiskBlock

```swift
public struct RigidDiskBlock {
    public let cylinders: UInt32
    public let sectors: UInt32      // sectors per track
    public let heads: UInt32
    public let blockSize: UInt32
    public let loCylinder: UInt32
    public let hiCylinder: UInt32
    public let rdbBlockHi: UInt32
    public var blocksPerCylinder: UInt32  // sectors × heads
    public var partitionBlocks: [PartitionBlock]
    public var fileSystemHeaders: [FileSystemHeaderBlock]

    public init(geometry: DiskGeometry, vendor: String = "AmigaDiskKit",
                product: String = "Virtual Disk", revision: String = "1.0")
    public func serialize(partitionListLBA: UInt32 = 0xFFFFFFFF,
                          fileSysHdrListLBA: UInt32 = 0xFFFFFFFF) -> Data

    public static func scan(device: BlockDevice, sliceStartLBA: Int64) throws -> RigidDiskBlock
    public func byteOffset(forCylinder cylinder: UInt32) -> Int64
}
```

`scan` searches the first 16 LBAs at `sliceStartLBA` for the `RDSK` identifier (`0x5244534B`), validates the Amiga checksum, then traverses the PART and FSHD linked lists (up to 256 entries each). It stops gracefully on a short read (truncated fixtures).

### PartitionBlock

```swift
public struct PartitionBlock {
    public let driveName: String         // e.g. "DH0", "SDH1"
    public let dosType: UInt32
    public let lowCyl: UInt32
    public let highCyl: UInt32
    public let surfaces: UInt32          // heads
    public let blocksPerTrack: UInt32    // sectors per track
    public let sectors: UInt32           // de_SectorsPerBlock (FS granularity multiplier)
    public let reserved: UInt32          // reserved blocks at partition start (always 2)
    public let fileSystemBlockSize: UInt32 // sectors × 512
    public let bootPriority: Int32
    public var isBootable: Bool
    public var noMount: Bool
    public var dosTypeFormatted: String  // e.g. "DOS\3"
    public var dosTypeHex: String        // e.g. "0x444F5303"

    public func startByteOffset(rdb: RigidDiskBlock) -> Int64
    public func endByteOffset(rdb: RigidDiskBlock) -> Int64

    public init(name: String, dosType: UInt32, lowCyl: UInt32, highCyl: UInt32,
                geometry: DiskGeometry, isBootable: Bool = false,
                bootPriority: Int32 = 0, sectorsPerFSBlock: UInt32 = 1)
    public func serialize(next: UInt32 = 0xFFFFFFFF) -> Data
}

public struct KnownDosType {
    public static let dos0: UInt32 = 0x444F5300  // OFS (no-intl)
    public static let dos1: UInt32 = 0x444F5301  // OFS + INTL
    public static let dos3: UInt32 = 0x444F5303  // FFS
    public static let dos5: UInt32 = 0x444F5305  // FFS + INTL
    public static let dos7: UInt32 = 0x444F5307  // FFS2 (large partition)
    public static let pds3: UInt32 = 0x50445303  // PFS3
    public static func isOFS(_ dosType: UInt32) -> Bool
    public static func isFFS(_ dosType: UInt32) -> Bool
    public static func isPFS3(_ dosType: UInt32) -> Bool
}
```

### FFSFormatter

```swift
public struct FFSFormatSpec {
    public var volumeName: String
    public var creationDate: Date
    public init(volumeName: String = "Empty", creationDate: Date = Date())
}

public enum FFSFormatter {
    // Compute layout geometry without I/O (used by FFSFileSystem.init too)
    public static func layout(partition: PartitionBlock, rdb: RigidDiskBlock) -> FFSLayout

    // Write boot block + bitmap blocks + bitmap extension blocks + root block
    public static func format(
        device: BlockDevice,
        sliceStartLBA: Int64 = 0,
        partition: PartitionBlock,
        rdb: RigidDiskBlock,
        spec: FFSFormatSpec = FFSFormatSpec()
    ) throws
}
```

`format` writes the four categories of FFS metadata blocks (boot, bitmap, bitmap extension, root). It does not touch data blocks. The bitmap is initialized with all writable blocks marked free, except the 2 reserved blocks at partition start, all bitmap blocks, all bitmap extension blocks, and the root block.

Block layout follows the Amiga standard:
- Boot block: FS blocks 0–1 (always 1024 bytes = 2 physical sectors)
- Bitmap blocks: FS blocks 2, 3, … (one per `bitsPerBitmapBlock` FS blocks; 25 fit in the root block directly)
- Bitmap extension blocks: follow bitmap blocks when more than 25 are needed
- Root block: FS block `totalFSBlocks / 2`

### FFSFileSystem

```swift
public final class FFSFileSystem {

    // Open a named partition in a disk image (auto-detects MBR+RDB or pure-RDB)
    public static func open(imageURL: URL, partitionName: String,
                            sliceStartLBA: Int64? = nil) throws -> FFSFileSystem

    // Open a flat ADF file (880 KB DD or 1760 KB HD; FFS or OFS)
    public static func openADF(url: URL) throws -> FFSFileSystem

    // Directory operations
    public func listDirectory(path: String = "") throws -> [FFSEntry]
    public func listRecursive(path: String = "") throws -> [String]  // one relative path per line
    public func makeDirectory(path: String) throws  // mkdir -p semantics

    // File operations
    public func writeFile(path: String, data: Data, overwrite: Bool = false) throws
    public func readFile(path: String) throws -> Data

    // Host ↔ image transfer
    public func copyFromHost(hostURL: URL, amigaPath: String) throws
    public func extractToHost(amigaPath: String, hostURL: URL) throws

    // Deletion
    public func delete(path: String) throws  // silently succeeds if not found

    // Commit bitmap changes — MUST be called after all write operations
    public func flush() throws
}
```

**Path conventions** — `/` separator (`"S/Startup-Sequence"`); root is `""` or `"/"`; case-insensitive (FFS standard); `makeDirectory` is `mkdir -p`; `writeFile` with `overwrite: true` deletes the existing file first; `delete` is not recursive (deleting a non-empty directory orphans its contents).

**OFS support** — when `partition.dosType` is OFS (DOS\0 / DOS\1), data-block assembly checks the block type field (`T_DATA = 8`) at read time, so OFS ADFs that store raw data without the 24-byte OFS header are detected by content rather than the boot-block DOS type.

**`flush()` contract** — the allocator holds bitmap changes in memory. Every session that calls any write operation (`writeFile`, `makeDirectory`, `copyFromHost`, `delete`) must call `flush()` before closing, or the on-disk bitmap is left inconsistent.

#### FFSEntry

```swift
public struct FFSEntry {
    public enum Kind { case directory; case file }
    public let kind: Kind
    public let name: String
    public let fsBlock: UInt32
    public let parent: UInt32
    public let hashChain: UInt32
    public let protect: UInt32
    public let byteSize: UInt32     // 0 for directories
    public let comment: String
    public let days: UInt32         // Amiga epoch (Jan 1 1978)
    public let mins: UInt32
    public let ticks: UInt32        // 50 ticks per second
    public let highSeq: UInt32
    public let extension_: UInt32
    public let dataPtrs: [UInt32]   // file only
    public let hashTable: [UInt32]  // directory only
    public var isDirectory: Bool
    public var isFile: Bool
}
```

### LHAArchive

```swift
public struct LHAMember {
    public let path: String
    public let isDirectory: Bool
    public let originalSize: Int
    public let method: String   // "-lh0-", "-lh5-", "-lh6-", "-lh7-"
}

public struct LHAArchive {
    public let members: [LHAMember]
    public init(url: URL) throws
    public func extract(to hostURL: URL) throws
}
```

Supports LHA header levels 0, 1, and 2. Methods: `-lh0-`/`-lzs-` (stored), `-lh5-` (13-bit dict), `-lh6-` (15-bit), `-lh7-` (16-bit). CRC-16 verified per member. Path sanitization strips `..` and `.` components and normalizes `\` to `/`.

### MBRPartitionTable

```swift
public struct MBRPartitionEntry {
    public let status: UInt8        // 0x80 = bootable
    public let partitionType: UInt8 // 0x0B/0x0C = FAT32, 0x76 = Amiga RDB slice
    public let lbaStart: UInt32
    public let lbaSectors: UInt32
    public var startByte: Int64
    public var endByte: Int64
    public var isBootable: Bool
    public var isEmpty: Bool
}

public struct MBRPartitionTable {
    public let partitions: [MBRPartitionEntry]  // always 4 entries
    public init(data: Data) throws
    public static func serialize(entries: [MBREntrySpec]) -> Data
}
```

PiStorm images use MBR slot 0 for the FAT32 boot partition (type `0x0C`, bootable) and slot 1 for the Amiga RDB slice (type `0x76`).

### AmigaDiskError

```swift
public enum AmigaDiskError: Error, CustomStringConvertible {
    // I/O
    case readFailed(offset: Int64, length: Int, reason: String)
    case writeFailed(offset: Int64, length: Int, reason: String)
    case imageTooSmall(required: Int64, actual: Int64)

    // MBR
    case invalidMBRSignature(found: UInt16)
    case mbrPartitionOutOfBounds(index: Int)

    // RDB
    case rdskNotFound
    case rdskChecksumMismatch(block: Int, expected: Int32, calculated: Int32)
    case partitionBlockChecksumMismatch(block: UInt32)
    case rdskBlockOutOfRange(block: UInt32, rdbBlockHi: UInt32)

    // FFS
    case invalidBootBlock(dosType: [UInt8])
    case invalidRootBlock(offset: UInt32)
    case rootBlockChecksumMismatch(offset: UInt32, expected: Int32, calculated: Int32)
    case pathNotFound(path: String)
    case notADirectory(path: String)
    case notAFile(path: String)
    case entryExists(path: String)
    case unsupportedDosType(UInt32)

    // Geometry
    case partitionOffsetOverflow(lowCyl: UInt32, blocksPerCylinder: UInt32, blockSize: UInt32)
    case invalidGeometry(reason: String)
}
```

## CLI reference

`AmigaDiskCLI` is a standalone command-line front-end built by the package.

```
disk info       <image>                                     — disk size and MBR table
disk rdb-info   <image>                                     — RDSK geometry, FSHD, PART list
disk rdb-build  <image> <size-bytes> [--mbr --fat-lba N
                 --fat-sectors N --rdb-lba N]
                 --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]...
disk rdb-reinit <image> [--slice-lba N]
                 --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]...
disk rdb-format <image> <partition-name> [<volume-name>] [--slice-lba N]
disk rdb-fs-add <image> <fs-binary> <dostype> [--name X]
                 [--fs-version maj.min] [--replace] [--slice-lba N]
disk fat-format <image> <volume-label> [--mbr-index N]
disk fs dir     <image> <partition> [<path>] [--recursive] [--slice-lba N]
disk fs exists  <image> <partition> <path>   [--slice-lba N]
disk fs mkdir   <image> <partition> <path>   [--slice-lba N]
disk fs copy    <image> <partition> <host-src> <amiga-dst> [--slice-lba N]
disk fs copydir <image> <partition> <host-src> <amiga-dst> [--slice-lba N]
disk fs extract <image> <partition> <amiga-src> <host-dst> [--slice-lba N]
disk fs delete  <image> <partition> <amiga-path> [--slice-lba N]
disk fat ...    <image> ...                   — FAT32 listing/copy on the boot partition
adf extract     <adf-file> <host-dest>
```

`rdb-format` and `fs` dispatch by partition dostype: PDS\3 partitions use the native PFS3 engine, everything else FFS. `rdb-fs-add` embeds a handler binary (FFS DOS7, pfs3aio PDS3) into the RDB FSHD/LSEG chain.

**`--slice-lba` flag** — all `disk rdb-*` and `disk fs` commands auto-detect the RDB slice start: if the image has a valid MBR with a type-`0x76` entry, that entry's `lbaStart` is used. Pass `--slice-lba N` to override.

**Partition spec format** — `name:dostype[:cyls[:boot[:priority[:sectorsPerFSBlk]]]]`
- `dostype` — symbolic (`DOS1`, `DOS3`, `DOS5`, `DOS7`, `PDS3`) or hex (`0x444F5307`)
- `cyls` — cylinder count; `0` or omitted = fill remaining space (last partition only)
- `boot` — `boot` or `1` to set bootable; omit for non-bootable
- `priority` — boot priority (default 0)
- `sectorsPerFSBlk` — FS block size multiplier: `1`=512 B, `4`=2048 B (default 1)

```bash
# PiStorm: 2 GB boot (DOS\3, 2048-byte blocks) + fill remaining (DOS\7, 2048-byte blocks)
disk rdb-build Amiga.img 32212254720 --mbr \
  --fat-lba 2048 --fat-sectors 2097152 --rdb-lba 2099200 \
  --part SDH0:DOS3:4165:boot:0:4 \
  --part SDH1:DOS7:0:0:0:4

# Classic: 2 GB DH0 + fill remaining DH1
disk rdb-build ClassicAmiga.img 8589934592 \
  --part DH0:DOS3:4165:boot:0:4 \
  --part DH1:DOS7:0:0:0:4
```

## Format details

### Checksums

Three distinct checksum algorithms are used:

- **Amiga RDSK / PART checksum** (`embedAmigaChecksum`) — sum all 32-bit big-endian words in the block (the checksum word counts as 0 when computing). The checksum word is set so the total is 0 in 32-bit arithmetic. Stored at byte offset 0x08.
- **FFS block checksum** (`embedFFSBlockChecksum`) — same algorithm for directory / file-header / root blocks. Stored at long[5] (byte offset 20).
- **FFS boot block checksum** (`embedFFSBootBlockChecksum`) — accumulate 32-bit big-endian words including carry (`sum += word; if sum < word: sum++`). The checksum word (byte offset 4) is set so the full result is 0. Matches adflib's boot-block verification.

### Geometry

Standard RDB geometry: **16 heads × 63 sectors/track = 1008 blocks/cylinder**. Reserved cylinders 0 and 1 cover the RDSK block at slice LBA 0 plus PART blocks at slice LBAs 3, 4, …. `loCylinder = 2`, `rdbBlockHi = 2 × 1008 − 1 = 2015`.

FS block sizes: DOS\3 (FFS) = 512-byte FS blocks; DOS\7 (FFS2) = 2048-byte FS blocks. FFS2 (DOS\7) is required for data partitions > 2 GiB because the 32-bit block count in the FFS root block otherwise overflows.

## Known limitations

- **Hard / soft links** — `markReachableEntryBlocksUsed` marks them used but does not follow them for I/O. The blocks are protected from allocation; link I/O is not implemented.
- **Non-recursive delete** — `FFSFileSystem.delete` on a directory frees only the directory block itself; sub-entries are orphaned. Callers that need recursion delete post-order.
- **ADF write via `FFSFileSystem`** — `openADF` defaults to read-only. Whole-disk ADF write (e.g. real-floppy round-trips) goes through `Floppy/ADFFloppyImage`, not `FFSFileSystem`.

## Testing

```bash
# Run all tests
swift test --package-path AmigaDiskKit

# A single test class
swift test --package-path AmigaDiskKit --filter FFSFileSystemTests
```

237 tests across 26 files. Binary fixtures in `Tests/AmigaDiskKitTests/Fixtures/binary/` are `dd`-extracted RDB areas and boot blocks from known-good reference images; golden text fixtures in `Fixtures/golden/` are reference `info` / `rdb info` output for the same images.

## Requirements

- Swift 5.9+
- macOS 13+
- No third-party dependencies

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

AmigaDiskKit is the disk-image engine behind **[AmigaImager](https://www.Amiga-Imager.com)**. Block layouts and on-disk parity were cross-checked against [hst-imager](https://github.com/henrikstengaard/hst-imager) as a reference implementation.
