import Foundation

enum VariableNamingStyle: String, Codable, CaseIterable, Hashable, Identifiable {
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
        case "xt", "lt", "lc", "lowercamel", "camel", "小驼峰":
            return .lowerCamel
        case "dt", "uc", "uppercamel", "pascal", "大驼峰":
            return .upperCamel
        case "snake", "snakecase", "xhx", "_", "下划线":
            return .snakeCase
        case "kebab", "kebabcase", "dhx", "-", "短横线":
            return .kebabCase
        case "const", "constant", "cl", "upper", "uppercase", "常量":
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

enum ChineseEnglishGlossary {
    private static let terms: [(String, String)] = [
        ("购物车", "cart"), ("管理员", "administrator"), ("身份证", "identity card"),
        ("用户名", "username"), ("用户名称", "user name"), ("用户", "user"),
        ("名称", "name"), ("名字", "name"), ("登录", "login"), ("注册", "register"),
        ("页面", "page"), ("界面", "interface"), ("手机号码", "phone number"),
        ("手机号", "phone"), ("手机", "phone"), ("电话", "telephone"), ("邮箱", "email"),
        ("邮件", "mail"), ("地址", "address"), ("密码", "password"), ("验证码", "verification code"),
        ("订单", "order"), ("列表", "list"), ("详情", "detail"), ("创建", "create"),
        ("新增", "add"), ("更新", "update"), ("编辑", "edit"), ("删除", "delete"),
        ("查询", "query"), ("搜索", "search"), ("筛选", "filter"), ("排序", "sort"),
        ("数据", "data"), ("数据库", "database"), ("接口", "api"), ("服务端", "server"),
        ("客户端", "client"), ("服务", "service"), ("图片", "image"), ("文件", "file"),
        ("上传", "upload"), ("下载", "download"), ("时间", "time"), ("日期", "date"),
        ("状态", "status"), ("类型", "type"), ("配置", "configuration"), ("设置", "settings"),
        ("角色", "role"), ("权限", "permission"), ("文章", "article"), ("标题", "title"),
        ("内容", "content"), ("消息", "message"), ("通知", "notification"), ("评论", "comment"),
        ("支付", "payment"), ("金额", "amount"), ("价格", "price"), ("商品", "product"),
        ("库存", "inventory"), ("公司", "company"), ("部门", "department"), ("员工", "employee"),
        ("学生", "student"), ("老师", "teacher"), ("账号", "account"), ("账户", "account"),
        ("输入", "input"), ("输出", "output"), ("结果", "result"), ("错误", "error"),
        ("成功", "success"), ("失败", "failure"), ("加载", "loading"), ("刷新", "refresh"),
        ("确认", "confirm"), ("取消", "cancel"), ("首页", "home"), ("个人中心", "profile"),
        ("功能", "function"), ("模块", "module"), ("系统", "system"), ("的", " ")
    ].sorted { $0.0.count > $1.0.count }

    static func translate(_ input: String) -> String? {
        guard containsChinese(input) else { return input }
        var translated = input
        for (chinese, english) in terms {
            translated = translated.replacingOccurrences(of: chinese, with: " \(english) ")
        }
        guard !containsChinese(translated) else { return nil }
        let normalized = translated
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func containsChinese(_ input: String) -> Bool {
        input.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value) ||
                (0xF900...0xFAFF).contains(scalar.value)
        }
    }
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
        let latin = ChineseEnglishGlossary.translate(input)
            ?? input.applyingTransform(.toLatin, reverse: false)
            ?? input
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

    static func convertEnglish(_ input: String,
                               style: VariableNamingStyle) -> String {
        style.apply(to: words(from: input))
    }
}

enum QuickLauncherCommand: Hashable, Identifiable {
    case variable(VariableNamingStyle)
    case random(RandomDataType)

    var id: String {
        switch self {
        case .variable(let style): return "variable.\(style.rawValue)"
        case .random(let type): return "random.\(type.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .variable(let style): return style.title
        case .random(let type): return "随机\(type.title)"
        }
    }

    var trigger: String {
        switch self {
        case .variable(let style): return style.shortcut
        case .random(let type):
            switch type {
            case .name: return "name"
            case .email: return "email"
            case .address: return "address"
            case .phone: return "phone"
            case .ipv4: return "ip"
            case .identityCard: return "idcard"
            case .uuid: return "uuid"
            case .password: return "password"
            }
        }
    }

    var aliases: [String] {
        switch self {
        case .variable(.lowerCamel): return ["xt", "lt", "lc", "camel", "小驼峰"]
        case .variable(.upperCamel): return ["dt", "uc", "pascal", "大驼峰"]
        case .variable(.snakeCase): return ["snake", "xhx", "下划线"]
        case .variable(.kebabCase): return ["kebab", "dhx", "短横线"]
        case .variable(.constantCase): return ["const", "cl", "常量"]
        case .random(.name): return ["name", "xm", "姓名", "名字"]
        case .random(.email): return ["email", "mail", "邮箱"]
        case .random(.address): return ["address", "dz", "地址", "住址"]
        case .random(.phone): return ["phone", "mobile", "sjh", "手机", "手机号"]
        case .random(.ipv4): return ["ip", "ipv4", "ip地址"]
        case .random(.identityCard): return ["idcard", "identitycard", "sfz", "身份证"]
        case .random(.uuid): return ["uuid", "guid"]
        case .random(.password): return ["password", "pwd", "mm", "密码"]
        }
    }

    var symbol: String {
        switch self {
        case .variable: return "textformat.abc"
        case .random(let type): return type.symbol
        }
    }

    var detail: String {
        switch self {
        case .variable:
            return "中文先译成英文，再转换为变量名"
        case .random(let type):
            return "生成一个\(type.title)测试值"
        }
    }

    var example: String {
        switch self {
        case .variable(.lowerCamel): return "xt 用户登录 → userLogin"
        case .variable(.upperCamel): return "dt 用户登录 → UserLogin"
        case .variable(.snakeCase): return "snake 用户登录 → user_login"
        case .variable(.kebabCase): return "kebab 用户登录 → user-login"
        case .variable(.constantCase): return "const 用户登录 → USER_LOGIN"
        case .random(let type): return "\(trigger) → \(type.title)"
        }
    }

    static let all: [QuickLauncherCommand] = VariableNamingStyle.allCases.map(Self.variable) +
        RandomDataType.allCases.map(Self.random)

    static func matching(_ token: String) -> Self? {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        return all.first { command in
            command.aliases.contains { $0.lowercased() == value }
        }
    }
}

struct QuickLauncherInvocation: Equatable {
    let command: QuickLauncherCommand
    let argument: String
}

enum QuickLauncherParser {
    static func invocation(from rawInput: String) -> QuickLauncherInvocation? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if let first = parts.first,
           let command = QuickLauncherCommand.matching(String(first)) {
            let argument = parts.count == 2
                ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return QuickLauncherInvocation(command: command, argument: argument)
        }

        let aliases = QuickLauncherCommand.all
            .flatMap { command in command.aliases.map { ($0.lowercased(), command) } }
            .sorted { $0.0.count > $1.0.count }
        for (alias, command) in aliases {
            guard input.lowercased().hasPrefix(alias) else { continue }
            let remainder = String(input.dropFirst(alias.count))
            guard ChineseEnglishGlossary.containsChinese(remainder) else { continue }
            return QuickLauncherInvocation(
                command: command,
                argument: remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if let type = RandomDataType.fromKeyword(input) {
            return QuickLauncherInvocation(command: .random(type), argument: "")
        }
        return nil
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

    static func fromKeyword(_ value: String) -> Self? {
        let keyword = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        switch keyword {
        case "姓名", "名字", "name", "randomname", "随机姓名":
            return .name
        case "邮箱", "邮件", "email", "mail", "randomemail", "随机邮箱":
            return .email
        case "地址", "住址", "address", "location", "randomaddress", "随机地址":
            return .address
        case "手机号", "手机", "电话", "phone", "mobile", "randomphone", "随机手机号":
            return .phone
        case "ip", "ipv4", "ip地址", "randomip", "随机ip":
            return .ipv4
        case "身份证", "身份证号", "idcard", "identitycard", "randomidcard", "随机身份证":
            return .identityCard
        case "uuid", "guid", "随机uuid":
            return .uuid
        case "密码", "强密码", "password", "pwd", "randompassword", "随机密码":
            return .password
        default:
            return nil
        }
    }

    var keyword: String {
        switch self {
        case .name: return "姓名"
        case .email: return "邮箱"
        case .address: return "地址"
        case .phone: return "手机号"
        case .ipv4: return "IP"
        case .identityCard: return "身份证"
        case .uuid: return "UUID"
        case .password: return "密码"
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
