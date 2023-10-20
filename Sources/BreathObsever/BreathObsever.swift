import AVFoundation
import SwiftUI
import Combine
import Accelerate

// TODO: remove SoundAnalysis, now record sound, try to get breath frequency, normalize -> spectrogram

public class BreathObsever: NSObject, ObservableObject {
  
  public enum ObserverError: Error {
    case noMicrophoneAccess
  }
  
  let sampleRate = 44100.0

  let audioSession: AVAudioSession
  
  /// Audio engine for recording
  private var audioEngine: AVAudioEngine?
          
  let bufferSize: UInt32 = 4096
    
  internal lazy var fftAnalyzer = FFTAnlyzer(bufferSize: bufferSize)
  
//  public var fftAnalysisSubject = PassthroughSubject<FFTAnlyzer.FFTResult, Never>()
  public var fftAnalysisSubject = PassthroughSubject<[Float], Never>()
  
  public var powerSubject = PassthroughSubject<Float, Never>()
  
  public override init() {
    audioSession = AVAudioSession.sharedInstance()
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
      try? self?.audioSession.setActive(false)
    }
  }
  
  private func startAudioSession() throws {
    stopAudioSession()
    do {
      try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
      try audioSession.setPreferredSampleRate(sampleRate)
      try audioSession.setActive(true)
    } catch {
      stopAudioSession()
      throw error
    }
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
  internal func sendFFTResult(_ result: [Float]) {
    fftAnalysisSubject.send(result)
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
      ) { buffer, time in
        Task { [weak self] in
                              
//          if let fftResult = self?.fftAnalyzer.performFFT(buffer: buffer) {
//            await self?.sendFFTResult(fftResult)
//          }
          
          if let fftMagnitudes = self?.fftAnalyzer.performFFT(buffer) {
            await self?.sendFFTResult(fftMagnitudes)
          }
          
          // calculate and send power power
          await self?.sendAudioPower(from: buffer)
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
