// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "EnhancementBench", platforms: [.macOS(.v15)],
    products: [.executable(name: "iive-enhancement-bench", targets: ["EnhancementBench"])],
    dependencies: [.package(path: "../FSRCNNXCoreML"), .package(path: "../FSRCNNXMetal"),
                   .package(path: "../../vendor/rife-metal")],
    targets: [.executableTarget(name: "EnhancementBench", dependencies: [
        .product(name: "FSRCNNXCoreML", package: "FSRCNNXCoreML"),
        .product(name: "FSRCNNXMetal", package: "FSRCNNXMetal"),
        .product(name: "RifeMetal", package: "rife-metal")])])
