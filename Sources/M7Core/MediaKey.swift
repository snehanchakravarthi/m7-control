import Foundation

public enum MediaKey: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown

    public var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
}

public struct MediaKeyEvent: Equatable, Sendable {
    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool

    public init(key: MediaKey, isDown: Bool, isRepeat: Bool) {
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
    }
}

public enum MediaKeyDecoder {
    /// Decodes the `data1` field of a system-defined event with subtype 8 (special keys).
    /// Layout: bits 16-31 key code, bits 8-15 state (0x0A down, 0x0B up), bit 0 repeat.
    public static func decode(data1: Int) -> MediaKeyEvent? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8

        let key: MediaKey
        switch keyCode {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        case 7: key = .mute
        default: return nil
        }
        return MediaKeyEvent(key: key, isDown: state == 0x0A, isRepeat: flags & 0x1 == 1)
    }

    /// Some keyboards send brightness as ordinary key presses instead of special-key events.
    /// Logitech keyboards send F14/F15 (the classic external-keyboard brightness keys);
    /// 144/145 are the dedicated brightness key codes other keyboards use.
    public static func brightnessKey(forKeyCode keyCode: Int) -> MediaKey? {
        switch keyCode {
        case 107, 145: return .brightnessDown // F14, brightness down
        case 113, 144: return .brightnessUp // F15, brightness up
        default: return nil
        }
    }
}

public enum Level {
    public static let volumeRange = 0...100
    public static let backlightRange = 0...50

    public static func stepped(_ value: Int, by delta: Int, in range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value + delta))
    }
}
