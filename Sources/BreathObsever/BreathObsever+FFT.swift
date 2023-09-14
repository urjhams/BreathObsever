import Accelerate

// MARK: - FFT Analyze
extension BreathObsever {
  
  internal func setupFFT() {
    let length = vDSP_Length(1024)
    fftSetup = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD)
  }
  
  internal func normalizeData(_ data: [Float]) -> [Float] {
    var normalizedData = data
    let dataSize = vDSP_Length(data.count)
    
    normalizedData.withUnsafeMutableBufferPointer { buffer in
      vDSP_vsmul(buffer.baseAddress!, 1, [2.0 / Float(dataSize)], buffer.baseAddress!, 1, dataSize)
    }
    
    return normalizedData
  }
  
  func analyzePeaks(_ data: [Float]) {
    guard let fftSetup else {
      return
    }
    
    var realIn = [Float](repeating: 0, count: data.count)
    var imagIn = [Float](repeating: 0, count: data.count)
    var realOut = [Float](repeating: 0, count: data.count)
    var imagOut = [Float](repeating: 0, count: data.count)
    
    //fill in real input part with audio samples
    for i in 0..<data.count {
      realIn[i] = data[i]
    }
    
    // perform fft
    vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)
    
    var complex: DSPSplitComplex?
    //wrap the result inside a complex vector representation used in the vDSP framework
    realOut.withUnsafeMutableBufferPointer { real in
      imagOut.withUnsafeMutableBufferPointer { imaginary in
        guard
          let realOutAddress = real.baseAddress,
          let imagOutAddress = imaginary.baseAddress
        else {
          return
        }
        complex = .init(realp: realOutAddress, imagp: imagOutAddress)
      }
    }
    
    guard var complex else {
      return
    }
    
    // create and store the result in magnitudes array
    var magnitudes = [Float](repeating: 0, count: data.count)
    vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(data.count))
    
    // Find local maxima in the magnitudes array
    var peaks: [(index: Int, magnitude: Float)] = []
    for index in 1..<(magnitudes.count - 1) {
      if magnitudes[index] > magnitudes[index - 1] && magnitudes[index] > magnitudes[index + 1] {
        peaks.append((index: index, magnitude: magnitudes[index]))
      }
    }
    
    // Calculate distances between consecutive peaks
    var peakDistances: [Int] = []
    for index in 1..<peaks.count {
      let distance = peaks[index].index - peaks[index - 1].index
      peakDistances.append(distance)
    }
    
    print("Detected Peaks: \(peaks)")
    print("Peak Distances: \(peakDistances)")
  }
}
