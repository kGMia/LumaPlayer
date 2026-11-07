import XCTest
import CoreMedia
@testable import EnhancerCore
final class TimelineTests:XCTestCase {
 func testRoundedNanosecondBoundaryKeepsModelFractionBelowOne()throws{
  var t=try Timeline(fps:60)
  // The 1/30 boundary rounded upward to nanoseconds is only 2/3 ns
  // beyond the output tick. A direct Float cast rounds its fraction to 1.
  let end=CMTime(value:33_333_334,timescale:1_000_000_000)
  let frames=try t.between(.zero,end)
  XCTAssertEqual(frames.count,3)
  XCTAssertLessThan(frames.last!.fraction,1)
  XCTAssertGreaterThan(frames.last!.fraction,0.999999)
  XCTAssertEqual(CMTimeCompare(frames.last!.pts,CMTime(value:2,timescale:60)),0)
  let next=try t.between(end,CMTime(value:66_666_667,timescale:1_000_000_000))
  XCTAssertGreaterThan(CMTimeCompare(next.first!.pts,frames.last!.pts),0)
 }
 func test24to60()throws{
  var t=try Timeline(fps:60)
  let first=try t.between(.zero,CMTime(value:1,timescale:24))
  XCTAssertEqual(first.map(\.fraction),[0,0.4,0.8])
  let second=try t.between(CMTime(value:1,timescale:24),CMTime(value:2,timescale:24))
  XCTAssertEqual(second.map(\.fraction),[0.2,0.6])
 }
 func test24to48AndReset()throws{
  var t=try Timeline(fps:48)
  XCTAssertEqual(try t.between(.zero,CMTime(value:1,timescale:24)).map(\.fraction),[0,0.5])
  t.reset();let start=CMTime(value:9,timescale:1)
  XCTAssertEqual(try t.between(start,CMTimeAdd(start,CMTime(value:1,timescale:24))).first?.pts,start)
 }
 func testInvalidPTS()throws{var t=try Timeline(fps:48);XCTAssertThrowsError(try t.between(.zero,.zero))}
}
