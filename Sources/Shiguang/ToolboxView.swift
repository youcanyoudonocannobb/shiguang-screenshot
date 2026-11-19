import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolboxView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case json
        case encoding

        var id: String { rawValue }
        var title: String { self == .json ? "JSON 转换" : "编码转换" }
        var symbol: String { self == .json ? "curlybraces" : "arrow.left.arrow.right" }
    }

    @StoredState private var tab: Tab = .json
    @StoredState private var jsonText = ""
    @StoredState private var jsonStatus: String?
    @StoredState private var jsonStatusIsError = false
    @StoredState private var encodingMode: EncodingMode = .base64
    @StoredState private var encodingDecoding = false
    @StoredState private var encodingInput = ""
    @StoredState private var encodingOutput = ""
    @StoredState private var encodingError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            if tab == .json { jsonPane } else { encodingPane }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .animation(nil, value: tab)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("工具箱").font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                            Text(item.title).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(tab == item ? Color.white : Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(tab == item ? Palette.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(Palette.panel)
    }

    // MARK: - JSON

    private var jsonPane: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Palette.line).frame(height: 1)
            TextEditor(text: $jsonText)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Palette.panel)
                .accessibilityLabel("JSON 输入")
                .overlay(alignment: .topLeading) {
                    if jsonText.isEmpty {
                        Text("粘贴 JSON 后点击格式化")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 18).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
            Rectangle().fill(Palette.line).frame(height: 1)
            statusBar
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton("格式化", symbol: "wand.and.stars") { transform { try JSONTool.format($0) } }
            toolButton("压缩", symbol: "arrow.down.right.and.arrow.up.left") { transform { try JSONTool.minify($0) } }
            toolButton("字段升序", symbol: "arrow.up.arrow.down") {
                transform { try JSONTool.reorder($0, ascending: true) }
            }
            toolButton("字段降序", symbol: "arrow.down.arrow.up") {
                transform { try JSONTool.reorder($0, ascending: false) }
            }
            toolButton("转义", symbol: "text.quote") {
                let escaped = JSONTool.escape(jsonText)
                setJSON(escaped, status: "已转义")
            }
            toolButton("去转义", symbol: "text.quote") {
                do {
                    setJSON(try JSONTool.unescape(jsonText), status: "已去转义")
                } catch {
                    fail(error)
                }
            }
            toolButton("删除注释", symbol: "trash") {
                setJSON(JSONTool.stripComments(jsonText), status: "已删除注释")
            }
            Spacer(minLength: 8)
            toolButton("复制", symbol: "doc.on.doc") {
                copy(jsonText)
                jsonStatus = "已复制"
                jsonStatusIsError = false
            }
            toolButton("清空", symbol: "xmark") {
                jsonText = ""
                jsonStatus = nil
            }
            toolButton("下载", symbol: "square.and.arrow.down") { saveJSON() }
        }
        .buttonStyle(ToolboxChipStyle())
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Palette.background)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: jsonStatusIsError ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(jsonStatusIsError ? Palette.danger : Palette.success)
            Text(jsonStatus ?? (jsonText.isEmpty ? "等待输入" : "JSON 有效"))
                .font(.system(size: 11))
                .foregroundStyle(jsonStatusIsError ? Palette.danger : Palette.muted)
            Spacer()
            Text("\(jsonText.count) 字符")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Palette.panel)
    }

    // MARK: - Encoding

    private var encodingPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("格式", selection: $encodingMode) {
                    ForEach(EncodingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 330)
                .animation(nil, value: encodingMode)
                .onChange(of: encodingMode) { _, _ in encodingOutput = ""; encodingError = nil }

                Spacer(minLength: 12)
                Button(encodingDecoding ? "解码 ↓" : "编码 ↓") {
                    runEncoding()
                }
                .buttonStyle(ToolboxAccentStyle())
                Button("交换") { swapEncoding() }
                    .buttonStyle(ToolboxChipStyle())
                    .disabled(encodingOutput.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Rectangle().fill(Palette.line).frame(height: 1)

            HStack(spacing: 0) {
                encodingPaneColumn(title: "原文", text: $encodingInput, editable: true)
                Rectangle().fill(Palette.line).frame(width: 1)
                encodingPaneColumn(title: "结果", text: $encodingOutput, editable: false)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 8) {
                if let encodingError {
                    Text(encodingError).font(.system(size: 11)).foregroundStyle(Palette.danger)
                } else {
                    Text("所有转换都在本机完成").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("复制结果") {
                    copy(encodingOutput)
                }
                .buttonStyle(ToolboxChipStyle())
                .disabled(encodingOutput.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Palette.panel)
        }
    }

    private func encodingPaneColumn(title: String, text: Binding<String>, editable: Bool) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 34)
            TextEditor(text: text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .disabled(!editable)
                .background(editable ? Palette.panel : Palette.sage.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runEncoding() {
        encodingError = nil
        do {
            encodingOutput = try EncodingTool.convert(encodingInput,
                                                      mode: encodingMode,
                                                      decoding: encodingDecoding)
        } catch {
            encodingOutput = ""
            encodingError = error.localizedDescription
        }
    }

    private func swapEncoding() {
        guard !encodingOutput.isEmpty else { return }
        encodingInput = encodingOutput
        encodingDecoding.toggle()
        encodingOutput = ""
        encodingError = nil
    }

    // MARK: - Helpers

    private func toolButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .disabled(jsonText.isEmpty && title != "清空")
    }

    private func transform(_ operation: (String) throws -> String) {
        do {
            let result = try operation(jsonText)
            setJSON(result, status: "转换完成")
        } catch {
            fail(error)
        }
    }

    private func setJSON(_ value: String, status: String) {
        jsonText = value
        jsonStatus = status
        jsonStatusIsError = false
    }

    private func fail(_ error: Error) {
        jsonStatus = error.localizedDescription
        jsonStatusIsError = true
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func saveJSON() {
        guard !jsonText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "PawShot.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try jsonText.write(to: url, atomically: true, encoding: .utf8)
            jsonStatus = "已保存"
            jsonStatusIsError = false
        } catch {
            fail(error)
        }
    }
}

private struct ToolboxChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @StoredState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(configuration.isPressed ? Palette.line : hovered ? Palette.accentSoft : Palette.panel,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

private struct ToolboxAccentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.accentDeep : Palette.accent,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - JSON

enum JSONToolError: LocalizedError {
    case invalid

    var errorDescription: String? {
        switch self {
        case .invalid: return "不是有效的 JSON"
        }
    }
}

enum JSONTool {
    static func format(_ text: String) throws -> String {
        try render(parse(text), pretty: true, ascending: nil)
    }

    static func minify(_ text: String) throws -> String {
        try render(parse(text), pretty: false, ascending: nil)
    }

    static func reorder(_ text: String, ascending: Bool) throws -> String {
        try render(parse(text), pretty: true, ascending: ascending)
    }

    static func parse(_ text: String) throws -> Any {
        let data = Data(text.utf8)
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONToolError.invalid
        }
    }

    static func render(_ value: Any, pretty: Bool, ascending: Bool?) -> String {
        var output = ""
        write(value, into: &output, level: 0, pretty: pretty, ascending: ascending)
        return output
    }

    private static func write(_ value: Any, into output: inout String,
                              level: Int, pretty: Bool, ascending: Bool?) {
        let indent = pretty ? String(repeating: "  ", count: level) : ""
        let newline = pretty ? "\n" : ""
        let nextIndent = pretty ? String(repeating: "  ", count: level + 1) : ""

        if let dictionary = value as? [String: Any] {
            if dictionary.isEmpty {
                output += "{}"
                return
            }
            var keys = Array(dictionary.keys)
            if let ascending {
                keys.sort { ascending ? $0 < $1 : $0 > $1 }
            } else {
                keys.sort()
            }
            output += "{" + newline
            for (index, key) in keys.enumerated() {
                output += nextIndent + quote(key) + (pretty ? ": " : ":")
                write(dictionary[key] as Any, into: &output, level: level + 1, pretty: pretty, ascending: ascending)
                if index < keys.count - 1 { output += "," }
                output += newline
            }
            output += indent + "}"
        } else if let array = value as? [Any] {
            if array.isEmpty {
                output += "[]"
                return
            }
            output += "[" + newline
            for (index, item) in array.enumerated() {
                output += nextIndent
                write(item, into: &output, level: level + 1, pretty: pretty, ascending: ascending)
                if index < array.count - 1 { output += "," }
                output += newline
            }
            output += indent + "]"
        } else if let string = value as? String {
            output += quote(string)
        } else if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output += number.boolValue ? "true" : "false"
            } else {
                output += number.stringValue
            }
        } else if value is NSNull {
            output += "null"
        } else {
            output += quote(String(describing: value))
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result + "\""
    }

    static func escape(_ text: String) -> String {
        quote(text)
    }

    static func unescape(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""),
           let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return value
        }
        return trimmed
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Removes // and /* */ comments while leaving string literals untouched.
    static func stripComments(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                result.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                index = next
                continue
            }
            if character == "/", next < text.endIndex, text[next] == "/" {
                var cursor = next
                while cursor < text.endIndex, text[cursor] != "\n" {
                    cursor = text.index(after: cursor)
                }
                index = cursor
                continue
            }
            if character == "/", next < text.endIndex, text[next] == "*" {
                var cursor = text.index(after: next)
                while cursor < text.endIndex {
                    let after = text.index(after: cursor)
                    if text[cursor] == "*", after < text.endIndex, text[after] == "/" {
                        cursor = text.index(after: after)
                        break
                    }
                    cursor = after
                }
                index = cursor
                continue
            }
            result.append(character)
            index = next
        }
        return result
    }
}

// MARK: - Encoding

enum EncodingMode: String, CaseIterable, Identifiable {
    case base64
    case url
    case unicode
    case hex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .base64: return "Base64"
        case .url: return "URL"
        case .unicode: return "Unicode"
        case .hex: return "Hex"
        }
    }
}

enum EncodingToolError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum EncodingTool {
    static func convert(_ input: String, mode: EncodingMode, decoding: Bool) throws -> String {
        switch (mode, decoding) {
        case (.base64, false):
            return Data(input.utf8).base64EncodedString()
        case (.base64, true):
            guard let data = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines),
                                  options: [.ignoreUnknownCharacters]),
                  let text = String(data: data, encoding: .utf8) else {
                throw EncodingToolError.invalid("不是有效的 Base64")
            }
            return text
        case (.url, false):
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
        case (.url, true):
            guard let text = input.removingPercentEncoding else {
                throw EncodingToolError.invalid("不是有效的 URL 编码")
            }
            return text
        case (.unicode, false):
            return input.unicodeScalars.map { scalar in
                scalar.value > 0xFFFF
                    ? String(format: "\\u%04x\\u%04x",
                             (scalar.value - 0x10000) / 0x400 + 0xD800,
                             (scalar.value - 0x10000) % 0x400 + 0xDC00)
                    : String(format: "\\u%04x", scalar.value)
            }.joined()
        case (.unicode, true):
            return try decodeUnicode(input)
        case (.hex, false):
            return Data(input.utf8).map { String(format: "%02x", $0) }.joined()
        case (.hex, true):
            let digits = input.filter { !$0.isWhitespace }
            guard digits.count % 2 == 0 else {
                throw EncodingToolError.invalid("十六进制长度必须是偶数")
            }
            var bytes: [UInt8] = []
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let byte = UInt8(digits[index..<next], radix: 16) else {
                    throw EncodingToolError.invalid("包含非十六进制字符")
                }
                bytes.append(byte)
                index = next
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw EncodingToolError.invalid("解码结果不是有效的 UTF-8")
            }
            return text
        }
    }

    private static func decodeUnicode(_ input: String) throws -> String {
        var result = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)
            guard character == "\\", next < input.endIndex, input[next] == "u" else {
                result.append(character)
                index = next
                continue
            }
            let start = input.index(next, offsetBy: 1)
            guard let end = input.index(start, offsetBy: 4, limitedBy: input.endIndex),
                  let value = UInt32(input[start..<end], radix: 16) else {
                throw EncodingToolError.invalid("Unicode 转义格式不正确")
            }
            if value >= 0xD800 && value <= 0xDBFF,
               end < input.endIndex,
               input[end] == "\\" {
                let lowStart = input.index(end, offsetBy: 2)
                if lowStart < input.endIndex,
                   let lowEnd = input.index(lowStart, offsetBy: 4, limitedBy: input.endIndex),
                   let low = UInt32(input[lowStart..<lowEnd], radix: 16),
                   low >= 0xDC00 && low <= 0xDFFF {
                    let scalarValue = 0x10000 + (value - 0xD800) * 0x400 + (low - 0xDC00)
                    if let scalar = Unicode.Scalar(scalarValue) { result.unicodeScalars.append(scalar) }
                    index = lowEnd
                    continue
                }
            }
            if let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) }
            index = end
        }
        return result
    }
}
