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
    if rawBufferAudioData.count < Self.samples * 2 {
      let actualSampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
      let pointer = data.bindMemory(to: Int16.self, capacity: actualSampleCount)
      let buffer = UnsafeMutableBufferPointer(start: pointer, count: actualSampleCount)
      
      rawBufferAudioData.append(contentsOf: buffer)
    }
    
    /// Addpend value to `rawAudioData`
    let actualSampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
    let pointer = data.bindMemory(to: Int16.self, capacity: actualSampleCount)
    let buffer = UnsafeMutableBufferPointer(start: pointer, count: actualSampleCount)
    rawAudioData.append(contentsOf: buffer)
    
    /// Calculate respiratory rate when `rawAudioData` reached the number of sample 
    /// that worth 5 seconds (overlapping 2.5 seconds)
    let limit = Int(Self.samplesToCalculate)
    while rawAudioData.count > limit {
      let dataToProcess = Array(rawAudioData[0 ..< Int(Self.samplesToCalculate)])
      rawAudioData.removeFirst(limit / 2)
      
      /// Send the replacement to maintaince the time we start to calculate the respiratory rate
      /// So we send the nil value to temorary store in the collected data array and will replace that nil
      /// value when the data is calculated from `calculateRespiratoryRate(from:)`, which
      /// could cost up to 1 seconds as observed.
      DispatchQueue.main.async { [weak self] in
        self?.respiratoryRate.send(nil)
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.calculateRespiratoryRate(from: dataToProcess)
      }
    }
    
    /// The following code app passes the first `sampleCount`elements of raw audio data to the
    /// `processData(values:)` function, and removes the first `hopCount` elements from
    /// `rawBufferAudioData`.
    ///
    /// By removing fewer elements than each step processes, the rendered frames of data overlap,
    /// ensuring no loss of audio data.
    while rawBufferAudioData.count >= Self.samples {
      let dataToProcess = Array(rawBufferAudioData[0 ..< Self.samples])
      rawBufferAudioData.removeFirst(Self.hopCount)
      processData(values: dataToProcess)
    }
    
    // update the amplitude visual
    Task { @MainActor [unowned self] in
      let amplitude = timeDomainBuffer
        .reduce(0.0) { max($0, abs($1)) }
      
      let threshold: Float = 2000
      amplitudeSubject.send(amplitude > threshold ? threshold : amplitude)
    }
  }
}
