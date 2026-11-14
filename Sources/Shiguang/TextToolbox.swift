import Foundation

enum VariableNamingStyle: String, Codable, CaseIterable, Identifiable {
    case lowerCamel
    case upperCamel
    case snakeCase
    case kebabCase
    case constantCase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowerCamel: return "小驼峰"
        case .upperCamel: return "大驼峰"
        case .snakeCase: return "下划线"
        case .kebabCase: return "短横线"
        case .constantCase: return "常量"
        }
    }

    var shortcut: String {
        switch self {
        case .lowerCamel: return "xt"
        case .upperCamel: return "dt"
        case .snakeCase: return "snake"
        case .kebabCase: return "kebab"
        case .constantCase: return "const"
        }
    }

    static func fromCommand(_ value: String) -> Self? {
        let command = value.lowercased()
        switch command {
        case "xt", "lc", "lowercamel", "camel":
            return .lowerCamel
        case "dt", "uc", "uppercamel", "pascal":
            return .upperCamel
        case "snake", "snakecase", "_":
            return .snakeCase
        case "kebab", "kebabcase", "-":
            return .kebabCase
        case "const", "constant", "upper", "uppercase":
            return .constantCase
        default:
            return nil
        }
    }

    fileprivate func apply(to words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        let lower = words.map { $0.lowercased() }
        switch self {
        case .lowerCamel:
            return lower.enumerated().map { index, word in
                index == 0 ? word : word.capitalizingFirstLetter
            }.joined()
        case .upperCamel:
            return lower.map(\.capitalizingFirstLetter).joined()
        case .snakeCase:
            return lower.joined(separator: "_")
        case .kebabCase:
            return lower.joined(separator: "-")
        case .constantCase:
            return lower.map { $0.uppercased() }.joined(separator: "_")
        }
    }
}

struct VariableNameConversion: Equatable {
    let value: String
    let style: VariableNamingStyle
    let usedCommand: Bool
}

enum VariableNameTransformer {
    static func convert(_ input: String,
                        defaultStyle: VariableNamingStyle) -> VariableNameConversion {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VariableNameConversion(value: "", style: defaultStyle, usedCommand: false)
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if let command = parts.first.map(String.init),
           let style = VariableNamingStyle.fromCommand(command),
           parts.count == 2 {
            let value = style.apply(to: words(from: String(parts[1])))
            return VariableNameConversion(value: value, style: style, usedCommand: true)
        }
        return VariableNameConversion(
            value: defaultStyle.apply(to: words(from: trimmed)),
            style: defaultStyle,
            usedCommand: false
        )
    }

    static func words(from input: String) -> [String] {
        let latin = input.applyingTransform(.toLatin, reverse: false) ?? input
        let folded = latin.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let pattern = #"[A-Z]+(?=[A-Z][a-z]|[0-9]|$)|[A-Z]?[a-z]+|[A-Z]+|[0-9]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
        return expression.matches(in: folded, range: range).compactMap { match in
            Range(match.range, in: folded).map { String(folded[$0]).lowercased() }
        }
    }
}

enum RandomDataType: String, CaseIterable, Hashable, Identifiable {
    case name
    case email
    case address
    case phone
    case ipv4
    case identityCard
    case uuid
    case password

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "姓名"
        case .email: return "邮箱"
        case .address: return "地址"
        case .phone: return "手机号"
        case .ipv4: return "IPv4"
        case .identityCard: return "身份证"
        case .uuid: return "UUID"
        case .password: return "强密码"
        }
    }

    var symbol: String {
        switch self {
        case .name: return "person.text.rectangle"
        case .email: return "at"
        case .address: return "mappin.and.ellipse"
        case .phone: return "iphone"
        case .ipv4: return "network"
        case .identityCard: return "person.badge.key"
        case .uuid: return "number"
        case .password: return "key.horizontal"
        }
    }
}

enum RandomDataGenerator {
    private static let surnames = [
        "赵", "钱", "孙", "李", "周", "吴", "郑", "王", "冯", "陈",
        "褚", "卫", "蒋", "沈", "韩", "杨", "朱", "秦", "许", "何"
    ]
    private static let givenNames = [
        "子涵", "雨桐", "浩然", "思远", "若溪", "嘉宁", "晨曦", "宇航",
        "诗语", "景行", "安然", "知夏", "明轩", "清越", "星野", "书言"
    ]
    private static let emailPrefixes = [
        "alex", "sam", "river", "north", "lumi", "mika", "cloud", "stone",
        "echo", "juniper", "maple", "moon", "pixel", "sunny"
    ]
    private static let emailDomains = ["example.com", "example.org", "example.net"]
    private static let locations = [
        ("北京市", "朝阳区"), ("北京市", "海淀区"), ("上海市", "浦东新区"),
        ("广东省", "广州市天河区"), ("广东省", "深圳市南山区"),
        ("浙江省", "杭州市西湖区"), ("四川省", "成都市武侯区"),
        ("湖北省", "武汉市洪山区"), ("江苏省", "南京市鼓楼区")
    ]
    private static let streets = [
        "云杉路", "星河街", "青禾路", "望江路", "知春街", "松岚路",
        "梧桐街", "海棠路", "清泉街", "远山大道"
    ]
    private static let phonePrefixes = [
        "130", "131", "132", "135", "136", "137", "138", "139",
        "150", "151", "152", "155", "156", "157", "158", "159",
        "166", "173", "175", "176", "177", "178", "180", "181",
        "182", "185", "186", "187", "188", "189", "199"
    ]
    private static let documentationNetworks = ["192.0.2", "198.51.100", "203.0.113"]
    private static let identityRegions = ["110101", "310101", "330106", "440106", "510107"]

    static func generate(_ type: RandomDataType) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(type, using: &generator)
    }

    static func generate<R: RandomNumberGenerator>(_ type: RandomDataType,
                                                   using generator: inout R) -> String {
        switch type {
        case .name:
            return pick(surnames, using: &generator) + pick(givenNames, using: &generator)
        case .email:
            let prefix = pick(emailPrefixes, using: &generator)
            let number = Int.random(in: 10...9999, using: &generator)
            return "\(prefix)\(number)@\(pick(emailDomains, using: &generator))"
        case .address:
            let location = pick(locations, using: &generator)
            let street = pick(streets, using: &generator)
            let number = Int.random(in: 1...399, using: &generator)
            let building = Int.random(in: 1...18, using: &generator)
            let room = Int.random(in: 101...2308, using: &generator)
            return "\(location.0)\(location.1)\(street)\(number)号\(building)号楼\(room)室"
        case .phone:
            return pick(phonePrefixes, using: &generator) +
                String(format: "%08d", Int.random(in: 0...99_999_999, using: &generator))
        case .ipv4:
            return "\(pick(documentationNetworks, using: &generator)).\(Int.random(in: 1...254, using: &generator))"
        case .identityCard:
            let body = identityBody(using: &generator)
            return body + identityChecksum(for: body)
        case .uuid:
            return UUID().uuidString.lowercased()
        case .password:
            return password(using: &generator)
        }
    }

    static func isChecksumValidIdentityCard(_ value: String) -> Bool {
        let normalized = value.uppercased()
        guard normalized.count == 18 else { return false }
        let body = String(normalized.prefix(17))
        guard body.allSatisfy(\.isNumber) else { return false }
        return identityChecksum(for: body) == String(normalized.suffix(1))
    }

    private static func identityBody<R: RandomNumberGenerator>(using generator: inout R) -> String {
        let year = Int.random(in: 1970...2005, using: &generator)
        let month = Int.random(in: 1...12, using: &generator)
        let day = Int.random(in: 1...28, using: &generator)
        let sequence = Int.random(in: 1...999, using: &generator)
        return pick(identityRegions, using: &generator) +
            String(format: "%04d%02d%02d%03d", year, month, day, sequence)
    }

    private static func identityChecksum(for body: String) -> String {
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]
        let total = zip(body.compactMap(\.wholeNumberValue), weights)
            .reduce(0) { $0 + $1.0 * $1.1 }
        return checks[total % 11]
    }

    private static func password<R: RandomNumberGenerator>(using generator: inout R) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz")
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let digits = Array("23456789")
        let symbols = Array("!@#$%&*+-=?")
        let all = lower + upper + digits + symbols
        var characters = [
            pick(lower, using: &generator), pick(upper, using: &generator),
            pick(digits, using: &generator), pick(symbols, using: &generator)
        ]
        while characters.count < 16 {
            characters.append(pick(all, using: &generator))
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }

    private static func pick<Element, R: RandomNumberGenerator>(
        _ values: [Element],
        using generator: inout R
    ) -> Element {
        values[Int.random(in: values.indices, using: &generator)]
    }
}

private extension String {
    var capitalizingFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
