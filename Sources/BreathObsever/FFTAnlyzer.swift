import Accelerate
import AVFAudio

public class FFTAnlyzer: NSObject {
  var fftSetup: vDSP_DFT_Setup?
  var bufferSize: UInt32 = 1024
  
  private override init() {
    super.init()
  }
  
  public convenience init(bufferSize: UInt32) {
    self.init()
    self.bufferSize = bufferSize
  }
  
}

extension FFTAnlyzer {
  public typealias FFTResult = (real: [Float], imaginary: [Float])
  
  public func performFFT(buffer: AVAudioPCMBuffer) -> FFTResult? {

    let bufferSize = Int(buffer.frameLength)
    let length = bufferSize / 2
    
    var realBuffer = [Float](repeating: 0.0, count: length)
    var imaginaryBuffer = [Float](repeating: 0.0, count: length)
    
    var splitComplex: DSPSplitComplex?
    //wrap the result inside a complex vector representation used in the vDSP framework
    realBuffer.withUnsafeMutableBufferPointer { real in
      imaginaryBuffer.withUnsafeMutableBufferPointer { imaginary in
        guard
          let realOutAddress = real.baseAddress,
          let imagOutAddress = imaginary.baseAddress
        else {
          return
        }
        splitComplex = .init(realp: realOutAddress, imagp: imagOutAddress)
      }
    }
    
    guard var splitComplex, let floatBuffer = buffer.floatChannelData else {
      return nil
    }
    
    // Convert the audio buffer to a float array
    var audioBuffer = Array(UnsafeBufferPointer(start: floatBuffer[0], count: bufferSize))
    
    let fftLength = vDSP_Length(floor(log2(Float(length))))
    guard let fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2)) else {
      return nil
    }
    
    
    // perform the FFT
    audioBuffer.withUnsafeMutableBufferPointer { bufferPointer in
      vDSP_fft_zip(fftSetup, &splitComplex, 1, fftLength, FFTDirection(FFT_FORWARD))
    }
    // clean
    vDSP_destroy_fftsetup(fftSetup)
    
    // extract the result
    let realPart = splitComplex.realp
    let real = Array(UnsafeBufferPointer(start: realPart, count: length))
    let imaginaryPart = splitComplex.imagp
    let imaginary = Array(UnsafeBufferPointer(start: imaginaryPart, count: length))
    
    return (real, imaginary)
  }
}

// MARK: - FFT Analyze setup
extension FFTAnlyzer {
  
  internal func setupFFT() -> vDSP_DFT_Setup? {
    let length = vDSP_Length(bufferSize)
    return vDSP_create_fftsetup(length, Int32(kFFTRadix2))
  }
  
  internal func cleanFFTSetup(_ fftSetup: FFTSetup) {
    vDSP_destroy_fftsetup(fftSetup)
  }
}

// MARK: - Peaks (fftSetup = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD) in setupFFT() instead)
extension FFTAnlyzer {
  
  internal func normalizeData(_ data: [Float]) -> [Float] {
    var normalizedData = data
    let dataSize = vDSP_Length(data.count)
    
    normalizedData.withUnsafeMutableBufferPointer { buffer in
      vDSP_vsmul(buffer.baseAddress!, 1, [2.0 / Float(dataSize)], buffer.baseAddress!, 1, dataSize)
    }
    
    return normalizedData
  }
  
  func analyzePeaks(_ data: [Float], fftSetup: vDSP_DFT_Setup) {
    
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
