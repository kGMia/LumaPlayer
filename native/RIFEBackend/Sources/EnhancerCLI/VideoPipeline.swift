import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import RifeMetal
import EnhancerCore

func convert(input:URL,output:URL,fps:Int32,tier:RifeQualityTier,autoFallback:Bool,modelURL:URL=RifeConfiguration.bundledModelURL) async throws {
 guard input.standardizedFileURL != output.standardizedFileURL,!FileManager.default.fileExists(atPath:output.path) else {throw BackendError.invalid("Output must be a new file; refusing overwrite")}
 let begin=ProcessInfo.processInfo.systemUptime
 let asset=AVURLAsset(url:input)
 guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw BackendError.invalid("No video track")}
 guard try await track.load(.preferredTransform) == .identity else {throw BackendError.invalid("Rotated sources not supported in this prototype")}
 guard let format=try await track.load(.formatDescriptions).first else {throw BackendError.invalid("Missing video format")}
 let ext=(CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
 let trc=ext[kCMFormatDescriptionExtension_TransferFunction] as? String
 let prim=ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String
 guard trc == kCVImageBufferTransferFunction_ITU_R_709_2 as String,prim == kCVImageBufferColorPrimaries_ITU_R_709_2 as String else {throw BackendError.invalid("Prototype requires explicitly tagged SDR BT.709. HDR/unknown color rejected. prim=\(String(describing:prim)), transfer=\(String(describing:trc))")}
 let nominalFPS=try await track.load(.nominalFrameRate)
 guard nominalFPS>0,Double(nominalFPS)<Double(fps) else {throw BackendError.invalid("Source FPS must be known and below target FPS")}
 let dims=CMVideoFormatDescriptionGetDimensions(format),w=Int(dims.width),h=Int(dims.height)
 let processor=try FrameProcessor(width:w,height:h,fps:fps,tier:tier,autoFallback:autoFallback,modelURL:modelURL)
 let reader=try AVAssetReader(asset:asset)
 let readVideo=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
 readVideo.alwaysCopiesSampleData=false;reader.add(readVideo)
 let writer=try AVAssetWriter(outputURL:output,fileType:.mov)
 let writeVideo=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:w,AVVideoHeightKey:h,AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:max(4_000_000,w*h*8),AVVideoExpectedSourceFrameRateKey:Int(fps)]])
 writeVideo.expectsMediaDataInRealTime=false
 writeVideo.mediaTimeScale=60000
 let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:writeVideo,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
 writer.add(writeVideo)
 var readAudio:AVAssetReaderTrackOutput?,writeAudio:AVAssetWriterInput?
 if let audio=try await asset.loadTracks(withMediaType:.audio).first {
  let r=AVAssetReaderTrackOutput(track:audio,outputSettings:nil);r.alwaysCopiesSampleData=false;reader.add(r);readAudio=r
  guard let hint=try await audio.load(.formatDescriptions).first else {throw BackendError.invalid("Missing audio format")}
  let out=AVAssetWriterInput(mediaType:.audio,outputSettings:nil,sourceFormatHint:hint)
  guard writer.canAdd(out) else{throw BackendError.invalid("Audio codec cannot be passed through to MOV")}
  writer.add(out);writeAudio=out
 }
 guard writer.startWriting() else{throw writer.error ?? BackendError.invalid("Writer start failed")}
 writer.startSession(atSourceTime:.zero)
 guard reader.startReading() else{throw reader.error ?? BackendError.invalid("Reader start failed")}
 let audioGroup=DispatchGroup()
 let audioPump:AudioPump? = readAudio.flatMap { r in writeAudio.map { AudioPump(reader:r,input:$0,writer:writer) } }
 if let pump=audioPump {
  audioGroup.enter();DispatchQueue(label:"iive.audio").async {pump.run();audioGroup.leave()}
 }
 var count=0,synthesized=0,lastPTS=CMTime.zero,lastDuration=CMTime(seconds:1/Double(nominalFPS),preferredTimescale:60000)
 func append(_ frames:[VideoFrame]) throws {
  for frame in frames {
   let waitStart=ProcessInfo.processInfo.systemUptime
   while !writeVideo.isReadyForMoreMediaData && writer.status == .writing {
    if ProcessInfo.processInfo.systemUptime-waitStart>30{throw BackendError.invalid("Encoder backpressure timeout")}
    Thread.sleep(forTimeInterval:0.002)
   }
   guard adaptor.append(frame.pixels,withPresentationTime:frame.pts) else{throw writer.error ?? BackendError.invalid("Append failed")}
   count+=1;if frame.synthesized{synthesized+=1}
  }
 }
 do {
  while let sample=readVideo.copyNextSampleBuffer() {
   try autoreleasepool {
    guard let image=CMSampleBufferGetImageBuffer(sample) else{throw BackendError.invalid("Missing pixel buffer")}
    lastPTS=CMSampleBufferGetPresentationTimeStamp(sample)
    let duration=CMSampleBufferGetDuration(sample)
    if duration.isNumeric && CMTimeGetSeconds(duration)>0{lastDuration=duration}
    else if nominalFPS>0 {lastDuration=CMTime(seconds:1/Double(nominalFPS),preferredTimescale:60000)}
    try append(processor.push(image,pts:lastPTS))
   }
  }
  guard reader.status != .failed else{throw reader.error ?? BackendError.invalid("Decode failed")}
  try append(processor.finish(end:CMTimeAdd(lastPTS,lastDuration)))
  writeVideo.markAsFinished();await waitForAudio(audioGroup)
  if let error=audioPump?.failure {throw error}
  writer.endSession(atSourceTime:CMTimeAdd(lastPTS,lastDuration))
  await writer.finishWriting()
  guard writer.status == .completed else{throw writer.error ?? BackendError.invalid("Encode failed")}
 }catch {reader.cancelReading();writer.cancelWriting();await waitForAudio(audioGroup);throw error}
 let wall=ProcessInfo.processInfo.systemUptime-begin
 try Stats.emit(["kind":"decode_rife_encode","model_file":modelURL.lastPathComponent,"output":output.path,"tier":tier.rawValue,"target_fps":fps,"output_frames":count,"synthesized_frames":synthesized,"wall_seconds":wall,"throughput_fps":Double(count)/wall,"media_seconds":CMTimeGetSeconds(CMTimeAdd(lastPTS,lastDuration)),"latency_per_pair_recent_4096":Stats.summarize(processor.inferenceMilliseconds),"inference_pairs_total":processor.inferenceCount,"inference_mean_ms_all":processor.inferenceCount>0 ? processor.inferenceTotalMilliseconds/Double(processor.inferenceCount) : NSNull(),"fallback_to_source_cadence":processor.fallback,"scene_cuts":processor.sceneCuts,"duplicates":processor.duplicates,"peak_rss_bytes":Stats.memory(),"audio":"first track passthrough with original PTS","dropped_frames":0,"player_realtime":NSNull(),"gpu_utilization":NSNull(),"note":"Bounded synchronous pipeline, at most one adjacent pair and one interval of output frames. Includes setup and graph cold start; MOV output is not stock IINA realtime integration."])
}

// This object exclusively owns audio reads/appends on its worker. AVAssetWriter
// supports distinct inputs on separate queues. failure is read only after join.
private final class AudioPump: @unchecked Sendable {
 let reader:AVAssetReaderTrackOutput, input:AVAssetWriterInput, writer:AVAssetWriter
 var failure:Error?
 init(reader:AVAssetReaderTrackOutput,input:AVAssetWriterInput,writer:AVAssetWriter){self.reader=reader;self.input=input;self.writer=writer}
 func run(){
  defer{input.markAsFinished()}
  while let sample=reader.copyNextSampleBuffer(){
   let start=ProcessInfo.processInfo.systemUptime
   while !input.isReadyForMoreMediaData && writer.status == .writing {
    if ProcessInfo.processInfo.systemUptime-start>30 {failure=BackendError.invalid("Audio backpressure timeout");writer.cancelWriting();return}
    Thread.sleep(forTimeInterval:0.002)
   }
   guard writer.status == .writing,input.append(sample) else {failure=writer.error ?? BackendError.invalid("Audio append failed");writer.cancelWriting();return}
  }
 }
}

private func waitForAudio(_ group:DispatchGroup) async {await withCheckedContinuation { continuation in group.notify(queue:.global()){continuation.resume()} }}
