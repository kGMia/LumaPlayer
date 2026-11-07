import Foundation
import CoreMedia

public enum BackendError: Error, CustomStringConvertible {
 case invalid(String)
 public var description: String { switch self { case .invalid(let s):return s } }
}
public struct OutputTime {
 public let pts: CMTime
 public let fraction: Float
}
/// Integer tick scheduling avoids 24->60 midpoint errors and accumulated drift.
/// Input PTS must be monotonic; reset at seeks/discontinuities before pushing.
public struct Timeline {
 public let fps: Int32
 private var origin: CMTime?
 private var tick: Int64 = 0
 public init(fps: Int32) throws {
  guard fps == 48 || fps == 60 else { throw BackendError.invalid("Target FPS must be 48 or 60") }
  self.fps=fps
 }
 public mutating func reset(){ origin=nil;tick=0 }
 public mutating func between(_ a:CMTime,_ b:CMTime) throws -> [OutputTime] {
  guard a.isNumeric,b.isNumeric,CMTimeCompare(b,a)>0 else { throw BackendError.invalid("Non-monotonic PTS") }
  if origin == nil { origin=a }
  let span=CMTimeGetSeconds(CMTimeSubtract(b,a))
  guard span<=1 else { throw BackendError.invalid("PTS gap > 1 second; reset stream") }
  var result:[OutputTime]=[]
  while true {
   let time=CMTimeAdd(origin!,CMTime(value:tick,timescale:fps))
   if CMTimeCompare(time,b)>=0 {break}
   tick+=1
   if CMTimeCompare(time,a)<0 {continue}
   // time < b in exact CMTime arithmetic, but a nanosecond-rounded input PTS
   // can make the Float conversion round up to 1, which RifeStream rejects.
   // Preserve the exact output clock/count; constrain only the model argument.
   let fraction=min(Float(1).nextDown,Float(CMTimeGetSeconds(CMTimeSubtract(time,a))/span))
   result.append(OutputTime(pts:time,fraction:fraction))
   if result.count>60 {throw BackendError.invalid("Output queue bound exceeded")}
  }
  return result
 }
}
