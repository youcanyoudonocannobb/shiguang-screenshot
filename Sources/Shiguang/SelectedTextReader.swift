import AppKit
import ApplicationServices

struct SelectedTextSelection {
    let text: String
    let bounds: CGRect?
}

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
        selection(applicationPID: applicationPID)?.text
    }

    static func selection(applicationPID: pid_t? = nil) -> SelectedTextSelection? {
        guard isTrusted else { return nil }
        if let selection = focusedSelection(AXUIElementCreateSystemWide()) {
            return selection
        }
        guard let applicationPID else { return nil }
        return focusedSelection(AXUIElementCreateApplication(applicationPID))
    }

    private static func focusedSelection(_ root: AXUIElement) -> SelectedTextSelection? {
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

        let resolvedText: String?
        if let value = selectedValue as? String {
            resolvedText = normalized(value)
        } else if let value = selectedValue as? NSAttributedString {
            resolvedText = normalized(value.string)
        } else {
            resolvedText = nil
        }
        guard let resolvedText else { return nil }
        return SelectedTextSelection(text: resolvedText, bounds: selectedBounds(of: focused))
    }

    private static func selectedBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let range = rangeValue as! AXValue
        guard AXValueGetType(range) == .cfRange else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = boundsValue as! AXValue
        guard AXValueGetType(value) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &bounds),
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    static func normalized(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
