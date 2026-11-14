import AppKit
import Carbon

struct HotkeySettings: Codable, Equatable {
    var key: String
    var option = true
    var shift = true
    var control = false
    var command = false

    var keyCode: UInt32 {
        Self.keyCodes[key.uppercased()] ?? Self.keyCodes["S"]!
    }

    var carbonModifiers: UInt32 {
        var value = 0
        if option { value |= optionKey }
        if shift { value |= shiftKey }
        if control { value |= controlKey }
        if command { value |= cmdKey }
        return UInt32(value)
    }

    var symbol: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined() + key.uppercased()
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        if control { flags.insert(.control) }
        if command { flags.insert(.command) }
        return flags
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "Esc", 79: "F18", 80: "F19",
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "↖",
        116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    private static let keyCodes: [String: UInt32] = Dictionary(
        uniqueKeysWithValues: keyNames.map { (String($0.value).uppercased(), UInt32($0.key)) }
    )

    static func fromKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeySettings? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty, let key = keyNames[keyCode] else { return nil }
        return HotkeySettings(
            key: key,
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            control: flags.contains(.control),
            command: flags.contains(.command)
        )
    }

    static func parseInput(_ input: String) -> HotkeySettings? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let tokens = Set(normalized
            .split(whereSeparator: { "+-—– ".contains($0) })
            .map(String.init))
        let control = normalized.contains("⌃") || normalized.contains("control") ||
            tokens.contains("ctrl")
        let option = normalized.contains("⌥") || normalized.contains("option") ||
            normalized.contains("alt") || tokens.contains("opt")
        let shift = normalized.contains("⇧") || normalized.contains("shift")
        let command = normalized.contains("⌘") || normalized.contains("command") ||
            tokens.contains("cmd")
        guard control || option || shift || command else { return nil }

        var remaining = normalized
        for removable in ["control", "ctrl", "option", "opt", "alt", "shift",
                          "command", "cmd", "⌃", "⌥", "⇧", "⌘", "+", "-", "—", "–", " "] {
            remaining = remaining.replacingOccurrences(of: removable, with: "")
        }
        let key = remaining.uppercased()
        guard keyCodes[key] != nil else { return nil }
        return HotkeySettings(key: key, option: option, shift: shift, control: control, command: command)
    }
}
