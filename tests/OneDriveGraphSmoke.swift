// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct OneDriveGraphSmoke {
    static func main() throws {
        let itemURL = OneDriveGraph.itemURL(drive: "drive-1", item: "item-1")
        precondition(OneDriveGraph.graphURL(itemURL))
        for bad in ["http://graph.microsoft.com/v1.0/me", "https://graph.microsoft.com.evil.test/v1.0/me",
                    "https://user:secret@graph.microsoft.com/v1.0/me", "https://graph.microsoft.com:444/v1.0/me",
                    "https://example.test/v1.0/me", "https://graph.microsoft.com/v1.0/me#token"] {
            precondition(!OneDriveGraph.graphURL(URL(string: bad)!))
        }
        let download = try OneDriveGraph.downloadURL("https://example.test/file?temporary=1")
        precondition(download.host == "example.test")
        for bad in ["http://example.test/file", "file:///tmp/file", "https://name:password@example.test/file"] {
            do { _ = try OneDriveGraph.downloadURL(bad); fatalError("Accepted unsafe download") } catch { }
        }
        let fixture = Data(#"{"value":[{"id":"1","name":"clip.mp4","size":42,"video":{"duration":12500}},{"id":"2","name":"Folder","folder":{"childCount":1}},{"id":"3","name":"notes.txt","size":12}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/d/items/f/children?$skiptoken=next"}"#.utf8)
        let page = try JSONDecoder().decode(OneDrivePage.self, from: fixture)
        precondition(page.value[0].duration == 12.5 && page.value[0].playable)
        precondition(!page.value[1].playable && !page.value[2].playable)
        precondition(page.value[0].mediaItem(drive: "d").name == "clip.mp4")
        precondition(OneDriveGraph.graphURL(URL(string: page.nextLink!)!))
        let request = try NetworkMediaRequest(url: OneDriveGraph.downloadURL("https://example.test/opaque?temporary=1"), directFileName: "clip.mp4")
        precondition(request.options["http-header-fields"] == nil)
        precondition(request.options["demuxer-lavf-format"] == "mov")
        precondition(request.options["force-media-title"] == "clip.mp4")
        precondition(request.options["stream-lavf-o"] == "max_redirects=0")
        print("PASS: Graph origin validation, secure anonymous content URL, pagination decoding, media identity and duration units. No account or remote playback tested.")
    }
}
