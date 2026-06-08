# AmigaDiskKit

A native Swift library for reading and writing Amiga disk images. Parses and creates MBR + RDB disk layouts, formats and mounts FFS/FFS2 partitions, and reads ADF and LHA archives — all without any external tools or Python runtime.

## Goal

AmigaDiskKit was created to replace [hst-imager](https://github.com/henrikstengaard/hst-imager) as the disk-image backend for AmigaImager. hst-imager has two known bugs that block large-disk workflows:

**Bug 1** — `rdb part format` silently writes a zero boot block for FFS partitions > 2 GiB (mitigated by upgrading those partitions to DOS\7 before format).

**Bug 2** — `FastFileSystemHelper.Mount` computes `bootBlockOffset = lowCyl × surfaces × blocksPerTrack × blockSize` in `uint32`, which wraps for `lowCyl >= 8321`. Any partition starting beyond ~4.3 GiB (cylinder 8320) is unreachable for file I/O — `fs dir` and `fs copy` throw `Invalid fast file system dos type '00000000' in boot block`. The format step uses `int64` and writes the correct boot block; only the mount/verify/copy path is broken.

AmigaDiskKit uses `Int64` for every byte-offset calculation, end-to-end. There is no `UInt32` arithmetic in any I/O path. Partitions starting at 154 GiB (the Phase 6 validation maximum) work identically to partitions at 1 GiB.

The v1.0 goal is that hst-imager becomes an optional user-facing fallback — not a required runtime dependency. AmigaImager builds must complete with `DISK_ENGINE=amigadiskkit` even if hst-imager is not installed.

## Current Status (2026-06-08)

**Phase 7 complete.** Full dispatch coverage in AmigaImager. All RDB partition I/O routes through AmigaDiskKit when `DISK_ENGINE=amigadiskkit`.

### What works

| Capability | Status |
|---|---|
| MBR parse + write (PiStorm layout) | ✅ |
| Pure-RDB parse + write (Classic / MiSTer HDF) | ✅ |
| RDB geometry, RDSK / PART / FSHD block parse | ✅ |
| Create blank image with RDB (`rdb-build`) | ✅ |
| Rewrite RDB in existing image (`rdb-reinit`) | ✅ |
| FFS / FFS2 format (DOS\3 / DOS\7) | ✅ |
| FFS / FFS2 directory listing, mkdir -p | ✅ |
| FFS / FFS2 file read + write | ✅ |
| Host → image copy (file or directory tree) | ✅ |
| Image → host extract (file or directory tree) | ✅ |
| Image path delete (file or directory) | ✅ |
| Recursive directory listing | ✅ |
| ADF extract (FFS and OFS, DD and HD) | ✅ |
| LHA archive read (lh0 / lh5 / lh6 / lh7) | ✅ |
| Bitmap cross-engine compatibility (LSB-first, reserved-offset) | ✅ |
| On-mount bitmap repair (walk reachable tree, mark all entry blocks used) | ✅ |

### Remaining before v1.0

| Item | Notes |
|---|---|
| FAT32 write | PiStorm boot partition (`mbr/1/`); needs native FAT32 write support |
| LHA extraction in build pipeline | `extract_lha_to_host` uses system `lha` binary + hst fallback; native decoder exists but not yet integrated |
| PFS3 format | Phase 9 decision gate; `rdb fs add` is the only blocker |

### Validation history

Five production builds (Phase 6, 2026-06-07) confirm end-to-end correctness across all three platforms and the Bug 2 trigger condition:

- **Pass 4** — PiStorm, 3-partition 127 GB image, custom partition names (`WORK0`/`WORK1`/`WORK2`), `WORK1` starting at byte 4,296,499,200 (LowCyl 8325 — past the Bug 2 threshold). A recursive `amiga-tools disk fs copy` wrote 2.9 GB across 3,552 files / 246 directories onto `WORK1`. Zero errors. ✅
- **Pass 5** — Identical setup with `DISK_ENGINE=hst` (control run). hst-imager throws `Invalid fast file system dos type '00000000'` on `WORK1`. Build fails. ❌

This is the definitive before-and-after: same partition, same payload, native engine ✅ vs hst-imager ❌.

## Package layout

```
AmigaDiskKit/
  Package.swift
  Sources/
    AmigaDiskKit/
      ImageIO/
        BlockDevice.swift       — raw byte/block I/O over a flat image file
        DiskGeometry.swift      — CHS geometry (16 heads × 63 sectors = 1008 blocks/cyl)
        DiskBuilder.swift       — create blank images with MBR + RDB or pure RDB
      MBR/
        MBRPartitionTable.swift — MBR parse + serialize
      RDB/
        RigidDiskBlock.swift    — RDSK parse + serialize + linked-list scan
        PartitionBlock.swift    — PART parse + serialize; KnownDosType constants
        FileSystemHeaderBlock.swift — FSHD + LSEG parse
      FFS/
        FFSFormat.swift         — FFS / FFS2 format (boot block, bitmap, root block)
        FFSAllocator.swift      — bitmap-based block allocator (LSB-first, canonical Amiga)
        FFSFileSystem.swift     — mounted FFS: list, mkdir, read/write, copy, extract, delete
        FFSEntry.swift          — directory entry parse; ffsHashName()
        FFSVolume.swift         — FFSVolume, RootBlock, FFSBootBlock
      LHA/
        LHAArchive.swift        — LHA archive reader (level 0/1/2, lh0/lh5/lh6/lh7)
        LHDecoder.swift         — LZH sliding-window decompressor
      Parsing/
        AmigaChecksum.swift     — Amiga RDSK/PART checksum; FFS block checksum; boot block checksum
        Data+Parsing.swift      — BE8/BE16/BE32/LE16/LE32 read; readBSTR; readAmigaString
        Data+Writing.swift      — BE8/BE16/BE32/LE16/LE32 write; writeBSTR; writeAmigaString
      Diagnostics/
        AmigaDiskError.swift    — typed error enum
      DiskImage.swift           — top-level auto-detect open (MBR+RDB or pure-RDB)
    AmigaDiskCLI/
      main.swift                — standalone CLI (disk info/rdb-info/rdb-build/rdb-reinit/rdb-format/fs/adf)
  Tests/
    AmigaDiskKitTests/
      DiskImageParserTests.swift — MBR + RDB golden-output tests
      RDBParserTests.swift       — RDSK / PART / FSHD parse tests
      RDBWriterTests.swift       — round-trip write tests (DiskBuilder)
      FFSFormatterTests.swift    — FFS / FFS2 format tests
      FFSFileSystemTests.swift   — mkdir, writeFile, copyFromHost, extractToHost, delete
      Fixtures/
        binary/                  — dd-extracted RDB areas and boot blocks from known-good images
        golden/                  — hst-imager reference text output for comparison
```

## Architecture

### Layers (bottom to top)

```
BlockDevice          — raw I/O; Int64 offsets everywhere
  ↓
MBRPartitionTable    — parse / write MBR first sector
RigidDiskBlock       — scan first 16 LBAs for RDSK; traverse PART + FSHD lists
DiskGeometry         — CHS geometry from byte size (16 × 63 = 1008 blocks/cyl)
DiskBuilder          — orchestrate: blank file → MBR → RDSK → PART chain
  ↓
FFSFormatter         — write boot block, bitmap blocks, root block onto a PART
FFSAllocator         — load live bitmap from disk; allocate / free / markUsed; flush
FFSFileSystem        — high-level ops: list, mkdir, writeFile, copyFromHost, extractToHost, delete
  ↓
AmigaDiskCLI         — CLI front-end (disk / adf subcommands)
```

### Key invariant: Int64 offsets

Every byte-offset calculation uses `Int64`, including partition start (`lowCyl × blocksPerCylinder × 512`). No `UInt32` arithmetic appears in any I/O path. This is the core fix for hst-imager Bug 2.

```swift
// RigidDiskBlock
public func byteOffset(forCylinder cylinder: UInt32) -> Int64 {
    Int64(cylinder) * Int64(blocksPerCylinder) * Int64(blockSize)
}
```

### Bitmap convention

The canonical Amiga FFS bitmap convention (confirmed byte-for-byte against hst-amiga `Bitmap.cs`):

- Domain: `sectOfMap = blockNum - reserved` (blocks below `reserved` have no bitmap representation)
- Word index: `sectOfMap / 32` (word 0 = long immediately after the checksum at long[0])
- Bit position: `sectOfMap % 32`, LSB-first (`1 << bitPos`)
- Bit value: `1` = free, `0` = used

A previous version used MSB-first, no `reserved` offset. It was internally self-consistent but byte-incompatible with hst-imager — every "free"/"used" bit one engine wrote was misread by the other as describing a different block, causing cross-engine overwrites of live directory headers (observed as `Invalid entry block type` during Aminet package installs). The fix is in `FFSAllocator` and `FFSFormatter.makeBitmapBlock`.

### On-mount bitmap repair

`FFSFileSystem.init` always walks the full reachable directory tree and calls `allocator.markUsed()` on every entry block (directory headers, file headers, extension blocks) it encounters. File data blocks are skipped — those are correctly tracked in the on-disk bitmap. This defense-in-depth pass ensures that even if the on-disk bitmap is stale after a cross-engine write sequence, the allocator starts each AmigaDiskKit session from a safe ground-truth state.

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

Geometry is derived from byte size by rounding down to the nearest full cylinder. Matches hst-imager's standard geometry (16 × 63). Minimum 3 cylinders.

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
    // Use this when the FAT partition was created by another tool (hst-imager --format PiStorm).
    public static func reinitPartitions(
        url: URL,
        sliceStartLBA: Int64,
        sliceSizeBytes: Int64,
        partitions: [PartitionSpec]
    ) throws
}
```

`build` creates a zero-filled file and writes the partition table structure. It does not format the filesystems — call `FFSFormatter.format` separately for each partition.

`reinitPartitions` rewrites only the RDSK + PART blocks at `sliceStartLBA`, leaving everything else (FAT, pre-existing data) intact. Used by the PiStorm build pipeline to replace hst-imager's `rdb part delete × 15 + rdb part add × N` sequence.

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

Detection: read first 512 bytes; if bytes 510–511 == `0x55 0xAA` → MBR present. Find first MBR entry with type `0x76` (Amiga RDB slice). Scan RDSK at that LBA. If no MBR (or no `0x76` entry), treat as pure-RDB at LBA 0.

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

    // Construction (for writing)
    public init(geometry: DiskGeometry, vendor: String = "AmigaDiskKit",
                product: String = "Virtual Disk", revision: String = "1.0")
    public func serialize(partitionListLBA: UInt32 = 0xFFFFFFFF,
                          fileSysHdrListLBA: UInt32 = 0xFFFFFFFF) -> Data

    // Parsing (for reading)
    public static func scan(device: BlockDevice, sliceStartLBA: Int64) throws -> RigidDiskBlock
    public func byteOffset(forCylinder cylinder: UInt32) -> Int64
}
```

`scan` searches the first 16 LBAs at `sliceStartLBA` for the `RDSK` identifier (`0x5244534B`), validates the Amiga checksum, then traverses the PART and FSHD linked lists (up to 256 entries each). Gracefully stops on short read (truncated fixtures).

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

    // Construction (for writing)
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

public struct FFSLayout {
    public let totalFSBlocks: Int
    public let rootBlockFSBlock: Int
    public let bitmapBlockFSBlocks: [Int]
    public let bitmapExtFSBlocks: [Int]
    public let reserved: Int            // always 2
    public let fsBlockSize: Int         // 512 (DOS\3) or 2048 (DOS\7)
    public let bitsPerBitmapBlock: Int
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

`format` writes the four categories of FFS metadata blocks. It does not touch data blocks. The bitmap is initialized with all writable blocks marked free, except: the 2 reserved blocks at partition start, all bitmap blocks, all bitmap extension blocks, and the root block.

Block layout follows the Amiga standard:
- Boot block: FS blocks 0–1 (always 1024 bytes = 2 physical sectors)
- Bitmap blocks: FS blocks 2, 3, … (one per `bitsPerBitmapBlock` FS blocks; 25 fit in root block directly)
- Bitmap extension blocks: follow bitmap blocks when more than 25 bitmap blocks are needed
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

#### Path conventions

- All paths use `/` as separator: `"S/Startup-Sequence"`, `"Devs/Monitors"`.
- The volume root is `""` or `"/"`.
- Paths are case-insensitive (FFS standard).
- `makeDirectory` is mkdir -p: creates intermediate components, no-ops on existing directories.
- `writeFile` with `overwrite: true` deletes the existing file before writing.
- `delete` is not recursive: deleting a non-empty directory orphans its contents.

#### OFS support

When `partition.dosType` is OFS (DOS\0 / DOS\1), `isOFS = true`. Data block assembly checks the block type field (`T_DATA = 8`) at read time — some OFS ADFs (e.g. WB3.2 ADF labeled DOS\1) store raw data without the 24-byte OFS header and are detected by the actual block content, not the boot block DOS type.

#### `flush()` contract

The allocator holds bitmap changes in memory. Every session that calls any write operation (writeFile, makeDirectory, copyFromHost, delete) must call `flush()` before closing. Missing `flush()` leaves the bitmap inconsistent on disk.

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

#### FFS hash function

```swift
public func ffsHashName(_ name: String, htSize: Int) -> Int
```

Standard Amiga FFS hash: ASCII toupper, accumulate `hash = hash * 13 + char`, mask to 11 bits, modulo htSize. Used for directory lookup and insertion.

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

Supports LHA header levels 0, 1, and 2. Compression methods: `-lh0-`/`-lzs-` (stored), `-lh5-` (13-bit dict), `-lh6-` (15-bit), `-lh7-` (16-bit). CRC-16 verified per member. Path sanitization strips `..` and `.` components and normalizes `\` to `/`.

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

## CLI reference (`AmigaDiskCLI`)

The standalone CLI included in the package. In AmigaImager it is compiled as `amiga-tools` and bundled in `Contents/Resources/`.

```
disk info   <image>                                         — disk size and MBR table
disk rdb-info <image>                                       — RDSK geometry, FSHD, PART list
disk rdb-build <image> <size-bytes> [--mbr --fat-lba N
                --fat-sectors N --rdb-lba N]
                --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]...
disk rdb-reinit <image> [--slice-lba N]
                --part name:dostype[:cyls[:boot[:pri[:fsblk]]]]...
disk rdb-format <image> <partition-name> [<volume-name>] [--slice-lba N]
disk fs dir     <image> <partition> [<path>] [--recursive] [--slice-lba N]
disk fs mkdir   <image> <partition> <path>   [--slice-lba N]
disk fs copy    <image> <partition> <host-src> <amiga-dst> [--slice-lba N]
disk fs extract <image> <partition> <amiga-src> <host-dst> [--slice-lba N]
disk fs delete  <image> <partition> <amiga-path> [--slice-lba N]
adf extract     <adf-file> <host-dest>
```

### `--slice-lba` flag

All `disk rdb-*` and `disk fs` commands auto-detect the RDB slice start: if the image has a valid MBR with a type-`0x76` entry, that entry's `lbaStart` is used. Pass `--slice-lba N` to override (e.g. when calling from a script that already knows the offset).

### Partition spec format

`name:dostype[:cyls[:boot[:priority[:sectorsPerFSBlk]]]]`

- `dostype` — symbolic (`DOS1`, `DOS3`, `DOS5`, `DOS7`, `PDS3`) or hex (`0x444F5307`)
- `cyls` — cylinder count; `0` or omitted = fill remaining space (last partition only)
- `boot` — `boot` or `1` to set bootable flag; omit for non-bootable
- `priority` — boot priority (default 0)
- `sectorsPerFSBlk` — FS block size multiplier: `1`=512 B, `4`=2048 B (default 1)

Examples:
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

### `disk fs dir` on file paths

`disk fs dir <image> <partition> <path>` exits 0 if `<path>` exists as either a file or directory. When `<path>` names a file, it prints a single-row listing. When `<path>` names a directory, it lists the directory contents. Non-zero exit = not found.

### `disk fs dir --recursive`

Outputs one relative path per line (files and directories interleaved). No header row. Used by the `fs_list_recursive` dispatch wrapper in `common.sh` to enumerate image contents.

## Checksums

Three distinct checksum algorithms are used:

**Amiga RDSK / PART checksum** (`embedAmigaChecksum`): Sum all 32-bit big-endian words in the block (including the checksum word itself, treated as 0 when computing). The checksum word is set so the sum equals 0 in 32-bit arithmetic (i.e. it holds the two's-complement negation of the sum of all other words). Stored at byte offset 0x08 in RDSK/PART blocks.

**FFS block checksum** (`embedFFSBlockChecksum`): Same algorithm but for directory / file-header / root blocks. Stored at long[5] (byte offset 20) in FFS blocks.

**FFS boot block checksum** (`embedFFSBootBlockChecksum`): Different algorithm — accumulate 32-bit big-endian words including carry: `sum += word; if sum < word: sum++`. The checksum word (at byte offset 4) is set so the full result is 0. This matches adflib and hst-imager's boot block verification.

## Geometry details

Standard RDB geometry used throughout: **16 heads × 63 sectors/track = 1008 blocks/cylinder**.

Reserved cylinders: 0 and 1 (covers the RDSK block at slice LBA 0, plus PART blocks at slice LBAs 3, 4, …). `loCylinder = 2`, `rdbBlockHi = 2 × 1008 − 1 = 2015`.

FS block sizes:
- DOS\3 (FFS): 1 sector/FS block = 512-byte FS blocks
- DOS\7 (FFS2): 4 sectors/FS block = 2048-byte FS blocks

FFS2 (DOS\7) is required for data partitions > 2 GiB because the 32-bit block count in the FFS root block otherwise overflows. AmigaImager auto-upgrades large data partitions to DOS\7 before format.

## Known limitations

- **FAT32**: read-only (MBR entry parsed, FAT sector not read). Writing the PiStorm boot partition remains on hst-imager.
- **PFS3**: not supported. Partitions with DOS type PDS\3 are detected but cannot be formatted or mounted. The build pipeline falls back to hst-imager for any layout that includes a PFS3 partition.
- **Hard links / soft links**: `markReachableEntryBlocksUsed` marks them used but does not follow them for I/O. This is safe; the blocks are protected from allocation. Hard/soft link I/O is not implemented.
- **Non-recursive delete**: `FFSFileSystem.delete` on a directory frees only the directory block itself. Sub-entries are orphaned (not freed). This matches the build pipeline's usage: files are deleted, never non-empty directories.
- **Write to ADF**: `openADF` opens a read-only `BlockDevice`. ADF write is not implemented.

## Testing

```bash
# Run all tests
swift test --package-path AmigaDiskKit

# Specific test class
swift test --package-path AmigaDiskKit --filter FFSFileSystemTests
```

Test count: 88+ tests across 5 test files. Binary fixtures in `Tests/AmigaDiskKitTests/Fixtures/binary/` are dd-extracted RDB areas and boot blocks from real AmigaImager builds (hst-imager v1.5.564 reference). Golden text fixtures in `Fixtures/golden/` are hst-imager `info` and `rdb info` output for the same images.

## Requirements

- Swift 5.9+
- macOS 13+
- No third-party dependencies
