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
  
  public var fftAnalysisSubject = PassthroughSubject<FFTAnlyzer.FFTResult, Never>()
  
  public var powerSubject = PassthroughSubject<Float, Never>()
  
  // TODO: need another subject to save ECG data
  // may be we keep collecting ECG data and save to an array,
  // when the the combineLatest receiveValue, we collect the data in array and empty it
  // prepare the handle of the data
  
  /// Indicates the amount of audio, in seconds, that informs a prediction.
  var inferenceWindowSize = Double(1.5)
  
  /// The amount of overlap between consecutive analysis windows.
  ///
  /// The system performs sound classification on a window-by-window basis. The system divides an
  /// audio stream into windows, and assigns labels and confidence values. This value determines how
  /// much two consecutive windows overlap. For example, 0.9 means that each window shares 90% of
  /// the audio that the previous window uses.
  var overlapFactor = Double(0.9)
      
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
  internal func sendFFTResult(_ result: FFTAnlyzer.FFTResult) {
    fftAnalysisSubject.send(result)
  }
}
