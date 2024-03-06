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
  
  // Get Power Spectral Density
  func singleWindowWelchPeriodogram(of data: [Float]) -> [Float] {
    let windowSize = data.count
    let overlap = 0  // No overlap since we're using a single window
    
    var psd = [Float](repeating: 0.0, count: windowSize / 2)
    
    // Apply Hanning window to the entire data array
    var windowedData = applyHanningWindow(data)
    
    // Perform FFT on the entire windowed data
    var realParts = [Float](repeating: 0, count: windowSize)
    var imagParts = [Float](repeating: 0, count: windowSize)
    
    realParts.withUnsafeMutableBufferPointer { realPtr in
      imagParts.withUnsafeMutableBufferPointer { imagPtr in
        
        var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
        
        data.withUnsafeBytes {
          vDSP.convert(
            interleavedComplexVector: [DSPComplex]($0.bindMemory(to: DSPComplex.self)),
            toSplitComplexVector: &splitComplex
          )
        }
        
        let log2n = vDSP_Length(log2(Float(windowSize * 2)))
        let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        
        fft?.forward(input: splitComplex, output: &splitComplex)
        
        // Compute power spectrum
        var power = [Float](repeating: 0.0, count: windowSize / 2)
        vDSP_zvmags(&splitComplex, 1, &power, 1, vDSP_Length(windowSize / 2))
        
        // Accumulate power for PSD
        for i in 0..<psd.count {
          psd[i] += power[i]
        }
        
        // Scale the PSD
        let scalingFactor = 1.0 / Float(windowSize)
        for i in 0..<psd.count {
          psd[i] *= scalingFactor
        }
      }
    }
        
    return psd
  }
  
  // TODO: find the peak as the respiratory rate
  
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
