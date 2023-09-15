import AVFAudio
import SoundAnalysis
import Combine
import Accelerate

public class BreathObsever: ObservableObject {
  
  public enum ObserverError: Error {
    case recorderNotAllocated
    case notRecording
    case noTimerAllocated
    case noAvailableInput
    case noMicrophoneAccess
    case audioStreamInterrupted
  }

  let audioSession = AVAudioSession.sharedInstance()
  
  private var recorder: AVAudioRecorder?
  
  private let analysisQueue = DispatchQueue(label: "com.quan.BreathObserver.AnalysisQueue")
  
  private var audioEngine: AVAudioEngine?
  
  private var soundAnalysisSubject: PassthroughSubject<SNClassificationResult, Error>?
  
  private var cancellables = Set<AnyCancellable>()
  
  internal var fftAnalyzer = FFTAnlyzer()
  
  @Published
  public var digitalPowerLevel: Double = 0
  
  @Published
  public var convertedPowerLevel: Int = 0
      
  public init() {
    
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
      typealias Options = AVAudioSession.CategoryOptions
      let options: Options = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
      try audioSession.setCategory(.record, mode: .measurement, options: options)
      
      let allowedPorts: [AVAudioSession.Port] = [
        .bluetoothLE,
        .bluetoothHFP,
        .airPlay,
        .bluetoothA2DP
      ]
      guard
        let inputs = audioSession.availableInputs,
        let _ = inputs.first(where: { description in allowedPorts.contains(description.portType) })
      else {
        throw ObserverError.noAvailableInput
      }
      
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      stopAudioSession()
      throw error
    }
  }
}

// MARK: - Sounds classification
extension BreathObsever {
  /// Starts observing for audio recording interruptions.
  private func startListeningForAudioSessionInterruptions() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.mediaServicesWereLostNotification,
      object: nil
    )
  }
  
  /// Stops observing for audio recording interruptions.
  private func stopListeningForAudioSessionInterruptions() {
    NotificationCenter
      .default
      .removeObserver(self, name: AVAudioSession.interruptionNotification,object: nil)
    NotificationCenter
      .default
      .removeObserver(self, name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
  }
  
  /// Handles notifications the system emits for audio interruptions.
  ///
  /// When an interruption occurs, the app notifies the subject of an error. The method terminates sound
  /// classification, so restart it to resume classification.
  ///
  /// - Parameter notification: A notification the system emits that indicates an interruption.
  @objc
  private func handleAudioSessionInterruption(_ notification: Notification) {
    let error = ObserverError.audioStreamInterrupted
    soundAnalysisSubject?.send(completion: .failure(error))
//    stopSoundClassification()
  }
}



// MARK: - track audio
extension BreathObsever {
  
  ///  Record audio signal and return the represent value as decibel
  public func trackAudioSignal() throws {
    guard let recorder else {
      throw ObserverError.recorderNotAllocated
    }
    
    guard recorder.isRecording else {
      throw ObserverError.notRecording
    }
    
    recorder.updateMeters()
    
        
    // range from -160 dBFS to 0 dBFS
    let power = recorder.averagePower(forChannel: 0)
    
    let threshold: Float = -90
    
    // cut off any sounds below -90 dBFS to reduce background noise
    guard power > threshold else {
      return
    }
    
    fftAnalyzer.appendAndAnalyze(
      audioPower: power,
      time: 441000 // `cycle` seconds at `sampeRate` Hz
    )
    
    fftAnalyzer.analyzeCurrentDataSet()
    
    // -- convert to 0-10000 scale and show in real time graph
    // Convert dB value to linear scale
    digitalPowerLevel = Double(power)
    
    let convtered = convertAudioSignal(power)
    
    // this converted power level is used for real time data
    convertedPowerLevel = convtered
    
  }
  
  /// The peakPower(forChannel:) function in AVFoundation returns the peak power of an
  /// audio signal in decibels (dB), which is not a 0-100000 scale.
  /// To convert the result to a 0-100000 scale, you can first convert the decibel value to a linear
  /// scale and then map it to the desired range.
  ///
  /// Use 100000 scale for a more accurate power with low noise, since we working with breathing sounds
  private func convertAudioSignal(_ value: Float) -> Int {
    Int(pow(10, value / 20) * 100000)
  }
}

// MARK: - toggle
extension BreathObsever {
  public func startTrackAudioSignal() {
    recorder?.record()
  }
  public func stopTrackAudioSignal() {
    recorder?.stop()
  }
}
