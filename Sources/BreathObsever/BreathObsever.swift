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
  
  /// The sample rate (44,1 Khz is common): 24Khz on airpod pro
  let sampleRate = 24000.0 //44100.0
  
  /// The bandpass filter to remove noise that higher than 1000 Hz and lower than 10 Hz
  lazy var bandpassFilter = BandPassFilter(
    sampleRate: sampleRate,
    frequencyLow: 10,
    frequencyHigh: 1000
  )
  
  var session: AVCaptureSession?
  
  /// Audio engine for recording
  private var audioEngine: AVAudioEngine?
  
  /// audio sample buffer size
  let bufferSize: UInt32 = 1024
    
  static let amplitudeSamplesCapacity = 50
  
  ///Tthe samples of amplitude for 5 seconds
  /// Because we get the amplitude value in each 0.1 second (10Hz), so we need the array of size 10 * 5 = 50
  var amplitudeSamples: [Float] = {
    var array = [Float]()
    array.reserveCapacity(amplitudeSamplesCapacity)
    return array
  }()
  
  public override init() { }
  
  /// The subject that recieves the latest data of audio amplitude
  public var amplitudeSubject = PassthroughSubject<Float, Never>()
  
  /// The sujbect that recieves the latest data of audio power in decibel
  public var powerSubject = PassthroughSubject<Float, Never>()
  
  /// Amplitude threshold for loudest breathing noise that we accept. All higher noise will be counted as this.
  let threshold: Float = 0.08
  
}

// MARK: microphone check
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
}

// MARK: AudioSession
extension BreathObsever {
  
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
        
        // TODO: hmm, whatabout use the python script, seems all necessary step can do on python sciPy library
        
        Task { @MainActor [weak self] in
          
          guard let self else {
            return
          }
          
          let amplitude = amplitude(from: filteredBuffer ?? buffer)
          
          amplitudeSamples.append(amplitude)
          
          // calculate the respiratory rate after each 5 seconds
          if amplitudeSamples.count >= Self.amplitudeSamplesCapacity {
            
            calculateRespiratoryRate()
          }
          
          processAmplitude(from: filteredBuffer ?? buffer)
          
//          // TODO: maybe remove this?
//          sendAudioPower(from: filteredBuffer ?? buffer)
        }
      }
      
      try newEngine.start()
    } catch {
      stopAnalyzing()
      throw error
    }
  }
  
  public func stopAnalyzing() {
    stopAudioSession()
    
    autoreleasepool { [weak self] in
      guard let self else {
        return
      }
      
      audioEngine?.stop()
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine = nil

    }
  }
}

extension BreathObsever {
  
  @MainActor
  private func calculateRespiratoryRate() {
    guard
      !amplitudeSamples.isEmpty,
      amplitudeSamples.count == amplitudeSamples.capacity
    else {
      return
    }
        
    // find the PSD -> RR
    let psd = singleWindowWelchPeriodogram(of: amplitudeSamples)
    print(amplitudeSamples)
    print(psd)
    
    // TODO: send the respiratory rate (RR) value into a passthrough subject
    
    
    // clean the amplitude array for new cycle of observation and calculation
    amplitudeSamples = []
  }
}
