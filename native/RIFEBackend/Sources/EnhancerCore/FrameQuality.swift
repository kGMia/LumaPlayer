import Foundation

/// Code-value RGB errors, excluding alpha/row padding. Not a perceptual metric.
public struct RGBError: Sendable {
 public private(set) var squaredError:Double=0
 public private(set) var absoluteError:Double=0
 public private(set) var samples:Int=0
 public init() {}
 public mutating func add(reference:Double,predicted:Double) {
  let difference=predicted-reference
  squaredError+=difference*difference;absoluteError+=abs(difference);samples+=1
 }
 public mutating func merge(_ other:RGBError) {
  squaredError+=other.squaredError;absoluteError+=other.absoluteError;samples+=other.samples
 }
 public var mse:Double? {samples>0 ? squaredError/Double(samples) : nil}
 public var mae:Double? {samples>0 ? absoluteError/Double(samples) : nil}
 // Exact matches use nil plus exact_match=true in JSON, never non-JSON Infinity.
 public var psnr:Double? {guard let mse,mse>0 else{return nil};return 10*log10(255*255/mse)}
 public var exactMatch:Bool {samples>0 && squaredError==0}
}
public struct RGBComparison: Sendable {
 public var model=RGBError(),nearest=RGBError(),blend=RGBError()
 public init() {}
 public mutating func merge(_ other:RGBComparison) {
  model.merge(other.model);nearest.merge(other.nearest);blend.merge(other.blend)
 }
 public mutating func add(reference:UInt8,predicted:UInt8,previous:UInt8,next:UInt8,fraction:Double) {
  let r=Double(reference),a=Double(previous),b=Double(next)
  model.add(reference:r,predicted:Double(predicted))
  nearest.add(reference:r,predicted:fraction<=0.5 ? a:b)
  blend.add(reference:r,predicted:a+(b-a)*fraction)
 }
}
