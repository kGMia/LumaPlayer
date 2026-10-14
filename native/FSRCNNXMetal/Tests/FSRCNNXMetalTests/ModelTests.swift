import XCTest
import Metal
import CoreVideo
@testable import FSRCNNXMetal
final class ModelTests:XCTestCase {
    func testTrainedModelsAgainstSmallReference()throws {
        guard ProcessInfo.processInfo.environment["IIVE_GPU_TESTS"]=="1" else{throw XCTSkip("Set IIVE_GPU_TESTS=1")}
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),w=16,h=12
        for tier in [FSRCNNXTier.fast8,.quality16] {
            let model=try FSRCNNXModel(device:device,width:w,height:h,tier:tier)
            let pixels=try model.makeInput()
            CVPixelBufferLockBaseAddress(pixels,[])
            let y=CVPixelBufferGetBaseAddressOfPlane(pixels,0)!.assumingMemoryBound(to:UInt8.self)
            var input=[Float](repeating:0,count:w*h)
            for row in 0..<h {for col in 0..<w {
                let value=UInt8(40+(col*7+row*11)%160)
                y[row*CVPixelBufferGetBytesPerRowOfPlane(pixels,0)+col]=value
                input[row*w+col]=Float(Float16(Float(value)/255))
            }}
            let uv=CVPixelBufferGetBaseAddressOfPlane(pixels,1)!
            for row in 0..<h/2 {memset(uv+row*CVPixelBufferGetBytesPerRowOfPlane(pixels,1),128,w)}
            CVPixelBufferUnlockBaseAddress(pixels,[])
            let output=try model.process(pixels)
            XCTAssertEqual(CVPixelBufferGetWidth(output),w*2);XCTAssertEqual(CVPixelBufferGetHeight(output),h*2)
            // Scalar reference: edge replication, HWIO, residual before channel PReLU.
            var tensors=["input":input]
            for layer in model.weights.layers {
                let k=layer.shape[0],ci=layer.shape[2],co=layer.shape[3],r=layer.shape[0]/2
                let src=tensors[layer.input]!,weights=layer.weights.map{Float(Float16($0))}
                var dst=[Float](repeating:0,count:w*h*co)
                for yy in 0..<h {for xx in 0..<w {for oc in 0..<co {
                    var sum:Float=0
                    for ky in 0..<k {for kx in 0..<k {for ic in 0..<ci {
                        let index=(min(h-1,max(0,yy+ky-r))*w+min(w-1,max(0,xx+kx-r)))*ci+ic
                        sum+=src[index]*weights[((ky*k+kx)*ci+ic)*co+oc]
                    }}}
                    sum=Float(Float16(sum));sum=Float(Float16(sum+Float(Float16(layer.bias[oc]))))
                    let pos=(yy*w+xx)*co+oc
                    if let skip=layer.skip {sum=Float(Float16(sum+tensors[skip]![pos]))}
                    if !layer.alpha.isEmpty && sum<0 {sum=Float(Float16(sum*Float(Float16(layer.alpha[oc]))))}
                    dst[pos]=sum
                }}}
                tensors[layer.name]=dst
            }
            let sub=tensors["stage6"]!
            CVPixelBufferLockBaseAddress(output,.readOnly)
            let bytes=CVPixelBufferGetBaseAddressOfPlane(output,0)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRowOfPlane(output,0)
            var error:Float=0
            for yy in 0..<h*2 {for xx in 0..<w*2 {
                let expected=min(1,max(0,sub[((yy/2)*w+xx/2)*4+(xx%2)*2+yy%2]))
                error+=abs(Float(bytes[yy*stride+xx])/255-expected)
            }}
            CVPixelBufferUnlockBaseAddress(output,.readOnly)
            XCTAssertLessThan(error/Float(w*h*4),0.01,"\(tier) FP16 graph/reference mismatch")
        }
    }
}
