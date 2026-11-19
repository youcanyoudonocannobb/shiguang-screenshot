// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shiguang",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Shiguang", targets: ["Shiguang"])],
    targets: [
        .executableTarget(name: "Shiguang")
    ],
    swiftLanguageModes: [.v5]
)
