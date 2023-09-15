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
  
  /// Audio engine for recording
  private var audioEngine: AVAudioEngine?
  
  /// A dispatch queue to asynchronously perform analysis on.
  private let analysisQueue = DispatchQueue(label: "com.breathObserver.AnalysisQueue")
  
  /// An analyzer that performs sound classification.
  private var classifyAnalyzer: SNAudioStreamAnalyzer?
  
  private var soundAnalysisSubject: PassthroughSubject<SNClassificationResult, Error>?
  
  private var cancellables = Set<AnyCancellable>()
  
  private var observer: SNResultsObserving?
    
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

// MARK: - AudioSessionInteruptions
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
    stopProcess()
  }
}

// MARK: - SoundsAnalysis
extension BreathObsever {
  
  public typealias Config = (request: SNRequest, observer: SNResultsObserving)
  
  public func startProcess(config: Config) throws {
    stopProcess()
    
    do {
      try startAudioSession()
      try ensureMicrophoneAccess()
      
      let audioEngine = AVAudioEngine()
      self.audioEngine = audioEngine
      
      let audioFormat = audioEngine.inputNode.outputFormat(forBus: 0)
      
      let classifyAnalyzer = SNAudioStreamAnalyzer(format: audioFormat)
      self.classifyAnalyzer = classifyAnalyzer
      
      try classifyAnalyzer.add(config.request, withObserver: config.observer)
      observer = config.observer
      
      // start to record
      audioEngine
        .inputNode
        .installTap(onBus: 0, bufferSize: 4096, format: audioFormat) { [weak self] buffer, time in
          self?.analysisQueue.async {
            classifyAnalyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            
            // TODO: perform FFT here as well
          }
        }
      
      try audioEngine.start()
    } catch {
      stopProcess()
      throw error
    }
  }
  
  public func stopProcess() {
    autoreleasepool { [weak self] in
      guard let self else {
        return
      }
      
      audioEngine?.stop()
      audioEngine?.inputNode.removeTap(onBus: 0)
      
      classifyAnalyzer?.removeAllRequests()
      
      classifyAnalyzer = nil
      audioEngine = nil
      observer = nil
    }
    
    stopAudioSession()
  }
}
