// swift-tools-version: 6.4
import PackageDescription

let package = Package(name: "SPANCoreML", platforms: [.macOS(.v15)],
    products: [.library(name: "SPANCoreML", targets: ["SPANCoreML"]),
               .executable(name: "iive-span", targets: ["SPANBench"])],
    dependencies: [.package(path: "../FSRCNNXMetal")],
    targets: [.target(name: "SPANCoreML"),
              .executableTarget(name: "SPANBench", dependencies: ["SPANCoreML",
                .product(name: "FSRCNNXMetal", package: "FSRCNNXMetal")])])
