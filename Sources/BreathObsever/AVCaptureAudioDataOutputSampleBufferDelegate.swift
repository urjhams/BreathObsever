import AVFoundation

extension BreathObsever: AVCaptureAudioDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
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
    
    /// Because the audio spectrogram code requires exactly `sampleCount` (which the app defines
    /// as 512) samples, but audio sample buffers from AVFoundation may not always contain exactly
    /// 512 samples, the app adds the contents of each audio sample buffer to `rawAudioData`.
    ///
    /// The following code creates an array from `data` and appends it to  `rawAudioData`:
    if rawAudioData.count < Self.samples * 2 {
      let actualSampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
      let pointer = data.bindMemory(to: Int16.self, capacity: actualSampleCount)
      let buffer = UnsafeMutableBufferPointer(start: pointer, count: actualSampleCount)
      
      rawAudioData.append(contentsOf: buffer)
    }
    
    /// The following code app passes the first `sampleCount`elements of raw audio data to the
    /// `processData(values:)` function, and removes the first `hopCount` elements from
    /// `rawAudioData`.
    ///
    /// By removing fewer elements than each step processes, the rendered frames of data overlap,
    /// ensuring no loss of audio data.
    while rawAudioData.count >= Self.samples {
      let dataToProcess = Array(rawAudioData[0 ..< Self.samples])
      rawAudioData.removeFirst(Self.hopCount)
      processData(values: dataToProcess)
    }
    
    DispatchQueue.main.async { [unowned self] in
      let amplitude = timeDomainBuffer.reduce(0.0) { max($0, abs($1)) }
//      // the envelopAmplitude is the uper envelop so we get the
//      let envelopAmplitude = timeDomainBuffer.reduce(0.0) { max($0, $1) }
      let threshold: Float = 2000
      amplitudeSubject.send(amplitude > threshold ? threshold : amplitude)
    }
  }
}
