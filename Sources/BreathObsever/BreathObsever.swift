import AVFoundation
import SwiftUI
import Combine
import Accelerate

public class BreathObsever: NSObject, ObservableObject {
  
  public enum ObserverError: Error {
    case noMicrophoneAccess
    case noCaptureDevice
    case cannotAddInput
    case cannotAddOutput
  }
  
  let sampleRate = 44100.0
  
  // The bandpass filter to remove noise that higher than 1000 Hz and lower than 10 Hz
  lazy var bandpassFilter = BandPassFilter(
    sampleRate: sampleRate,
    frequencyLow: 10,
    frequencyHigh: 1000
  )

  var session: AVCaptureSession?
  
  /// Audio engine for recording
  private var audioEngine: AVAudioEngine?
          
  let bufferSize: UInt32 = 1024
  
  public var amplitudeSubject = PassthroughSubject<Float, Never>()
  
  public var powerSubject = PassthroughSubject<Float, Never>()
  
  /// Amplitude threshold for loudest breathing noise that we accept. All higher noise will be counted as this.
  let threshold: Float = 0.08
  
  public override init() {
  }
}

// MARK: AudioSession
extension BreathObsever {
  private func ensureMicrophoneAccess() throws {
    var hasMicrophoneAccess = false
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
      let sem = DispatchSemaphore(value: 0)
      AVCaptureDevice.requestAccess(for: .audio) { success in
        hasMicrophoneAccess = success
        sem.signal()
      }
      _ = sem.wait(timeout: DispatchTime.distantFuture)
    case .denied, .restricted:
      break
    case .authorized:
      hasMicrophoneAccess = true
    @unknown default:
      fatalError("unknown authorization status for microphone access")
    }
    
    if !hasMicrophoneAccess {
      throw ObserverError.noMicrophoneAccess
    }
  }
  
  private func stopAudioSession() {
    autoreleasepool { [weak self] in
      self?.session?.stopRunning()
    }
  }
  
  private func startAudioSession() throws {
    stopAudioSession()
    let audioSettings: [String : Any] = [
      AVFormatIDKey           : kAudioFormatLinearPCM,
      AVNumberOfChannelsKey   : 1,
      AVSampleRateKey         : sampleRate
    ]
    let queue = DispatchQueue(label: "AudioSessionQueue")
    let microphone: AVCaptureDevice?
    if #available(macOS 14.0, *) {
      microphone = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)
    } else {
      // Fallback on earlier versions
      microphone = AVCaptureDevice.default(for: .audio)
    }
    guard let microphone else {
      throw ObserverError.noCaptureDevice
    }
    
    do {
      try ensureMicrophoneAccess()
      session = AVCaptureSession()
      
      let input = try AVCaptureDeviceInput(device: microphone)
      let output = AVCaptureAudioDataOutput()
      
      output.setSampleBufferDelegate(self, queue: queue)
      output.audioSettings = audioSettings
      session?.beginConfiguration()
      try addInput(session, input: input)
      try addOutput(session, output: output)
      session?.commitConfiguration()
      session?.startRunning()
    } catch {
      stopAudioSession()
      throw error
    }
  }
  
  private func addInput(_ session: AVCaptureSession?, input: AVCaptureDeviceInput) throws {
    guard let session, session.canAddInput(input) else {
      throw ObserverError.cannotAddInput
    }
    session.addInput(input)
  }
  
  private func addOutput(_ session: AVCaptureSession?, output: AVCaptureAudioDataOutput) throws {
    guard let session, session.canAddOutput(output) else {
      throw ObserverError.cannotAddOutput
    }
    session.addOutput(output)
  }
}

extension BreathObsever: AVCaptureAudioDataOutputSampleBufferDelegate {
  
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

extension BreathObsever {
  public func startAnalyzing() throws {
    stopAnalyzing()
    
    do {
      try startAudioSession()
      try ensureMicrophoneAccess()
      
      // start the engine
      // IMPORTARNT!!! must start the new engine here right before installTap
      // to prevent error:
      // reason: 'required condition is false: format.sampleRate == hwFormat.sampleRate.
      let newEngine = AVAudioEngine()
      audioEngine = newEngine
      
      let audioFormat = newEngine.inputNode.inputFormat(forBus: 0)
      
      // start to record
      newEngine.inputNode.installTap(
        onBus: 0,
        bufferSize: bufferSize,
        format: audioFormat
      ) { [weak self] buffer, time in
        
        guard let self else {
          return
        }
        
        let filteredBuffer = applyBandPassFilter(inputBuffer: buffer, filter: bandpassFilter)
        
        Task { [weak self] in
          
          await self?.processAmplitude(from: filteredBuffer ?? buffer)
          
          // calculate and send power power
          await self?.sendAudioPower(from: filteredBuffer ?? buffer)
        }
      }
      
      try newEngine.start()
    } catch {
      stopAnalyzing()
      throw error
    }
  }
  
  public func stopAnalyzing() {
    autoreleasepool { [weak self] in
      guard let self else {
        return
      }
      
      audioEngine?.stop()
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine = nil

    }
    
    stopAudioSession()
  }
}

fileprivate extension BreathObsever {
  func applyBandPassFilter(
    inputBuffer: AVAudioPCMBuffer,
    filter: BandPassFilter
  ) -> AVAudioPCMBuffer? {
    guard
      let inputInt16ChannelData = inputBuffer.int16ChannelData,
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputBuffer.format,
        frameCapacity: inputBuffer.frameLength
      ) 
    else {
      return nil
    }
    
    guard let outputInt16ChannelData = outputBuffer.int16ChannelData else {
      return nil
    }
    
    guard let biquad = vDSP.Biquad(
      coefficients: [filter.b0, filter.b1, filter.b2, filter.a1, filter.a2],
      channelCount: 1,
      sectionCount: 1,
      ofType: Float.self
    ) else {
      return nil
    }
    var filters = [vDSP.Biquad](repeating: biquad, count: 1)
    
    for channel in 0..<Int(inputBuffer.format.channelCount) {
      let p1: UnsafeMutablePointer<Int16> = inputInt16ChannelData[channel]
      let p2: UnsafeMutablePointer<Int16> = outputInt16ChannelData[channel]
      
      var signal = [Float](repeating: 0.0, count: Int(inputBuffer.frameLength))
      
      for i in 0..<Int(inputBuffer.frameLength) {
        signal[i] = Float(p1[i]) / 32767.0
      }
      
      signal = filters[0].apply(input: signal)
      
      for i in 0..<Int(inputBuffer.frameLength) {
        if signal[i] < -1.0 {
          p2[i] = -32767
        } else if signal[i] > 1.0 {
          p2[i] = 32767
        } else {
          p2[i] = Int16(Int(signal[i] * 32767))
        }
      }
    }
    
    outputBuffer.frameLength = inputBuffer.frameLength
    return outputBuffer
  }
}
