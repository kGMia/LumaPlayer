import Foundation
@main struct FrameQualitySmoke {
 static func main() {
  var empty=RGBError()
  precondition(empty.mse==nil && empty.mae==nil && empty.psnr==nil && !empty.exactMatch)
  empty.add(reference:12,predicted:12)
  precondition(empty.exactMatch && empty.psnr==nil && empty.mse==0)
  var errors=RGBComparison()
  errors.add(reference:15,predicted:16,previous:10,next:30,fraction:0.25)
  precondition(errors.model.mae==1 && errors.model.mse==1)
  precondition(abs(errors.model.psnr! - 48.1308036086791)<1e-9)
  precondition(errors.nearest.mse==25 && errors.blend.exactMatch)
  var second=RGBComparison()
  second.add(reference:25,predicted:28,previous:10,next:30,fraction:0.75)
  errors.merge(second)
  precondition(errors.model.samples==2 && errors.model.mse==5 && errors.model.mae==2)
  precondition(errors.nearest.mse==25 && errors.blend.exactMatch)
  print("PASS RGB error, exact match, weighted blend, nearest endpoint, pooled MSE")
 }
}
