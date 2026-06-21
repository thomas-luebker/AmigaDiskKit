import Foundation

// MARK: - Common floppy-device abstraction
//
// Both the Greaseweazle and DrawBridge controllers drive a real 3.5" Amiga
// drive over a serial port. They speak different wire protocols, but expose
// the same whole-disk operations to the app, so the app's FloppyController and
// menu can hold any `FloppyDevice` without caring which hardware is attached.
//
// The reusable codec stack underneath (AmigaMFM, FluxMFM, ADFFloppyImage,
// SCPImage) is shared by both controllers — only the device command layer and
// the on-wire flux/MFM framing differ.

/// Per-track progress for a whole-disk read/write, reported on the calling
/// (background) thread. `track` is `cyl * heads + head`.
public struct DiskProgress: Sendable {
    public let track: Int
    public let totalTracks: Int
    public let sectorsFound: Int
    public let sectorsExpected: Int

    public init(track: Int, totalTracks: Int, sectorsFound: Int, sectorsExpected: Int) {
        self.track = track
        self.totalTracks = totalTracks
        self.sectorsFound = sectorsFound
        self.sectorsExpected = sectorsExpected
    }
}

/// A connected floppy controller (Greaseweazle or DrawBridge). All operations
/// are blocking and meant to run off the main thread; `progress` is invoked
/// per track and `isCancelled` is polled between tracks.
public protocol FloppyDevice: AnyObject {
    /// Human-readable device + firmware string, valid after `connectDevice()`.
    var deviceDescription: String { get }

    /// Whether the attached firmware can stream raw flux. False firmware can
    /// still read/write ADFs but cannot image/restore SCP. The app hides the
    /// SCP actions when this is false.
    var supportsFlux: Bool { get }

    /// Open the session: reset comms and read the device's identity/firmware.
    /// Populates `deviceDescription` and `supportsFlux`.
    func connectDevice() throws

    func readDisk(geometry: AmigaFloppyGeometry,
                  progress: ((DiskProgress) -> Void)?,
                  isCancelled: () -> Bool) throws -> (adf: Data, results: [TrackReadResult])

    func writeDisk(adf: Data, geometry: AmigaFloppyGeometry,
                   progress: ((DiskProgress) -> Void)?,
                   isCancelled: () -> Bool) throws

    func readSCP(cylinders: Int, heads: Int, diskType: UInt8,
                 progress: ((DiskProgress) -> Void)?,
                 isCancelled: () -> Bool) throws -> Data

    func writeSCP(_ data: Data, heads: Int,
                  progress: ((DiskProgress) -> Void)?,
                  isCancelled: () -> Bool) throws
}

public extension FloppyDevice {
    /// SCP imaging with the default Amiga disk type, so callers driving an
    /// `any FloppyDevice` don't need the kit-internal disk-type constant.
    func readSCP(cylinders: Int, heads: Int,
                 progress: ((DiskProgress) -> Void)?,
                 isCancelled: () -> Bool) throws -> Data {
        try readSCP(cylinders: cylinders, heads: heads, diskType: SCPImage.amigaDiskType,
                    progress: progress, isCancelled: isCancelled)
    }
}
