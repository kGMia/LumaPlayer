import Foundation
import RifeMetal
import EnhancerCore
@main struct CLI {
 static func main() async {
  do {
   var a=Array(CommandLine.arguments.dropFirst())
   func value(_ flag:String)throws->String? {
    guard let i=a.firstIndex(of:flag) else{return nil}
    guard a.filter({$0==flag}).count==1,i+1<a.count,!a[i+1].hasPrefix("--") else{throw BackendError.invalid("Missing or repeated \(flag)")}
    let v=a[i+1];a.removeSubrange(i...i+1);return v
   }
   let modelURL=try value("--model").map{URL(fileURLWithPath:$0)} ?? RifeConfiguration.bundledModelURL
   let sourceValue=try value("--source-fps"),targetValue=try value("--target-fps"),formatValue=try value("--format")
   let startValue=try value("--start"),pairValue=try value("--pairs")
   if a.first=="evaluate",a.count==3,let tier=RifeQualityTier(rawValue:a[2]) {
    guard sourceValue==nil,formatValue==nil,let start=Double(startValue ?? "0"),let pairs=Int(pairValue ?? "8"),let fps=Int32(targetValue ?? "48") else{throw BackendError.invalid("Invalid evaluation options")}
    try await evaluateVideo(input:URL(fileURLWithPath:a[1]),tier:tier,modelURL:modelURL,start:start,pairs:pairs,targetFPS:fps)
   } else if a.first=="bench",a.count==5,let w=Int(a[1]),let h=Int(a[2]),let tier=RifeQualityTier(rawValue:a[3]),let n=Int(a[4]) {
    guard startValue==nil,pairValue==nil,let sourceFPS=Int32(sourceValue ?? "24"),let targetFPS=Int32(targetValue ?? "48"),
          ["bgra","nv12"].contains(formatValue ?? "bgra") else {throw BackendError.invalid("Invalid benchmark FPS/format")}
    try benchmark(width:w,height:h,tier:tier,iterations:n,modelURL:modelURL,sourceFPS:sourceFPS,targetFPS:targetFPS,nv12:formatValue=="nv12")
   } else {
    guard sourceValue==nil,targetValue==nil,formatValue==nil,startValue==nil,pairValue==nil else{throw BackendError.invalid("FPS/format options apply only to bench")}
    let noFallback=a.last=="--no-fallback"
    if noFallback {a.removeLast()}
    if a.first=="process",a.count==5,let fps=Int32(a[3]),let tier=RifeQualityTier(rawValue:a[4]) {
     try await convert(input:URL(fileURLWithPath:a[1]),output:URL(fileURLWithPath:a[2]),fps:fps,tier:tier,autoFallback:!noFallback,modelURL:modelURL)
    } else {throw BackendError.invalid("Usage: iive-rife evaluate INPUT fast|balanced|hq [--pairs 8] [--start SECONDS] [--target-fps 48|60] [--model FILE.rmw]\n       iive-rife bench WIDTH HEIGHT fast|balanced|hq PAIRS [--source-fps 24|30] [--target-fps 48|60] [--format bgra|nv12] [--model FILE.rmw]\n       iive-rife process INPUT OUTPUT.mov 48|60 fast|balanced|hq [--no-fallback] [--model FILE.rmw]")}
   }
  }catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
 }
}
