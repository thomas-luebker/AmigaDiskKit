# AmigaDiskKit Test Fixtures

Phase 0 corpus captured 2026-06-04/05 from known-good Amiga-Imager builds (hst-imager v1.5.564).

## Coverage

| Platform | Image | Status |
|----------|-------|--------|
| MiSTer Minimig | `mister-8g-hdf` | ✅ captured |
| PiStorm / Emu68 (8 GB) | `pistorm-8g-img` | ✅ captured |
| PiStorm / Emu68 (29 GB, 2-partition) | `pistorm-29g-img` | ✅ captured 2026-06-05 |
| PiStorm / Emu68 (7 GB, 3-partition overflow) | `pistorm-7g-3part` | ✅ captured 2026-06-05 |
| Classic Amiga (pure RDB) | `classic-8g-img` | ✅ captured |

## Golden Text Outputs (`golden/`)

Captured via `hst-imager info` and `hst-imager rdb info`. Used for:
- verifying parser output matches known-good reference
- catching regressions in geometry and partition metadata

| File | Command | Description |
|------|---------|-------------|
| `mister-8g-hdf-rdb-overview.txt` | `hst-imager info` | Disk overview, pure RDB |
| `mister-8g-hdf-rdb-detail.txt` | `hst-imager rdb info` | Full RDB + partition detail |
| `pistorm-8g-img-mbr-info.txt` | `hst-imager info` | Disk overview, MBR layout (8 GB) |
| `pistorm-8g-img-mbr-detail.txt` | `hst-imager mbr info` | MBR + FAT32 + RDB slot detail (8 GB) |
| `pistorm-8g-img-rdb-info.txt` | `hst-imager rdb info` | Full RDB inside PiStorm MBR slot (8 GB) |
| `pistorm-29g-img-mbr-info.txt` | `hst-imager info` | Disk overview, MBR layout (29 GB, 2-partition) |
| `pistorm-29g-img-rdb-info.txt` | `hst-imager rdb info` | Full RDB (29 GB): SDH0 DOS\3 2 GB + SDH1 DOS\7 25.8 GB |
| `pistorm-7g-3part-img-mbr-info.txt` | `hst-imager info` | Disk overview (7 GB, 3-partition) |
| `pistorm-7g-3part-img-rdb-info.txt` | `hst-imager rdb info` | SDH0 DOS\3 + SDH1 DOS\7 + SDH2 DOS\3 (LowCyl=10372, start ~5 GiB — overflow fixture) |
| `classic-8g-img-rdb-overview.txt` | `hst-imager info` | Disk overview, pure RDB, no MBR |
| `classic-8g-img-rdb-detail.txt` | `hst-imager rdb info` | Full RDB + partition detail (DH0 DOS\3, DH1 DOS\7) |

## Binary Fixtures (`binary/`)

Extracted with `dd`. Used for:
- round-trip parse/write tests without needing full disk images
- testing specific byte-level correctness (checksums, signatures)

### MiSTer (pure RDB, FFS)
| File | Source offset | Size | Contents |
|------|--------------|------|----------|
| `mister-8g-rdb-area.bin` | LBA 0, 64 sectors | 32 KB | Full RDB area (RDSK + PART + FSHD blocks) |
| `mister-8g-dh0-bootblock.bin` | LBA 2016, 8 sectors | 4 KB | DH0 boot block (DOS\3 FFS, 2048-byte FS blocks) |

### PiStorm 8g (MBR + FAT32 + RDB slice)
| File | Source offset | Size | Contents |
|------|--------------|------|----------|
| `pistorm-mbr.bin` | LBA 0, 1 sector | 512 B | MBR (partition table + 0x55AA signature) |
| `pistorm-fat32-boot-sector.bin` | LBA 2048, 1 sector | 512 B | FAT32 boot sector (VBR) |
| `pistorm-rdb-area.bin` | LBA 2097153, 64 sectors | 32 KB | RDB area inside MBR slot 1 (RDSK + PART blocks) |
| `pistorm-dh0-bootblock.bin` | LBA 2099169, 2 sectors | 1 KB | DH0 boot block (DOS\3 FFS) |

### PiStorm 29g — large image, 2-partition (MBR + FAT32 + RDB slice)
| File | Source offset | Size | Contents |
|------|--------------|------|----------|
| `pistorm-29g-mbr.bin` | LBA 0, 1 sector | 512 B | MBR (0x55AA signature) |
| `pistorm-29g-fat32-boot-sector.bin` | LBA 2048, 1 sector | 512 B | FAT32 VBR |
| `pistorm-29g-rdb-area.bin` | LBA 2097153, 64 sectors | 32 KB | RDB area (RDSK + 2×PART blocks) |
| `pistorm-29g-sdh0-bootblock.bin` | LBA 2099169, 8 sectors | 4 KB | SDH0 boot block (DOS\3 FFS, 2 GB boot partition) |
| `pistorm-29g-sdh1-bootblock.bin` | LBA 6294465, 8 sectors | 4 KB | SDH1 boot block (DOS\7 FFS2, 25.8 GB data; LowCyl=4164, start ≈ 3.0 GiB — below overflow threshold) |

### PiStorm 7g — 3-partition overflow fixture (MBR + FAT32 + RDB slice)
| File | Source offset | Size | Contents |
|------|--------------|------|----------|
| `pistorm-7g-3part-mbr.bin` | LBA 0, 1 sector | 512 B | MBR (0x55AA signature) |
| `pistorm-7g-3part-fat32-boot-sector.bin` | LBA 2048, 1 sector | 512 B | FAT32 VBR |
| `pistorm-7g-3part-rdb-area.bin` | LBA 2097153, 64 sectors | 32 KB | RDB area (RDSK + 3×PART blocks) |
| `pistorm-7g-3part-sdh0-bootblock.bin` | LBA 2099169, 8 sectors | 4 KB | SDH0 (DOS\3, 2 GB boot, LowCyl=2) |
| `pistorm-7g-3part-sdh1-bootblock.bin` | LBA 6294465, 8 sectors | 4 KB | SDH1 (DOS\7, 3 GB data, LowCyl=4164) |
| `pistorm-7g-3part-sdh2-bootblock.bin` | LBA 12552129, 8 sectors | 4 KB | **SDH2 (DOS\3, 512 MB work, LowCyl=10372, start=5,352,947,712 bytes ≈ 5 GiB → UInt32 overflow)** |

### Classic Amiga (pure RDB, no MBR)
| File | Source offset | Size | Contents |
|------|--------------|------|----------|
| `classic-8g-rdb-area.bin` | LBA 0, 64 sectors | 32 KB | Full RDB area (RDSK + 2×PART + FSHD + LSEG blocks); no MBR |
| `classic-8g-dh0-bootblock.bin` | LBA 2016, 8 sectors | 4 KB | DH0 boot block (DOS\3 FFS, 2048-byte FS blocks) |
| `classic-8g-dh1-bootblock.bin` | LBA 4197312, 8 sectors | 4 KB | DH1 boot block (DOS\7 FFS2, auto-upgraded large data partition) |

Note: all three platforms produce boot blocks with zero checksum and zero rootblock pointer. This is normal for RDB-mounted partitions — AmigaOS FFS derives the rootblock position from partition geometry, not from the boot block pointer.

## Source Images

| Image | Platform | Build | Size |
|-------|----------|-------|------|
| `~/Desktop/build/Amiga.hdf` | MiSTer | 2026-06-04 21:08 | 8 GB |
| `~/Desktop/build/Amiga.img` | PiStorm (with Classic content) | 2026-06-04 19:11 | 8 GB |
| `~/Desktop/build/ClassicAmiga.img` | Classic Amiga (pure RDB) | 2026-06-05 01:26 | 8 GB |
| `~/Desktop/build/PiStomrAmiga.img` | PiStorm (29 GB, 2-partition) | 2026-06-05 02:43 | 29 GB (31,000,000,000 bytes) |
| `~/Desktop/build/PiStomrAmiga.img` | PiStorm (7 GB, 3-partition overflow) | 2026-06-05 03:12 | 7 GB (7,000,000,000 bytes) |

## What Is Still Needed

- FFS root block binary fixture for each partition type
