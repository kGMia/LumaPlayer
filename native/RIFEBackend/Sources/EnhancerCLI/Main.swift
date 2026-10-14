import Foundation
import RifeMetal
import EnhancerCore
@main struct CLI {
 static func main() async {
  do {
   let a=Array(CommandLine.arguments.dropFirst())
   if a.first=="bench",a.count==5,let w=Int(a[1]),let h=Int(a[2]),let tier=RifeQualityTier(rawValue:a[3]),let n=Int(a[4]) {try benchmark(width:w,height:h,tier:tier,iterations:n)}
   else if a.first=="process",a.count>=5,let fps=Int32(a[3]),let tier=RifeQualityTier(rawValue:a[4]) {try await convert(input:URL(fileURLWithPath:a[1]),output:URL(fileURLWithPath:a[2]),fps:fps,tier:tier,autoFallback:!a.contains("--no-fallback"))}
   else {throw BackendError.invalid("Usage: iive-rife bench WIDTH HEIGHT fast|balanced|hq ITERATIONS\n       iive-rife process INPUT OUTPUT.mov 48|60 fast|balanced|hq [--no-fallback]")}
  }catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
 }
}
