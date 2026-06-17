import Foundation

// MARK: - Flux <-> MFM bitcell conversion
//
// A floppy read yields flux reversals as time intervals. MFM records one cell
// per nominal bit-time; a flux reversal marks a 1 cell, the gaps between
// reversals are 0 cells. For Amiga DD the cell is ~2µs (500 kbit/s), so flux
// intervals cluster at 2, 3 and 4 cell-times (the classic "2/3/4" pattern);
// HD halves that to ~1µs.
//
// Decode uses a simple tracking PLL: each flux interval is rounded to a whole
// number of cells against an adaptive window, the window nudged toward the
// observed timing so it follows speed variation. Encode is the inverse —
// emit a flux interval for every 1 cell, the gap sized by the run of 0s.

public struct FluxTiming: Sendable {
    /// Nominal cell time in seconds (DD = 2e-6, HD = 1e-6).
    public let cellSeconds: Double
    public static let dd = FluxTiming(cellSeconds: 2e-6)
    public static let hd = FluxTiming(cellSeconds: 1e-6)

    public init(cellSeconds: Double) { self.cellSeconds = cellSeconds }
}

public enum FluxMFM {

    /// Decode flux intervals (in seconds) into an MFM cell byte stream
    /// (MSB-first, one bit per cell). Tolerates ±~15% speed variation via a
    /// tracking PLL.
    public static func decode(fluxSeconds: [Double], timing: FluxTiming) -> [UInt8] {
        var bits = BitWriter()
        var cell = timing.cellSeconds
        let minCell = timing.cellSeconds * 0.7
        let maxCell = timing.cellSeconds * 1.4

        for interval in fluxSeconds where interval > 0 {
            // Number of cells this flux interval spans (>= 1).
            let n = max(1, Int((interval / cell).rounded()))
            // Emit (n-1) zero cells then a 1 cell at the reversal.
            for _ in 0 ..< (n - 1) { bits.append(0) }
            bits.append(1)
            // Nudge the PLL toward the residual error (adaptive cell time).
            let predicted = Double(n) * cell
            let error = interval - predicted
            cell += error / Double(n) * 0.10
            cell = Swift.min(Swift.max(cell, minCell), maxCell)
        }
        return bits.bytes()
    }

    /// Encode an MFM cell byte stream (MSB-first) into flux intervals
    /// (seconds), one interval per 1 cell. Leading zero cells before the first
    /// reversal are folded into the first interval.
    public static func encode(cells: [UInt8], timing: FluxTiming) -> [Double] {
        var flux: [Double] = []
        var run = 0
        let totalBits = cells.count * 8
        for i in 0 ..< totalBits {
            let bit = (cells[i >> 3] >> UInt8(7 - (i & 7))) & 1
            run += 1
            if bit == 1 {
                flux.append(Double(run) * timing.cellSeconds)
                run = 0
            }
        }
        return flux
    }
}

// MARK: - Bit writer (MSB-first)

struct BitWriter {
    private var buffer: [UInt8] = []
    private var current: UInt8 = 0
    private var fill = 0

    mutating func append(_ bit: Int) {
        current = (current << 1) | UInt8(bit & 1)
        fill += 1
        if fill == 8 {
            buffer.append(current)
            current = 0
            fill = 0
        }
    }

    mutating func bytes() -> [UInt8] {
        if fill > 0 {
            // Left-justify the final partial byte so bit order is preserved.
            buffer.append(current << UInt8(8 - fill))
            current = 0
            fill = 0
        }
        return buffer
    }
}
