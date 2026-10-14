import Foundation

/// 8 子带、单声道的 SBC 合成滤波器状态。
///
/// 这里使用规范中的 16×8 cosine matrix 和 80 点 prototype window，
/// 不依赖 Node 或平台音频 API。输入仍是 `MiSbcSubbandFrame` 的子带域样本，
/// 因此可以独立于 HID、VB-Cable 和实时线程进行 golden 对比。
public struct MiSbcSynthesisFilter: Sendable {
    private var state = [Double](repeating: 0, count: 160)
    private let matrix: [[Double]]

    public init() {
        matrix = (0..<16).map { k in
            (0..<8).map { i in
                cos((Double(i) + 0.5) * Double(k + 4) * Double.pi / 8)
            }
        }
    }

    public mutating func reset() {
        state = [Double](repeating: 0, count: 160)
    }

    public mutating func synthesize(_ frame: MiSbcSubbandFrame) -> [Int16] {
        var output = [Int16]()
        output.reserveCapacity(MiSbcProfile.samplesPerFrame)
        for block in frame.samples {
            state.replaceSubrange(16..<160, with: state[0..<144])
            for k in 0..<16 {
                state[k] = zip(matrix[k], block).reduce(0) { $0 + $1.0 * Double($1.1) }
            }
            for sample in 0..<8 {
                var value = 0.0
                let index = sample * 5
                for tap in 0..<5 {
                    value += Self.prototypeM0[index + tap] * state[sample + tap * 32]
                    value += Self.prototypeM1[index + tap] * state[sample + 8 + (tap * 2 + 1) * 16]
                }
                output.append(Int16(clamping: Int((value * Self.outputGain).rounded())))
            }
        }
        return output
    }

    // 反量化使用标准 SBC 的 scale + 1 定点幅度，合成结果恢复为 PCM。
    private static let outputGain = 2.0

    private static let prototypeM0: [Double] = [
        0, -0.011318989098, -0.135997891426, 0.135997891426, 0.011318989098,
        -0.000313150696, -0.016058823094, -0.165969520807, 0.10637460649, 0.006994348951,
        -0.000686512794, -0.02091688849, -0.195150777698, 0.07815027982, 0.003299461678,
        -0.001109240111, -0.025494467467, -0.222393378615, 0.052219752222, 0.000357610639,
        -0.001647838857, -0.029305052012, -0.246529102325, 0.029280815274, -0.001804308966,
        -0.002279850189, -0.03180912137, -0.266528844833, 0.009831560776, -0.003233125433,
        -0.002952803392, -0.032441694289, -0.281507015228, -0.005848168861, -0.003989091143,
        -0.003567434382, -0.030636820942, -0.290779680014, -0.01771515049, -0.004207439721
    ]

    private static let prototypeM1: [Double] = [
        -0.004023650661, -0.025874361396, -0.29391014576, -0.025874361396, -0.004023650661,
        -0.004207439721, -0.01771515049, -0.290779680014, -0.030636820942, -0.003567434382,
        -0.003989091143, -0.005848168861, -0.281507015228, -0.032441694289, -0.002952803392,
        -0.003233125433, 0.009831560776, -0.266528844833, -0.03180912137, -0.002279850189,
        -0.001804308966, 0.029280815274, -0.246529102325, -0.029305052012, -0.001647838857,
        0.000357610639, 0.052219752222, -0.222393378615, -0.025494467467, -0.001109240111,
        0.003299461678, 0.07815027982, -0.195150777698, -0.02091688849, -0.000686512794,
        0.006994348951, 0.10637460649, -0.165969520807, -0.016058823094, -0.000313150696
    ]
}

private extension Int16 {
    init(clamping value: Int) {
        self.init(Swift.max(Int(Int16.min), Swift.min(Int(Int16.max), value)))
    }
}














