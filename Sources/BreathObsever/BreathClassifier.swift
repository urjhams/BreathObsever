import Foundation
import AVFoundation
import SoundAnalysis
import Combine

public final class BreathClassifier: NSObject {
  
  enum AudioClassificationError: Error {
    case audioStreamInterrupted
    case noMicrophoneAccess
  }
  
  /// A dispatch queue to asynchronously perform sound analysis on.
  internal let analysisQueue = DispatchQueue(label: "com.quan.BreathMeasuring.SoundAnalysisQueue")
  
  /// An audio engine the app uses to record system input.
  internal var audioEngine: AVAudioEngine?
  
  /// An analyzer that performs sound classification.
  private var analyzer: SNAudioStreamAnalyzer?
  
  private var retainedObserver: SNResultsObserving?
  
  /// A subject to deliver sound classification results to, including an error, if necessary.
  private var subject: PassthroughSubject<SNClassificationResult, Error>?
  
  private override init() {}
  
  static let shared = BreathClassifier()
}

public extension BreathClassifier {
  func startBreathClassification(
    subject: PassthroughSubject<SNClassificationResult, Error>,
    inferenceWindowSize: Double,
    overlapFactor: Double
  ) {
    stopSoundClassification()
    
    do {
      let observer = ClassificationResultsSubject(subject: subject)
      
      let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
      request.windowDuration = CMTimeMakeWithSeconds(inferenceWindowSize, preferredTimescale: 48_000)
      request.overlapFactor = overlapFactor
      
      self.subject = subject
      
      startListeningForAudioSessionInterruptions()
      try startAnalyzing((request, observer))
    } catch {
      subject.send(completion: .failure(error))
      self.subject = nil
      stopSoundClassification()
    }
  }
}

public extension BreathClassifier {
  
  typealias Broadcasting = (request: SNRequest, observer: SNResultsObserving)
  
  internal func startAnalyzing(_ boardcasting: Broadcasting) throws {
    stopAnalyzing()
    
    do {
      try startAudioSession()
      try ensureMicrophoneAccess()
      
      let engine = AVAudioEngine()
      audioEngine = engine
      
      let bus = AVAudioNodeBus(0)
      let size = AVAudioFrameCount(4096)
      let format = engine.inputNode.outputFormat(forBus: bus)
      
      analyzer = SNAudioStreamAnalyzer(format: format)
      
      try analyzer?.add(boardcasting.request, withObserver: boardcasting.observer)
      
      retainedObserver = boardcasting.observer
      
      engine.inputNode.installTap(
        onBus: bus,
        bufferSize: size,
        format: format
      ) { [weak self] buffer, time in
        self?.analysisQueue.async {
          self?.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
      }
      
      try engine.start()
    } catch {
      stopAnalyzing()
      throw error
    }
  }
  
  internal func stopAnalyzing() {
    autoreleasepool { [weak self] in
      if let audioEngine = self?.audioEngine {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
      }
      
      if let analyzer = self?.analyzer {
        analyzer.removeAllRequests()
      }
      
      self?.analyzer = nil
      self?.retainedObserver = nil
      self?.audioEngine = nil
    }
    
    stopAudioSession()
  }
  
  /// Stops any active sound classification task.
  func stopSoundClassification() {
    stopAnalyzing()
    stopListeningForAudioSessionInterruptions()
  }
}

public extension BreathClassifier {
  /// Requests permission to access microphone input, throwing an error if the user denies access.
  internal func ensureMicrophoneAccess() throws {
    var hasMicrophoneAccess = false
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
      let semephore = DispatchSemaphore(value: 0)
      AVCaptureDevice.requestAccess(for: .audio) { success in
        hasMicrophoneAccess = success
        semephore.signal()
      }
      _ = semephore.wait(timeout: DispatchTime.distantFuture)
    case .denied, .restricted:
      break
    case .authorized:
      hasMicrophoneAccess = true
    @unknown default:
      fatalError("unknown authorization status for microphone access")
    }
    
    if !hasMicrophoneAccess {
      throw AudioClassificationError.noMicrophoneAccess
    }
  }
  
  /// Deactivates the app's AVAudioSession.
  internal func stopAudioSession() {
    autoreleasepool {
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(false)
    }
  }
  
  internal func startAudioSession() throws {
    stopAudioSession()
    do {
      let session = AVAudioSession.sharedInstance()
      
      typealias Options = AVAudioSession.CategoryOptions
      let options: Options = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
      try session.setCategory(.record,  mode: .measurement, options: [options])
      
      try session.setActive(true)
    } catch {
      stopAudioSession()
      throw error
    }
  }
  
  /// Starts observing for audio recording interruptions.
  internal func startListeningForAudioSessionInterruptions() {
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
    NotificationCenter.default.removeObserver(
      self,
      name: AVAudioSession.interruptionNotification,
      object: nil)
    NotificationCenter.default.removeObserver(
      self,
      name: AVAudioSession.mediaServicesWereLostNotification,
      object: nil)
  }
  
  @objc
  private func handleAudioSessionInterruption(_ notification: Notification) {
    let error = AudioClassificationError.audioStreamInterrupted
    subject?.send(completion: .failure(error))
    stopSoundClassification()
  }
}
