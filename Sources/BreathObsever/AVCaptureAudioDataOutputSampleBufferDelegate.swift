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
    
    /// Because the audio spectrogram code requires exactly `sampleCount` (which the app defines
    /// as 512) samples, but audio sample buffers from AVFoundation may not always contain exactly
    /// 512 samples, the app adds the contents of each audio sample buffer to `rawBufferAudioData`.
    ///
    /// The following code creates an array from `data` and appends it to  `rawBufferAudioData`:
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
    
    /// Calculate respiratory rate when `rawAudioData` reached the number of sample that worth 5 seconds (overlapping 2.5 seconds)
    let limit = Int(Self.samplesToCalculate)
    while rawAudioData.count > limit {
      let dataToProcess = Array(rawAudioData[0 ..< Int(Self.samplesToCalculate)])
      rawAudioData.removeFirst(limit / 2)
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
      let amplitude = vDSP.rootMeanSquare(timeDomainBuffer)
      
      amplitudeLoopCounter += 1
      if 1 ... accumulatedAmplitudes.count ~= amplitudeLoopCounter {
        switch amplitudeLoopCounter {
        case accumulatedAmplitudes.count - 1:
          // reset the coutner
          amplitudeLoopCounter = 0
        default:
          // set the amplitude at coressponding index in the container
          let indexToChange = amplitudeLoopCounter - 1
          accumulatedAmplitudes[indexToChange] = amplitude
        }
      }
      
      let threshold: Float = 2000
      amplitudeSubject.send(amplitude > threshold ? threshold : amplitude)
    }
  }
}
