import AVFAudio
import SwiftUI
import SoundAnalysis
import Combine
import Accelerate

// TODO: remove SoundAnalysis, now record sound, try to get breath frequency, normalize -> spectrogram
public enum Breathing {
  case breath(confidence: Double)
  case none
  
  init(from result: SNClassificationResult) {
    guard
      let breath = result.classification(forIdentifier: "breathing"),
      breath.confidence > 0.0
    else {
      self = .none
      return
    }
    self = .breath(confidence: breath.confidence)
  }
  
  public var confidence: Int {
    switch self {
    case .breath(let value):
      return Int(value * 100)
    default:
      return 0
    }
  }
}


public class BreathObsever: NSObject, ObservableObject {
  
  public enum ObserverError: Error {
    case noMicrophoneAccess
  }
  
  let sampleRate = 44100.0

  let audioSession: AVAudioSession
  
  /// Audio engine for recording
  private var audioEngine: AVAudioEngine?
  
  /// An analyzer that performs sound classification.
  private var classifyAnalyzer: SNAudioStreamAnalyzer?
  
  public var soundAnalysisSubject = PassthroughSubject<Breathing, Never>()
  
  private var soundAnalysisTempResult = [SNClassificationResult]()
      
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

// MARK: - SoundsAnalysis
extension BreathObsever {
    
  public func startAnalyzing(request: SNRequest) throws {
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
      
      let audioFormat = newEngine.inputNode.outputFormat(forBus: 0)
      
      classifyAnalyzer = SNAudioStreamAnalyzer(format: audioFormat)
      
      try classifyAnalyzer?.add(request, withObserver: self)
      
      // start to record
      newEngine
        .inputNode
        .installTap(onBus: 0, bufferSize: bufferSize, format: audioFormat) { buffer, time in
          Task { [weak self] in
            self?.classifyAnalyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
            
            if let fftResult = self?.fftAnalyzer.performFFT(buffer: buffer) {
              await self?.sendFFTResult(fftResult)
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
      
      classifyAnalyzer?.removeAllRequests()
      classifyAnalyzer = nil
    }
    
    stopAudioSession()
  }
  
  public func startProcess() throws {
    stopProcess()
    
    // setup the sound analysis request
    do {
      let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
      request.windowDuration = CMTimeMakeWithSeconds(
        inferenceWindowSize,
        preferredTimescale: 48_000
      )
      request.overlapFactor = overlapFactor
      
      try startAnalyzing(request: request)
    } catch {
      print("❗️ \(error.localizedDescription)")
      stopProcess()
      throw error
    }
  }
  
  public func stopProcess() {
    stopAnalyzing()
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

// MARK: - SNResultsObserving
extension BreathObsever: SNResultsObserving {
  public func request(_ request: SNRequest, didProduce result: SNResult) {
    guard let result = result as? SNClassificationResult else {
      return
    }
    Task { @MainActor in
      soundAnalysisSubject.send(Breathing(from: result))
    }
  }
}
