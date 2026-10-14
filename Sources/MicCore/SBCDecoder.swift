import Foundation

public enum MiSbcProfile {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let blocks = 10
    public static let subbands = 8
    public static let bitpool = 12
    public static let samplesPerFrame = blocks * subbands
}

public protocol SBCDecoder: Sendable {
    func decode(_ frame: MiSbcFrame) throws -> [Int16]
}

public struct UnsupportedSBCDecoder: SBCDecoder {
    public init() {}

    public func decode(_ frame: MiSbcFrame) throws -> [Int16] {
        _ = frame
        throw SBCDecoderError.notImplemented
    }
}

public enum SBCDecoderError: Error, Equatable {
    case notImplemented
    case invalidCRC
    case invalidBitstream
}

struct MiSbcBitReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    var remaining: Int { bytes.count * 8 - offset }

    mutating func read(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32, remaining >= count else {
            throw SBCDecoderError.invalidBitstream
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            value = (value << 1) | UInt32((bytes[offset >> 3] >> (7 - (offset & 7))) & 1)
            offset += 1
        }
        return value
    }
}

public struct MiSbcSubbandFrame: Sendable, Equatable {
    public let scaleFactors: [UInt8]
    public let samples: [[Int32]]
}

public struct MiSbcLiveDecoder {
    private var parser = MiSbcReferenceDecoder()
    private var synthesis = MiSbcSynthesisFilter()

    public init() {}

    public mutating func decode(_ frames: [[UInt8]]) throws -> [Int16] {
        guard frames.count == 3, frames.allSatisfy({ $0.count == MiSbcFrame.length }) else {
            throw SBCDecoderError.invalidBitstream
        }
        var output: [Int16] = []
        output.reserveCapacity(3 * MiSbcProfile.samplesPerFrame)
        for bytes in frames {
            let frame = try MiSbcFrame(bytes)
            let subbands = try parser.decodeSubbands(frame, validateCRC: false)
            output.append(contentsOf: synthesis.synthesize(subbands))
        }
        return output
    }

    public mutating func reset() {
        synthesis.reset()
    }
}
public struct MiSbcReferenceDecoder {
    public init() {}

    /// Parses the vendor bitstream.  CRC validation remains opt-in until the
    /// vendor's frame CRC convention is fully matched against captured packets.
    public func decodeSubbands(_ frame: MiSbcFrame, validateCRC: Bool = false) throws -> MiSbcSubbandFrame {
        let bytes = frame.bytes
        if validateCRC && crc(bytes) != bytes[3] { throw SBCDecoderError.invalidCRC }
        var reader = MiSbcBitReader(bytes: Array(bytes[4...]))
        var scale = [UInt8](repeating: 0, count: MiSbcProfile.subbands)
        for index in scale.indices { scale[index] = UInt8(try reader.read(4)) }
        let bits = allocateBits(scale)
        var samples = Array(repeating: Array(repeating: Int32(0), count: MiSbcProfile.subbands), count: MiSbcProfile.blocks)
        for block in 0..<MiSbcProfile.blocks {
            for band in 0..<MiSbcProfile.subbands {
                let width = bits[band]
                guard width > 0 else { continue }
                let raw = Int32(try reader.read(width))
                let scaleValue = Int32(1) << Int32(scale[band] + 1)
                let denominator = (Int32(1) << Int32(width)) - 1
                samples[block][band] = ((raw * 2 + 1) * scaleValue / denominator) - scaleValue
            }
        }
        guard reader.remaining == 0 else { throw SBCDecoderError.invalidBitstream }
        return MiSbcSubbandFrame(scaleFactors: scale, samples: samples)
    }

    private func crc(_ bytes: [UInt8]) -> UInt8 {
        var value: UInt8 = 0x0f
        func push(_ bit: UInt8, into crc: inout UInt8) {
            let feedback = ((crc >> 7) & 1) ^ bit
            crc <<= 1
            if feedback != 0 { crc ^= 0x1d }
        }
        for byte in bytes[1...2] {
            for shift in stride(from: 7, through: 0, by: -1) { push((byte >> shift) & 1, into: &value) }
        }
        for byte in bytes[4..<8] {
            for shift in stride(from: 7, through: 0, by: -1) { push((byte >> shift) & 1, into: &value) }
        }
        return value
    }

    /// Allocates the fixed 12 bitpool using the SBC Loudness rule for 16 kHz／8 bands.
    /// The vendor profile keeps the normal SBC bit allocation, but fixes the number of
    /// blocks to ten.  Keeping this separate makes the unusual block count explicit.
    private func allocateBits(_ scale: [UInt8]) -> [Int] {
        let loudnessOffset = [-2, 0, 0, 0, 0, 0, 0, 1]
        let need = zip(scale, loudnessOffset).map { scaleFactor, offset in
            guard scaleFactor != 0 else { return -5 }
            let loudness = Int(scaleFactor) - offset
            return loudness > 0 ? loudness / 2 : loudness
        }
        let maxNeed = need.max() ?? 0
        var bits = Array(repeating: 0, count: MiSbcProfile.subbands)
        var bitSlice = maxNeed + 1
        var bitCount = 0
        var sliceCount = 0

        repeat {
            bitSlice -= 1
            bitCount += sliceCount
            sliceCount = 0
            for band in need.indices {
                if need[band] > bitSlice + 1 && need[band] < bitSlice + 16 {
                    sliceCount += 1
                } else if need[band] == bitSlice + 1 {
                    sliceCount += 2
                }
            }
        } while bitCount + sliceCount < MiSbcProfile.bitpool

        if bitCount + sliceCount == MiSbcProfile.bitpool {
            bitCount += sliceCount
            bitSlice -= 1
        }

        for band in need.indices {
            guard need[band] >= bitSlice + 2 else { continue }
            bits[band] = min(16, need[band] - bitSlice)
        }

        var band = 0
        while bitCount < MiSbcProfile.bitpool && band < bits.count {
            if bits[band] >= 2 && bits[band] < 16 {
                bits[band] += 1
                bitCount += 1
            } else if need[band] == bitSlice + 1 && MiSbcProfile.bitpool > bitCount + 1 {
                bits[band] = 2
                bitCount += 2
            }
            band += 1
        }
        band = 0
        while bitCount < MiSbcProfile.bitpool && band < bits.count {
            if bits[band] < 16 {
                bits[band] += 1
                bitCount += 1
            }
            band += 1
        }
        return bits
    }
}





