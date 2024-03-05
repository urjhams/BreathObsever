import Accelerate
import AVFoundation

extension BreathObsever {
  /// Applies a bandpass filter to an AVAudioPCMBuffer.
  ///
  /// - Parameters:
  ///   - inputBuffer: The input audio buffer to be filtered.
  ///   - filter: The bandpass filter parameters.
  /// - Returns: The filtered output audio buffer, or nil if an error occurs.
  func applyBandPassFilter(
    inputBuffer: AVAudioPCMBuffer,
    filter: BandPassFilter
  ) -> AVAudioPCMBuffer? {
    // Ensure input buffer has float channel data and create output buffer
    guard
      let inputFloatChannelData = inputBuffer.floatChannelData,
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputBuffer.format,
        frameCapacity: inputBuffer.frameLength
      )
    else {
      return nil
    }
    guard let outputFloatChannelData = outputBuffer.floatChannelData else {
      return nil
    }
    
    // Extract necessary properties from input buffer
    let channelCount = Int(inputBuffer.format.channelCount)
    let frameLength = Int(inputBuffer.frameLength)
    
    // Apply bandpass filter to each channel
    for channel in 0..<channelCount {
      let inputChannelData = inputFloatChannelData[channel]
      let outputChannelData = outputFloatChannelData[channel]
      
      // Initialize filter for current channel
      guard let biquad = vDSP.Biquad(
        coefficients: [filter.b0, filter.b1, filter.b2, filter.a1, filter.a2],
        channelCount: 1,
        sectionCount: 1,
        ofType: Float.self
      ) else {
        return nil
      }
      var filters = [vDSP.Biquad](repeating: biquad, count: 1)
      
      // Convert input samples to Float and apply the filter
      var signal = [Float](unsafeUninitializedCapacity: frameLength) { buffer, count in
        inputChannelData.withMemoryRebound(to: Float.self, capacity: frameLength) { ptr in
          for i in 0..<frameLength {
            buffer[i] = ptr[i] / 32767.0 // Normalize input samples to range [-1, 1]
          }
          count = frameLength
        }
      }
      
      signal = filters[0].apply(input: signal)
      
      // Scale filtered signal and store in output buffer
      for i in 0..<frameLength {
        let scaledValue = signal[i] * 32767.0 // Scale back to Int16 range
        outputChannelData[i] = max(-32767.0, min(32767.0, scaledValue)) // Clamp values to Int16 range
      }
    }
    
    // Set the frame length of the output buffer and return it
    outputBuffer.frameLength = inputBuffer.frameLength
    return outputBuffer
  }
}

extension BreathObsever {
  func applyHanningWindow(_ data: [Float]) -> [Float] {
    var windowedData = [Float](repeating: 0.0, count: data.count)
    vDSP_hann_window(&windowedData, vDSP_Length(data.count), Int32(vDSP_HANN_NORM))
    
    var output = [Float](repeating: 0.0, count: data.count)
    vDSP_vmul(windowedData, 1, data, 1, &output, 1, vDSP_Length(data.count))
    
    return output
  }
}

extension BreathObsever {
  // Function to perform Hilbert transform
  func hilbertTransform(inputSignal: [Float]) -> [Float]? {
    let bufferSize = inputSignal.count
    let log2n = UInt(round(log2(Double(bufferSize))))
    let bufferSizePOT = Int(1 << log2n)
    let length = bufferSizePOT / 2
    
    var splitComplex: DSPSplitComplex?
    
    // Prepare input signal for FFT
    var realBuffer = inputSignal
    var imagBuffer = [Float](repeating: 0, count: bufferSize)
    
    // Convert the signal into complex format
    realBuffer.withUnsafeMutableBufferPointer { realPointer in
      imagBuffer.withUnsafeMutableBufferPointer { imagPointer in
        guard
          let realBaseAddress = realPointer.baseAddress,
          let imagBaseAddress = imagPointer.baseAddress
        else {
          return
        }
        splitComplex = DSPSplitComplex(realp: realBaseAddress, imagp: imagBaseAddress)
      }
    }
    
    // Perform FFT
    guard
      var splitComplex,
      let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))
    else {
      return nil
    }

    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
    
    // Compute magnitude of the FFT result
    var magnitudes = [Float](repeating: 0.0, count: length)
    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(length))
    
    // Compute envelope
    var envelope = [Float](repeating: 0.0, count: bufferSize)
    vDSP_vsmul(magnitudes, 1, [2], &envelope, 1, vDSP_Length(length))
    vDSP_vdbcon(envelope, 1, [1], &envelope, 1, vDSP_Length(bufferSize), 0)
    
    // cleaning
    vDSP_destroy_fftsetup(fftSetup)
    
    return envelope
  }
  
  // Function to downsample signal to target sample rate
  func downsampleSignal(signal: [Float], originalSampleRate: Double, targetSampleRate: Double) -> [Float] {
    let downsampleFactor = Int(round(originalSampleRate / targetSampleRate))
    let downsampledLength = signal.count / downsampleFactor
    
    var downsampledSignal = [Float](repeating: 0.0, count: downsampledLength)
    
    // Downsample signal
    vDSP_desamp(
      signal, 
      vDSP_Stride(downsampleFactor),
      [Float](repeating: 0.0, count: downsampledLength),
      &downsampledSignal, vDSP_Length(downsampledLength),
      vDSP_Length(downsampleFactor)
    )
    
    return downsampledSignal
  }
  
  func findPeaks(signal: [Float]) -> [Int] {
    var peaks: [Int] = []
    
    for i in 1..<(signal.count - 1) {
      if signal[i] > signal[i-1] && signal[i] > signal[i+1] {
        peaks.append(i)
      }
    }
    
    return peaks
  }
  
  func calculateRespiratoryRate(peaks: [Int], sampleRate: Float) -> Float {
    var timeSum: Float = 0
    
    for i in 1..<peaks.count {
      let cycleDuration = Float(peaks[i] - peaks[i-1]) / sampleRate
      timeSum += cycleDuration
    }
    
    let averageCycleDuration = timeSum / Float(peaks.count - 1)
    let respiratoryRate = 60 / averageCycleDuration
    
    return respiratoryRate
  }
}

// MARK: - audio digital power recieved
extension BreathObsever {
  @MainActor
  internal func sendAudioPower(from buffer: AVAudioPCMBuffer) {
    let samples = UnsafeBufferPointer(
      start: buffer.floatChannelData?[0],
      count: Int(buffer.frameLength)
    )
    var power: Float = 0.0
    
    for sample in samples {
      power += sample * sample
    }
    
    power /= Float(samples.count)
    
    let powerInDB = 10.0 * log10(power)
    powerSubject.send(powerInDB)
  }
  
  @MainActor
  internal func processAmplitude(from buffer: AVAudioPCMBuffer) {

    let amplitude = amplitude(from: buffer)
    
    // Update the graph with the audio waveform
    amplitudeSubject.send(amplitude <= threshold ? amplitude : threshold)
  }
  
  @MainActor
  func amplitude(from buffer: AVAudioPCMBuffer) -> Float {
    // Extract audio samples from the buffer
    let bufferLength = UInt(buffer.frameLength)
    let audioBuffer = UnsafeBufferPointer(
      start: buffer.floatChannelData?[0],
      count: Int(bufferLength)
    )
    
    // Calculate the amplitude from the audio samples
    return audioBuffer.reduce(0.0) { max($0, abs($1)) }
  }
}
