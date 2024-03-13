import AVFoundation
import Accelerate

extension BreathObsever: AVCaptureAudioDataOutputSampleBufferDelegate {
  @MainActor public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    
    guard collectingData else {
      return
    }
    
    var audioBufferList = AudioBufferList()
    var blockBuffer: CMBlockBuffer?
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &audioBufferList,
      bufferListSize: MemoryLayout.stride(ofValue: audioBufferList),
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &blockBuffer)
    
    guard let data = audioBufferList.mBuffers.mData else {
      return
    }
    
    /// Creates an array from `data` and appends it to  `rawBufferAudioData`:
    if rawAudioData.count < Self.samples * 2 {
      let actualSampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
      let pointer = data.bindMemory(to: Int16.self, capacity: actualSampleCount)
      let buffer = UnsafeMutableBufferPointer(start: pointer, count: actualSampleCount)
      
      rawAudioData.append(contentsOf: buffer)
    }
    
    /// The following code app passes the first `sampleCount`elements of raw audio data to the
    /// `processData(values:)` function, and removes the first `hopCount` elements from
    /// `rawBufferAudioData`.
    ///
    /// By removing fewer elements than each step processes, the rendered frames of data overlap,
    /// ensuring no loss of audio data.
    while rawAudioData.count >= Self.samples {
      let dataToProcess = Array(rawAudioData[0 ..< Self.samples])
      rawAudioData.removeFirst(Self.hopCount)
      processData(values: dataToProcess)
    }
    
    let amplitude = timeDomainBuffer.reduce(0.0) { max($0, abs($1)) } // vDSP.rootMeanSquare(timeDomainBuffer)
    
    processingBuffer[counter] = amplitude
    
    counter += 1
    
    if counter == Self.processingSamples {
      counter = 0
      // apply Hanning window to smoothing the data
//      print("🙆🏻🙆🏻🙆🏻 \(processingBuffer)")
      vDSP.multiply(processingBuffer, processingHanningWindow, result: &processingBuffer)
//      print("🙆🏻🙆🏻🙆🏻🙆🏻 \(processingBuffer)")
      
      // downsample to half
      let filter = [Float](repeating: 1, count: 1)
      let downsampled = vDSP.downsample(processingBuffer, decimationFactor: 2, filter: filter)
      
      print("🙆🏻🙆🏻🙆🏻🙆🏻🙆🏻 \(downsampled)")
      
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else {
          return
        }
        calculateRespiratoryRate(from: downsampled)
      }
      
      processingBuffer = [Float](repeating: 0, count: Self.processingSamples)
    }
    
    // update the amplitude visual
    Task { @MainActor [unowned self] in
      let threshold: Float = 2000
      amplitudeSubject.send(amplitude > threshold ? threshold : amplitude)
    }
  }
}
