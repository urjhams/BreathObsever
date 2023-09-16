import AVFAudio
import SoundAnalysis
import Combine
import Accelerate

public enum Breathing {
  case breath(confidence: Double)
  case none
  
  init(from result: SNClassificationResult) {
    guard
      let breath = result.classification(forIdentifier: "breathing"),
      breath.confidence > 0.7 // 70 % confidence
    else {
      self = .none
      return
    }
    self = .breath(confidence: breath.confidence)
  }
}


public class BreathObsever: NSObject, ObservableObject {
  
  public enum ObserverError: Error {
    case recorderNotAllocated
    case notRecording
    case noTimerAllocated
    case noAvailableInput
    case noMicrophoneAccess
    case audioStreamInterrupted
  }
  
  let sampleRate = 44100.0

  let audioSession = AVAudioSession.sharedInstance()
  
  /// Audio engine for recording
  private let audioEngine = AVAudioEngine()
  
  /// A dispatch queue to asynchronously perform analysis on.
  private let analysisQueue = DispatchQueue(label: "com.breathObserver.AnalysisQueue")
  
  /// An analyzer that performs sound classification.
  private var classifyAnalyzer: SNAudioStreamAnalyzer?
  
  private var soundAnalysisSubject = PassthroughSubject<Breathing, Never>()
  
  private var soundAnalysisTempResult = [SNClassificationResult]()
  
  private var cancellables = Set<AnyCancellable>()
    
  let bufferSize: UInt32 = 4096
    
  internal lazy var fftAnalyzer = FFTAnlyzer(bufferSize: bufferSize)
  
  private var fftAnalysisSubject = PassthroughSubject<FFTAnlyzer.FFTResult, Never>()
  
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
    
  }
  
  deinit {
    cancellables.removeAll()
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
      try audioSession.setPreferredSampleRate(sampleRate)
      
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
    stopProcess()
  }
}

// MARK: - SoundsAnalysis
extension BreathObsever {
  
  public typealias Config = (request: SNRequest, observer: SNResultsObserving)
  
  public func startAnalyzing(request: SNRequest) throws {
    stopAnalyzing()
    
    do {
      try startAudioSession()
      try ensureMicrophoneAccess()
      
      let audioFormat = audioEngine.inputNode.outputFormat(forBus: 0)
      
      let classifyAnalyzer = SNAudioStreamAnalyzer(format: audioFormat)
      self.classifyAnalyzer = classifyAnalyzer
      
      try classifyAnalyzer.add(request, withObserver: self)
      
      // start to record
      audioEngine
        .inputNode
        .installTap(onBus: 0, bufferSize: bufferSize, format: audioFormat) { [weak self] buffer, time in
          self?.analysisQueue.async {
            classifyAnalyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            
            if let fftResult = self?.fftAnalyzer.performFFT(buffer: buffer) {
              print("🙆🏻 send fft subject result")
              self?.fftAnalysisSubject.send(fftResult)
            }
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
      
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      
      classifyAnalyzer?.removeAllRequests()
      
      classifyAnalyzer = nil
    }
    
    stopAudioSession()
  }
  
  public func startProcess() {
    stopProcess()
    
    // TODO: need another subject to save ECG data
    // may be we keep collecting ECG data and save to an array,
    // when the the combineLatest receiveValue, we collect the data in array and empty it
    // prepare the handle of the data
    Publishers
      .CombineLatest(soundAnalysisSubject, fftAnalysisSubject)
      .receive(on: DispatchQueue.main)
      .sink { _ in
        
      } receiveValue: { classifyResult, fftResult in
        // TODO: handle the combine value of sound classfy result and fft result
        DispatchQueue.main.async {
          print("🎉 result: \nclassify: \(classifyResult)\nfft: \(fftResult)")
        }
      }
      .store(in: &cancellables)
    
    // setup the sound analysis request
    do {
      let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
      request.windowDuration = CMTimeMakeWithSeconds(
        inferenceWindowSize,
        preferredTimescale: 48_000
      )
      request.overlapFactor = overlapFactor
      
      startListeningForAudioSessionInterruptions()
      try startAnalyzing(request: request)
    } catch {
      stopProcess()
    }
  }
  
  public func stopProcess() {
    stopAnalyzing()
    stopListeningForAudioSessionInterruptions()
  }
}


extension BreathObsever: SNResultsObserving {
  public func request(_ request: SNRequest, didProduce result: SNResult) {
    guard let result = result as? SNClassificationResult else {
      return
    }
    print("🙆🏻 send sound analysis subject result")
    soundAnalysisSubject.send(Breathing(from: result))
  }
  
  public func requestDidComplete(_ request: SNRequest) {
    // we can ignore this since we use a Never passthrough subject
    soundAnalysisSubject.send(completion: .finished)
  }
}
