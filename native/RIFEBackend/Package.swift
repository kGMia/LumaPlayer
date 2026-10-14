// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "RIFEBackend", platforms: [.macOS(.v13)], products: [
 .executable(name: "iive-rife", targets: ["EnhancerCLI"]),
 .library(name: "EnhancerCore", targets: ["EnhancerCore"]),
 .library(name: "IIVERIFE", type: .dynamic, targets: ["RIFEBridge"])
], dependencies: [.package(path: "../../vendor/rife-metal")], targets: [
 .target(name: "EnhancerCore", dependencies: [.product(name: "RifeMetal", package: "rife-metal")]),
 .executableTarget(name: "EnhancerCLI", dependencies: ["EnhancerCore", .product(name: "RifeMetal", package: "rife-metal")]),
 .target(name: "RIFEBridge", dependencies: ["EnhancerCore", .product(name: "RifeMetal", package: "rife-metal")]),
 .testTarget(name: "EnhancerCoreTests", dependencies: ["EnhancerCore"])
])
