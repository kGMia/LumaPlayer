// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "FSRCNNXMetal", platforms: [.macOS(.v13)],
    products: [.library(name: "IIVEFSR", type: .dynamic, targets: ["FSRCNNXMetal"]),
               .library(name: "FSRCNNXMetal", targets: ["FSRCNNXMetal"])],
    targets: [
        .target(name: "FSRCNNXMetal", exclude: ["Shaders"], resources: [.copy("Resources")], plugins: [.plugin(name: "CompileFSRCNNXShaders")]),
        .plugin(name: "CompileFSRCNNXShaders", capability: .buildTool(), path: "Plugins/CompileMetalShaders"),
        .testTarget(name: "FSRCNNXMetalTests", dependencies: ["FSRCNNXMetal"])
    ])
