import AppKit
import ApplicationServices

enum SelectedTextReader {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func selectedText(applicationPID: pid_t? = nil) -> String? {
        guard isTrusted else { return nil }
        if let text = focusedElementText(AXUIElementCreateSystemWide()) {
            return text
        }
        guard let applicationPID else { return nil }
        return focusedElementText(AXUIElementCreateApplication(applicationPID))
    }

    private static func focusedElementText(_ root: AXUIElement) -> String? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return nil }

        let focused = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success, let selectedValue else { return nil }

        if let text = selectedValue as? String {
            return normalized(text)
        }
        if let text = selectedValue as? NSAttributedString {
            return normalized(text.string)
        }
        return nil
    }

    static func normalized(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
