import Foundation

/// 平台键码到中文名的映射，仅用于展示；未知键码显示数值。
public enum KeyNames {
    #if os(Windows)
    public static let escapeCode: Int32 = 0x1b
    private static let known: [Int32: String] = [
        0x1b: "Esc",
        0x5b: "左 Win", 0xa7: "右 Win",
        0xa0: "左 Shift", 0xa1: "右 Shift",
        0xa2: "左 Ctrl", 0xa3: "右 Ctrl",
        0xa4: "左 Alt", 0xa5: "右 Alt",
    ]
    #else
    public static let escapeCode: Int32 = 0x35
    private static let known: [Int32: String] = [
        0x35: "Esc",
        0x3f: "fn 键",
        0x37: "左 Command", 0x36: "右 Command",
        0x38: "左 Shift", 0x3c: "右 Shift",
        0x3a: "左 Option", 0x3d: "右 Option",
        0x3b: "左 Ctrl", 0x3e: "右 Ctrl",
        0x7a: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6d: "F10", 0x67: "F11", 0x6f: "F12",
    ]
    #endif

    public static func name(_ code: Int32) -> String {
        if let name = known[code] { return name }
        #if os(Windows)
        if (0x70...0x7b).contains(code) { return "F\(code - 0x70 + 1)" }
        #endif
        return "键码 \(code)"
    }
}
