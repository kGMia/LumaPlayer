// Compiled with the actual NFO parser and save implementation by check-nfo-write.py.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("episode.nfo")
let original = Data("<episodedetails><title>Old</title><uniqueid type='tmdb'>42</uniqueid><actor><name>A</name><role>B</role><thumb>image.jpg</thumb></actor></episodedetails>".utf8)
try original.write(to: file)
var metadata = NFOParser.parse(original)!
metadata.title = "New & title"
try await Writer().saveLocalMetadata(metadata, forMediaPath: dir.appendingPathComponent("episode.mkv").path, preferredNFOURL: file)
let updated = try XMLDocument(data: Data(contentsOf: file), options: [])
precondition(updated.rootElement()?.name == "episodedetails")
precondition((try! updated.nodes(forXPath: "//uniqueid")).first?.stringValue == "42")
precondition((try! updated.nodes(forXPath: "//actor/role")).first?.stringValue == "B")
precondition((try! updated.nodes(forXPath: "//title")).first?.stringValue == "New & title")
precondition((try! Data(contentsOf: file.appendingPathExtension("luma-backup"))) == original)
print("PASS: NFO root, unknown fields, actor details, escaping and original backup")

let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: file.path)
do {
    try await Writer().saveLocalMetadata(metadata, forMediaPath: "unused", preferredNFOURL: file, expectedModification: stamp)
    fatalError("External edit was overwritten")
} catch let error as CocoaError { precondition(error.code == .fileWriteFileExists) }
print("PASS: external NFO modification rejected")

let baseline = try Data(contentsOf: file)
try Data("<movie><title>External edit</title></movie>".utf8).write(to: file)
do {
    try await Writer().saveLocalMetadata(metadata, forMediaPath: "unused", preferredNFOURL: file, expectedContents: baseline)
    fatalError("Changed contents overwritten")
} catch let error as CocoaError { precondition(error.code == .fileWriteFileExists) }
do {
    try await Writer().saveLocalMetadata(metadata, forMediaPath: "unused", preferredNFOURL: file, expectsMissing: true)
    fatalError("Concurrent new file overwritten")
} catch let error as CocoaError { precondition(error.code == .fileWriteFileExists) }
print("PASS: content conflicts and concurrent creation rejected")
