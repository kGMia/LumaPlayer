import Foundation
import Darwin
struct Stats {
 static func summarize(_ samples:[Double])->[String:Any] {
  let s=samples.sorted()
  guard !s.isEmpty else{return ["samples":0,"mean_ms":NSNull(),"p50_ms":NSNull(),"p95_ms":NSNull()]}
  func q(_ p:Double)->Double{s[min(s.count-1,Int(ceil(Double(s.count)*p))-1)]}
  return ["samples":s.count,"mean_ms":s.reduce(0,+)/Double(s.count),"p50_ms":q(0.5),"p95_ms":q(0.95)]
 }
 static func emit(_ data:[String:Any]) throws {let d=try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(d);print("")}
 static func memory()->Int64 {var r=rusage();getrusage(RUSAGE_SELF,&r);return Int64(r.ru_maxrss)}
}
