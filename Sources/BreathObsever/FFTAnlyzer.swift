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

// MARK: - FFT result
extension FFTAnlyzer {
  public typealias FFTResult = (real: [Float], imaginary: [Float])
  
  public func performFFT(buffer: AVAudioPCMBuffer) -> FFTResult? {

    let bufferSize = Int(buffer.frameLength)
    let length = bufferSize / 2
    
    var realBuffer      = [Float](repeating: 0.0, count: length)
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
        splitComplex = DSPSplitComplex(realp: realOutAddress, imagp: imagOutAddress)
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

  public func performFFT(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    let bufferSize = buffer.frameLength
    let log2n = UInt(round(log2(Double(bufferSize))))
    let bufferSizePOT = Int(1 << log2n)
    let length = bufferSizePOT / 2
    let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))
    
    var realBuffer = [Float](repeating: 0, count: length)
    var imaginaryBuffer = [Float](repeating: 0, count: length)
        
    var splitComplex: DSPSplitComplex?
    //wrap the result inside a complex vector representation used in the vDSP framework
    realBuffer.withUnsafeMutableBufferPointer { realPointer in
      imaginaryBuffer.withUnsafeMutableBufferPointer { imagPointer in
        guard let real = realPointer.baseAddress, let imag = imagPointer.baseAddress else {
          return
        }
        splitComplex = DSPSplitComplex(realp: real, imagp: imag)
      }
    }
    
    guard var splitComplex, let floatBuffer = buffer.floatChannelData else {
      return nil
    }
    
    let windowSize = bufferSizePOT
    var transferBuffer = [Float](repeating: 0, count: windowSize)
    var window = [Float](repeating: 0, count: windowSize)
    
    // Hann windowing to reduce the frequency leakage
    vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
    vDSP_vmul(floatBuffer.pointee, 1, window, 1, &transferBuffer, 1, vDSP_Length(windowSize))
    
    // Transforming the [Float] buffer into a UnsafePointer<Float> object for the vDSP_ctoz method
    // And then pack the input into the complex buffer (output)
    withUnsafePointer(to: transferBuffer) { pointer in
      pointer.withMemoryRebound(to: DSPComplex.self, capacity: transferBuffer.count) {
        vDSP_ctoz($0, 2, &splitComplex, 1, vDSP_Length(length))
      }
    }
    
    // Perform the FFT
    vDSP_fft_zrip(fftSetup!, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
    
    var magnitudes = [Float](repeating: 0.0, count: length)
    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(length))
    
    // Normalizing
    magnitudes = normalizedData(from: &magnitudes, length: length)
    
    vDSP_destroy_fftsetup(fftSetup)
    
    return magnitudes
  }
}

// MARK: - Peaks (fftSetup = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD) in setupFFT() instead)
extension FFTAnlyzer {
  
  internal func normalizedData(from magnitudes: inout [Float], length: Int) -> [Float] {
    var normalizedMagnitudes = [Float](repeating: 0.0, count: length)
    vDSP_vsmul(
      magnitudes.map { sqrtf($0) }, 1, [2.0 / Float(length)],
      &normalizedMagnitudes, 1, vDSP_Length(length)
    )
    
    return magnitudes
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
