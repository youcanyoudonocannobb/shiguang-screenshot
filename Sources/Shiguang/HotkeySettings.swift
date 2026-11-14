import AppKit
import Carbon

struct HotkeySettings: Codable, Equatable {
    var key: String
    var option = true
    var shift = true
    var control = false
    var command = false

    var keyCode: UInt32 {
        ["A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
         "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
         "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
         "Y": 16, "Z": 6][key.uppercased()] ?? 1
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
        guard key.count == 1, key.range(of: "^[A-Z]$", options: .regularExpression) != nil else {
            return nil
        }
        return HotkeySettings(key: key, option: option, shift: shift, control: control, command: command)
    }
}
