// Derived from cinemore/rife-metal CompileMetalShaders, Apache-2.0.
// Original license: vendor/rife-metal/LICENSE.
import PackagePlugin
import Foundation

@main
struct CompileMetalShaders: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        // Discover .metal files under the target's Shaders/ directory directly.
        // We can't use target.sourceFiles because Shaders/ is excluded from the
        // SwiftPM source list (so Xcode's auto-MetalLink phase doesn't pick them
        // up and collide with our plugin).
        let shadersDir = target.directory.appending("Shaders")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: shadersDir.string)) ?? []
        let metalFiles = entries
            .filter { $0.hasSuffix(".metal") }
            .map { shadersDir.appending($0) }
        guard !metalFiles.isEmpty else { return [] }

        let outputDir = context.pluginWorkDirectory.appending("MetalLib")
        let moduleCacheDir = context.pluginWorkDirectory.appending("MetalModuleCache")
        let airFiles = metalFiles.map { metal -> Path in
            outputDir.appending(metal.stem + ".air")
        }
        let metallibPath = outputDir.appending("default.metallib")

        // Locate metal and metallib via xcrun (with fallback to prebuilt default.metallib if MetalToolchain is not active)
        if let metalPath = xcrunFind("metal"), let metallibToolPath = xcrunFind("metallib") {
            var commands: [Command] = []

            for (metal, air) in zip(metalFiles, airFiles) {
                commands.append(.buildCommand(
                    displayName: "Compile \(metal.lastComponent)",
                    executable: Path(metalPath),
                    arguments: [
                        "-c",
                        "-fmodules-cache-path=\(moduleCacheDir.string)",
                        metal.string,
                        "-o", air.string,
                    ],
                    inputFiles: [metal],
                    outputFiles: [air]
                ))
            }

            commands.append(.buildCommand(
                displayName: "Link default.metallib",
                executable: Path(metallibToolPath),
                arguments: airFiles.map { $0.string } + ["-o", metallibPath.string],
                inputFiles: airFiles,
                outputFiles: [metallibPath]
            ))

            return commands
        }

        let prebuilt = shadersDir.appending("default.metallib.prebuilt")
        guard FileManager.default.fileExists(atPath: prebuilt.string) else {
            throw PluginError.toolNotFound("metallib")
        }
        return [
            .buildCommand(
                displayName: "Copy prebuilt default.metallib",
                executable: Path("/bin/cp"),
                arguments: ["-f", prebuilt.string, metallibPath.string],
                inputFiles: [prebuilt],
                outputFiles: [metallibPath]
            )
        ]
    }

    private func xcrunFind(_ tool: String) -> String? {
        let argumentVariants: [[String]] = [
            ["--find", tool],
            ["--sdk", "macosx", "--find", tool],
            ["--toolchain", "com.apple.dt.toolchain.MetalToolchain", "--find", tool]
        ]
        for args in argumentVariants {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            if (try? process.run()) != nil {
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                        return path
                    }
                }
            }
        }
        return nil
    }

    enum PluginError: Error {
        case toolNotFound(String)
    }
}
