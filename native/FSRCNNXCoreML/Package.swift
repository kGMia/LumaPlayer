// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "FSRCNNXCoreML", platforms: [.macOS(.v15)],
    products: [.library(name: "FSRCNNXCoreML", targets: ["FSRCNNXCoreML"]),
               .executable(name: "iive-fsrcnnx-coreml", targets: ["FSRBench"])],
    dependencies: [.package(path: "../FSRCNNXMetal")],
    targets: [.target(name: "FSRCNNXCoreML"),
              .executableTarget(name: "FSRBench", dependencies: ["FSRCNNXCoreML",
                .product(name: "FSRCNNXMetal", package: "FSRCNNXMetal")])])
