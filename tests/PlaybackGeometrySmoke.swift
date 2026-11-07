// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct PlaybackGeometrySmoke {
    @MainActor static func main() {
        let state = PlaybackGeometry()
        var sample: [String: Any] = ["media-epoch":1, "media-loaded":true, "seekable":true, "duration":100.0,
            "track-list":[["type":"video"]], "ab-loop-a":10.0, "ab-loop-b":20.0,
            "video-aspect-override":16.0/9, "iive-crop-ratio":"235:100"]
        state.update(sample)
        precondition(state.canLoop && state.hasVideo && state.start==10 && state.end==20)
        precondition(state.aspect=="16:9" && state.crop=="235:100")
        sample["media-epoch"]=2; sample["media-loaded"]=false
        state.update(sample)
        precondition(!state.canLoop && !state.hasLoopPoints && state.aspect=="no" && state.crop=="")
        sample["media-loaded"]=true; sample["ab-loop-a"]=Double.nan; sample["ab-loop-b"]="no"
        sample["duration"]=Double.infinity
        state.update(sample)
        precondition(!state.canLoop && !state.hasLoopPoints)
        sample["duration"]=100.0; sample["seekable"]=false
        state.update(sample)
        precondition(!state.canLoop)
        sample["seekable"]=true; sample["track-list"]=[["type":"audio"],["type":"video","albumart":true]]
        state.update(sample)
        precondition(state.canLoop && !state.hasVideo, "Audio supports loops, cover art is not motion video")
        precondition(VideoRatio.selection(-2, fallback:"no")=="no")
        precondition(PlaybackGeometry.time(.infinity)=="—")
        state.reset();precondition(!state.canLoop && !state.hasLoopPoints)
        print("PASS: loop snapshot validation, file transitions, audio-only controls and aspect selection; no GUI opened.")
    }
}
