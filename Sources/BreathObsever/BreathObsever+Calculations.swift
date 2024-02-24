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
  // Function to perform Hilbert transform
  func hilbertTransform(inputSignal: [Float]) -> [Float]? {
    let bufferSize = inputSignal.count
    let log2n = UInt(round(log2(Double(bufferSize))))
    let bufferSizePOT = Int(1 << log2n)
    let length = bufferSizePOT / 2
    
    var splitComplex: DSPSplitComplex
    var signalComplex = [DSPComplex](repeating: DSPComplex(), count: length)
    
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
    let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))

    vDSP_fft_zrip(fftSetup!, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
    
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
  
  // Function to apply Welch method and estimate respiratory rate
  func welchMethod(signal: [Float], originalSampleRate: Double) -> Double {
    let windowSize = vDSP_Length(signal.count)
    
    // Apply Hanning window
    var window = [Float](repeating: 0.0, count: Int(windowSize))
    vDSP_hann_window(&window, windowSize, Int32(vDSP_HANN_NORM))
    
    // Apply window to signal
    var windowedSignal = [Float](repeating: 0.0, count: signal.count)
    vDSP_vmul(signal, 1, window, 1, &windowedSignal, 1, windowSize)
    
    // Calculate power spectral density
    var powerSpectralDensity = [Float](repeating: 0.0, count: signal.count / 2)
    let powerSpectralDensityLength = vDSP_Length(signal.count / 2)
    vDSP_fftqrv(windowedSignal, 1, &powerSpectralDensity, 1, powerSpectralDensityLength)
    
    // Estimate respiratory rate
    let maxIndex = vDSP_Length(powerSpectralDensity.firstIndex(of: powerSpectralDensity.max()!)!)
    let respiratoryRate = Double(maxIndex) * (originalSampleRate / Double(windowSize))
    
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
    // Extract audio samples from the buffer
    let bufferLength = UInt(buffer.frameLength)
    let audioBuffer = UnsafeBufferPointer(
      start: buffer.floatChannelData?[0],
      count: Int(bufferLength)
    )
    
    // Calculate the amplitude from the audio samples
    let amplitude = audioBuffer.reduce(0.0) { max($0, abs($1)) }
    
    // Update the graph with the audio waveform
    amplitudeSubject.send(amplitude <= threshold ? amplitude : threshold)
  }
}
