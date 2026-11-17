import CoreGraphics
import Foundation
import Vision

enum OCRMode: String, CaseIterable, Hashable, Identifiable {
    case text
    case table
    case formula

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "文字识别"
        case .table: return "表格识别"
        case .formula: return "公式识别"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .table: return "tablecells"
        case .formula: return "function"
        }
    }
}

struct OCRTextBlock {
    let text: String
    /// Normalized bounding box, origin at the bottom left.
    let box: CGRect
}

struct OCRTable {
    let rows: [[String]]

    var isEmpty: Bool { rows.isEmpty }

    var markdown: String {
        guard let header = rows.first else { return "" }
        let columnCount = rows.map(\.count).max() ?? header.count
        func padded(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "| " + padded(header).map(escaped).joined(separator: " | ") + " |",
            "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        ]
        for row in rows.dropFirst() {
            lines.append("| " + padded(row).map(escaped).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    var tsv: String {
        rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    var csv: String {
        func field(_ value: String) -> String {
            guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n")
    }
}

enum OCRTools {
    static func blocks(in image: CGImage) async throws -> [OCRTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = request.recognitionLanguages.filter { supported.contains($0) }
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return (request.results ?? []).compactMap { observation -> OCRTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return OCRTextBlock(text: text, box: observation.boundingBox)
                }
            }.value
        } onCancel: {
            request.cancel()
        }
    }

    static func table(in image: CGImage) async throws -> OCRTable {
        let blocks = try await blocks(in: image).sorted { $0.box.maxY > $1.box.maxY }
        guard !blocks.isEmpty else { return OCRTable(rows: []) }

        var rows: [[OCRTextBlock]] = []
        for block in blocks {
            if let last = rows.last,
               let reference = last.first,
               abs(block.box.midY - reference.box.midY) < max(0.012, reference.box.height * 0.55) {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block])
            }
        }
        rows = rows.map { $0.sorted { $0.box.minX < $1.box.minX } }

        let starts = rows.flatMap { $0.map { $0.box.minX } }.sorted()
        var centers: [CGFloat] = []
        for start in starts {
            if let last = centers.last, abs(start - last) < 0.02 {
                centers[centers.count - 1] = (last + start) / 2
            } else {
                centers.append(start)
            }
        }
        guard !centers.isEmpty else { return OCRTable(rows: []) }

        var matrix = rows.map { row -> [String] in
            var cells = Array(repeating: "", count: centers.count)
            for block in row {
                var column = 0
                var best = CGFloat.greatestFiniteMagnitude
                for (index, center) in centers.enumerated() where abs(block.box.minX - center) < best {
                    best = abs(block.box.minX - center)
                    column = index
                }
                cells[column] = cells[column].isEmpty ? block.text : cells[column] + " " + block.text
            }
            return cells
        }

        matrix.removeAll { $0.allSatisfy { $0.isEmpty } }
        if let width = matrix.map(\.count).max() {
            let used = (0..<width).filter { column in matrix.contains { !$0[column].isEmpty } }
            matrix = matrix.map { row in used.map { row[$0] } }
        }
        return OCRTable(rows: matrix)
    }

    static func formula(in image: CGImage) async throws -> String {
        let lines = try await blocks(in: image)
            .sorted { lhs, rhs in
                if abs(lhs.box.midY - rhs.box.midY) > 0.01 { return lhs.box.midY > rhs.box.midY }
                return lhs.box.minX < rhs.box.minX
            }
            .map(\.text)
        return FormulaNormalizer.latex(from: lines.joined(separator: "\n"))
    }
}

enum FormulaNormalizer {
    private static let symbols: [(String, String)] = [
        ("≤", "\\leq "), ("≥", "\\geq "), ("≠", "\\neq "), ("≈", "\\approx "),
        ("±", "\\pm "), ("×", "\\times "), ("÷", "\\div "), ("∞", "\\infty "),
        ("∑", "\\sum "), ("∏", "\\prod "), ("∫", "\\int "), ("√", "\\sqrt "),
        ("π", "\\pi "), ("θ", "\\theta "), ("α", "\\alpha "), ("β", "\\beta "),
        ("γ", "\\gamma "), ("δ", "\\delta "), ("λ", "\\lambda "), ("μ", "\\mu "),
        ("σ", "\\sigma "), ("φ", "\\phi "), ("ω", "\\omega "), ("Δ", "\\Delta "),
        ("Ω", "\\Omega "), ("→", "\\rightarrow "), ("←", "\\leftarrow "),
        ("⇒", "\\Rightarrow "), ("∈", "\\in "), ("∉", "\\notin "), ("⊂", "\\subset "),
        ("∪", "\\cup "), ("∩", "\\cap "), ("∂", "\\partial "), ("∇", "\\nabla "),
        ("°", "^{\\circ}"), ("·", "\\cdot "), ("…", "\\ldots ")
    ]

    private static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
        "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "ⁿ": "n"
    ]

    private static let subscripts: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
        "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9"
    ]

    static func latex(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let digit = superscripts[character] {
                var group = String(digit)
                var next = text.index(after: index)
                while next < text.endIndex, let more = superscripts[text[next]] {
                    group.append(more)
                    next = text.index(after: next)
                }
                output += "^{\(group)}"
                index = next
                continue
            }
            if let digit = subscripts[character] {
                var group = String(digit)
                var next = text.index(after: index)
                while next < text.endIndex, let more = subscripts[text[next]] {
                    group.append(more)
                    next = text.index(after: next)
                }
                output += "_{\(group)}"
                index = next
                continue
            }
            if let replacement = symbols.first(where: { $0.0 == String(character) })?.1 {
                output += replacement
            } else {
                output.append(character)
            }
            index = text.index(after: index)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
