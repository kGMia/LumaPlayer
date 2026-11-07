import Foundation
private struct BrowserEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
    let folder: Bool
    init(_ name: String, parent: String = "/media", folder: Bool = false) {
        self.name = name; self.url = URL(fileURLWithPath: parent).appendingPathComponent(name)
        self.id = url.path; self.folder = folder
    }
}
func checkGrouping() {
    let entries = [BrowserEntry("Show ep01.mkv"), BrowserEntry("Show ep02.mkv"),
        BrowserEntry("Film 2024.mkv"), BrowserEntry("Film 2025.mkv"),
        BrowserEntry("Show ep03.mkv", parent: "/other"), BrowserEntry("Show ep04", folder: true)]
    let grouped = BrowserStack.build(entries, enabled: true)
    precondition(grouped.count == 5 && grouped[0].entries.count == 2)
    precondition(BrowserStack.build(entries, enabled: false).count == entries.count)
    for names in [["Show E01.mp4", "Show E02.mp4"], ["Show episode1.mp4", "Show episode2.mp4"],
                  ["Show 01.mkv", "Show 02.mkv"], ["Show S01E01.mkv", "Show S01E02.mkv"]] {
        precondition(BrowserStack.build(names.map { BrowserEntry($0) }, enabled: true).count == 1)
    }
    print("PASS: episode patterns, opt-out, year exclusion, folder and directory isolation")
}
checkGrouping()
