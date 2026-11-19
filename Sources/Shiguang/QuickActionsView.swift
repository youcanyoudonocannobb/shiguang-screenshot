import SwiftUI

struct QuickActionsView: View {
    @ObservedObject var model: AppModel
    let onCopyText: (String) -> Void
    let onClose: () -> Void
    @StoredState private var variableInput = ""
    @StoredState private var generatedValues: [RandomDataType: String] = [:]
    @StoredState private var dataSearch = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("变量命名", detail: "输入中文、英文或混合词组，实时转换")
                variableNameCard

                HStack(spacing: 12) {
                    sectionTitle("随机测试数据", detail: "点击卡片生成并复制，可在本地反复刷新")
                    Spacer(minLength: 12)
                    dataSearchField.frame(width: 224)
                }
                if filteredRandomTypes.isEmpty {
                    Text("没有匹配的数据类型")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        ForEach(filteredRandomTypes) { type in
                            randomDataCard(type)
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .onAppear(perform: seedGeneratedValues)
        .onExitCommand(perform: onClose)
    }

    private var filteredRandomTypes: [RandomDataType] {
        let query = dataSearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return RandomDataType.allCases }
        return RandomDataType.allCases.filter { type in
            searchKeywords(for: type).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var dataSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            TextField("搜索数据类型，例如：姓名、邮箱、IP", text: $dataSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            if !dataSearch.isEmpty {
                Button { dataSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除数据搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line))
    }

    private var variableNameCard: some View {
        let conversion = VariableNameTransformer.convert(
            variableInput,
            defaultStyle: model.variableNamingStyle
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.abc.dottedunderline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                TextField("例如：xt user profile / 用户 名称", text: $variableInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Menu {
                    ForEach(VariableNamingStyle.allCases) { style in
                        Button {
                            model.variableNamingStyle = style
                        } label: {
                            if style == model.variableNamingStyle {
                                Label("\(style.title) · \(style.shortcut)", systemImage: "checkmark")
                            } else {
                                Text("\(style.title) · \(style.shortcut)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(conversion.style.title)
                        Text(conversion.style.shortcut)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.muted)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 8) {
                Text(conversion.value.isEmpty ? "转换结果会显示在这里" : conversion.value)
                    .font(.system(size: 13, weight: conversion.value.isEmpty ? .regular : .medium,
                                  design: .monospaced))
                    .foregroundStyle(conversion.value.isEmpty ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    guard !conversion.value.isEmpty else { return }
                    onCopyText(conversion.value)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 27)
                }
                .buttonStyle(.plain)
                .foregroundStyle(conversion.value.isEmpty ? Palette.muted : .white)
                .background(conversion.value.isEmpty ? Palette.ink.opacity(0.06) : Palette.accent,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(conversion.value.isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line))

            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.accent)
                Text("命令前缀")
                    .font(.system(size: 9.5, weight: .semibold))
                ForEach(VariableNamingStyle.allCases) { style in
                    Text("\(style.shortcut) \(style.title)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Palette.ink.opacity(0.045), in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line))
    }

    private func randomDataCard(_ type: RandomDataType) -> some View {
        Button {
            let value = RandomDataGenerator.generate(type)
            generatedValues[type] = value
            onCopyText(value)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: type.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 24, height: 24)
                        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(type.title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                Text(generatedValues[type] ?? "点击生成并复制")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(generatedValues[type] == nil ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line))
        }
        .buttonStyle(.plain)
        .help("生成新的\(type.title)并复制")
        .accessibilityLabel("生成并复制\(type.title)")
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.muted)
        }
    }

    private func searchKeywords(for type: RandomDataType) -> [String] {
        let extra: [String]
        switch type {
        case .name:
            extra = ["名字", "name", "randomname"]
        case .email:
            extra = ["邮件", "email", "mail", "randomemail"]
        case .address:
            extra = ["住址", "address", "location", "randomaddress"]
        case .phone:
            extra = ["手机", "电话", "phone", "mobile", "randomphone"]
        case .ipv4:
            extra = ["ip", "ip地址", "randomip"]
        case .identityCard:
            extra = ["身份证号", "idcard", "identitycard", "randomidcard"]
        case .uuid:
            extra = ["guid", "随机uuid"]
        case .password:
            extra = ["密码", "password", "pwd", "randompassword"]
        }
        return [type.title, type.keyword, type.rawValue] + extra
    }

    private func seedGeneratedValues() {
        guard generatedValues.isEmpty else { return }
        for type in RandomDataType.allCases {
            generatedValues[type] = RandomDataGenerator.generate(type)
        }
    }
}
