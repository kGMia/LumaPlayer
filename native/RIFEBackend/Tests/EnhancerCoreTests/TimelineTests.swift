import XCTest
import CoreMedia
@testable import EnhancerCore
final class TimelineTests:XCTestCase {
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
