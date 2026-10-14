// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "FSRCNNXMetal", platforms: [.macOS(.v13)],
    products: [.library(name: "IIVEFSR", type: .dynamic, targets: ["FSRCNNXMetal"])],
    targets: [
        .target(name: "FSRCNNXMetal", exclude: ["Shaders"], resources: [.copy("Resources")], plugins: [.plugin(name: "CompileMetalShaders")]),
        .plugin(name: "CompileMetalShaders", capability: .buildTool()),
        .testTarget(name: "FSRCNNXMetalTests", dependencies: ["FSRCNNXMetal"])
    ])
