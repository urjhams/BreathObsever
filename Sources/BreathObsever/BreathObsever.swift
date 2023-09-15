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
  
  private var soundAnalysisSubject = PassthroughSubject<SNClassificationResult, Error>()
  
  private var cancellables = Set<AnyCancellable>()
  
  private var observer: SNResultsObserving?
    
  internal var fftAnalyzer = FFTAnlyzer()
  
  private var fftAnalysisSubject = PassthroughSubject<[Float], Error>()
  
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
    // TODO: send the failure to FFT subject as well
    stopProcess()
  }
}

// MARK: - SoundsAnalysis
extension BreathObsever {
  
  public typealias Config = (request: SNRequest, observer: SNResultsObserving)
  
  public func startAnalyzing(config: Config) throws {
    stopAnalyzing()
    
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
            // TODO: the fft result saved in another passthrough subject
            // TODO: use the Publisher.CombineLastest() of that subject and the sound analyze subject
          }
        }
      
      try audioEngine.start()
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
      
      classifyAnalyzer?.removeAllRequests()
      
      classifyAnalyzer = nil
      audioEngine = nil
      observer = nil
    }
    
    stopAudioSession()
  }
  
  public func startProcess() {
    stopProcess()
    
    // TODO: need another subject to save ECG data
    // may be we keep collecting ECG data and save to an array,
    // when the the combineLatest receiveValue, we collect the data in array and empty it
    Publishers
      .CombineLatest(soundAnalysisSubject, fftAnalysisSubject)
      .receive(on: DispatchQueue.main)
      .sink { _ in
        
      } receiveValue: { result in
        // TODO: handle the combine value of sound classfy result and fft result
      }

    
    do {
      
    } catch {
      
    }
  }
  
  public func stopProcess() {
    stopAnalyzing()
    stopListeningForAudioSessionInterruptions()
  }
}

