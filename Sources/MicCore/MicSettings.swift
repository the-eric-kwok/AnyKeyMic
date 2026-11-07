import Foundation

public enum MicMode: String, Codable, Sendable {
    case auto
    case alwaysOn = "always-on"
    case pushToTalk = "push-to-talk"

    public var displayName: String {
        switch self {
        case .auto:
            #if os(Windows)
            return "自动（USB、蓝牙均常开麦）"
            #else
            return "自动（USB 常开、蓝牙按键开麦）"
            #endif
        case .alwaysOn: return "常开麦"
        case .pushToTalk: return "按住 AI 键开麦"
        }
    }

    public func usesPushToTalk(isBluetooth: Bool) -> Bool {
        switch self {
        case .auto:
            #if os(Windows)
            return false
            #else
            return isBluetooth
            #endif
        case .alwaysOn: return false
        case .pushToTalk: return true
        }
    }
}

public struct MicSettings: Codable, Equatable, Sendable {
    public let outputID: String
    public let outputName: String
    /// AI 键映射的平台键码，nil 表示不映射。
    public var aiKeyMap: Int32?
    public var mode: MicMode

    public init(outputID: String, outputName: String, aiKeyMap: Int32? = nil, mode: MicMode = .auto) {
        self.outputID = outputID
        self.outputName = outputName
        self.aiKeyMap = aiKeyMap
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputID = try values.decode(String.self, forKey: .outputID)
        outputName = try values.decode(String.self, forKey: .outputName)
        aiKeyMap = try values.decodeIfPresent(Int32.self, forKey: .aiKeyMap)
        mode = try values.decodeIfPresent(MicMode.self, forKey: .mode) ?? .auto
    }
}
