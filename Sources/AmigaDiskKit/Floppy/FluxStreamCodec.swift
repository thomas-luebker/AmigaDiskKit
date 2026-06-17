import Foundation

// MARK: - Greaseweazle flux byte-stream codec
//
// The Greaseweazle device streams flux as a byte sequence; the host decodes it
// into a list of inter-flux intervals (in sample-frequency ticks) plus the
// tick positions of index pulses. Ported verbatim from the reference
// implementation (`greaseweazle/usb.py` `_decode_flux`/`_encode_flux`):
//
//   1–249   : interval += byte; flush a sample
//   250–254 : two-byte form, value 250 + (b-250)*255 + (next-1)
//   255     : opcode escape — Index (1) records an index position,
//             Space (2) adds a 28-bit value to the running interval,
//             Astable (3) carries a 28-bit period (encode side only)
//   0       : end of stream
//
// 28-bit values pack 7 data bits per byte (bit0 = 1 marker so a payload byte
// is never a 0 terminator).

enum FluxOp {
    static let index: UInt8 = 1
    static let space: UInt8 = 2
    static let astable: UInt8 = 3
}

public struct DecodedFlux: Sendable {
    /// Inter-flux intervals in device ticks.
    public let flux: [Int]
    /// Cumulative tick position of each index pulse (revolution boundaries).
    public let indexTicks: [Int]
}

public enum FluxStreamCodec {

    /// Decode a Greaseweazle ReadFlux byte stream (terminated by a 0 byte).
    public static func decode(_ data: [UInt8]) -> DecodedFlux {
        var flux: [Int] = []
        var index: [Int] = []
        var ticks = 0          // running interval accumulator
        var total = 0          // total ticks emitted (for index positions)
        var i = 0
        let n = data.count

        func read28() -> Int {
            guard i + 4 <= n else { i = n; return 0 }
            var val = (Int(data[i]) & 254) >> 1
            val += (Int(data[i + 1]) & 254) << 6
            val += (Int(data[i + 2]) & 254) << 13
            val += (Int(data[i + 3]) & 254) << 20
            i += 4
            return val
        }

        while i < n {
            let b = Int(data[i]); i += 1
            if b == 0 { break }                       // end of stream
            if b < 250 {
                ticks += b
                total += ticks
                flux.append(ticks)
                ticks = 0
            } else if b < 255 {
                guard i < n else { break }
                let nextB = Int(data[i]); i += 1
                ticks += 250 + (b - 250) * 255 + (nextB - 1)
                total += ticks
                flux.append(ticks)
                ticks = 0
            } else {
                guard i < n else { break }
                let op = data[i]; i += 1
                switch op {
                case FluxOp.index:
                    let val = read28()
                    index.append(total + ticks + val)
                case FluxOp.space:
                    ticks += read28()
                default:
                    _ = read28()                       // Astable etc. — skip
                }
            }
        }
        return DecodedFlux(flux: flux, indexTicks: index)
    }

    /// Encode flux intervals (in device ticks) into a Greaseweazle WriteFlux
    /// byte stream, terminated by a 0 byte.
    public static func encode(_ flux: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(flux.count + flux.count / 4 + 1)

        func write28(_ x: Int) {
            out.append(UInt8(1 | (x << 1) & 255))
            out.append(UInt8(1 | (x >> 6) & 255))
            out.append(UInt8(1 | (x >> 13) & 255))
            out.append(UInt8(1 | (x >> 20) & 255))
        }

        for sample in flux {
            var val = sample
            if val < 250 {
                out.append(UInt8(max(1, val)))
            } else if val <= 250 + 4 * 255 + 254 {
                // two-byte extension range
                let high = (val - 250) / 255
                if high < 5 {
                    out.append(UInt8(250 + high))
                    out.append(UInt8(1 + (val - 250) % 255))
                } else {
                    out.append(255); out.append(FluxOp.space); write28(val)
                    out.append(1)   // a 1-tick flush after the space
                }
            } else {
                // long gap: Space opcode carries the bulk, then flush.
                val -= 249
                out.append(255); out.append(FluxOp.space); write28(val)
                out.append(249)
            }
        }
        out.append(0)
        return out
    }
}
