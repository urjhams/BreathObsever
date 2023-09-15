import AVFAudio
import Combine
import Accelerate

public class BreathObsever: ObservableObject {
  
  public enum ObserverError: Error {
    case recorderNotAllocated
    case notRecording
    case noTimerAllocated
    case noAvailableInput
  }

  let session = AVAudioSession()
  
  private var recorder: AVAudioRecorder?
    
  /// time of one update cycle
  let cycle: TimeInterval
  
  /// timer
  var timer: AnyPublisher<Date, Never>?
  
  private var cancellables = Set<AnyCancellable>()
  
  /// A flag that indicate that currentlly recording
  @Published
  public var isTracking = false {
    didSet {
      isTracking ? startTrackAudioSignal() : stopTrackAudioSignal()
    }
  }
  
  internal var fftAnalyzer = FFTAnlyzer()
  
  /// A flag that indicate if the timer is successfully created
  @Published
  public var hasTimer = false
  
  /// A flag that indicate if the setupAudioRecorder() has run successfully
  @Published
  public var successfullySetupRecord = false
  
  @Published
  public var digitalPowerLevel: Double = 0
  
  @Published
  public var convertedPowerLevel: Int = 0
  
  /// State to know is the session successfully set up and available
  @Published
  public var sessionAvailable = false
  
  public var endTime: TimeInterval
  
  private var cycleCounter = 0
  
  // TODO: need a model to store the powerlevel array's peaks (up and down)
  // then use them to indicate cognitive load level
  
  let sampleRate = 44100.0
    
  public init(cycle: TimeInterval, end: TimeInterval) {
    self.cycle = cycle
    self.endTime = end
    
    do {
      try setupAudioRecorder()
      sessionAvailable = true
    } catch {
      sessionAvailable = false
    }

  }
}

// MARK: - setup
extension BreathObsever {
  
  public func assignTimer(timer: AnyPublisher<Date, Never>) throws {
    self.timer = timer
    try setupTimer()
    hasTimer = true
  }
  
  public func deallocateTimer() {
    cancellables.removeAll()
  }
  
  private func setupTimer() throws {
    guard let timer else {
      throw ObserverError.noTimerAllocated
    }
    timer.sink { [weak self] _ in
      guard let tracking = self?.isTracking, tracking else {
        return
      }
      try? self?.trackAudioSignal()
    }
    .store(in: &cancellables)
  }
  
  public func setupAudioRecorder() throws {
    
    defer {
      successfullySetupRecord = true
    }
    
    // record if from phone's mic, playAndRecord if in AirPods
    //try AVInstance.setCategory(.record)
    typealias Options = AVAudioSession.CategoryOptions
    let options: Options = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
    try session.setCategory(.playAndRecord,  mode: .measurement, options: [options])
    
    guard let availableInputs = session.availableInputs else {
      throw ObserverError.noAvailableInput
    }
        
    let availableBluetoothLE = availableInputs.first { description in
      // bluetooth hand free profile, BLE - like AirPods
      [.bluetoothLE, .bluetoothHFP, .airPlay, .bluetoothA2DP].contains(description.portType)
    }
    
    if let _ = availableBluetoothLE  {
      try sessionAndRecorderConfig()
    }
  }
  
  private func sessionAndRecorderConfig() throws {
    try session.setActive(true, options: .notifyOthersOnDeactivation)
    
    let filePaths = NSTemporaryDirectory()
    let url = URL(fileURLWithPath: filePaths).appendingPathComponent("tempRecord")
    
    let settings: [String: Any] = [
      // 192 kHz is the highest commonly used sample rate
      AVSampleRateKey:          sampleRate,
      AVFormatIDKey:            Int(kAudioFormatAppleLossless),
      AVNumberOfChannelsKey:    1,
      AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
    ]
    
    try recorder = AVAudioRecorder(url: url, settings: settings)
    
    guard let recorder else {
      throw ObserverError.recorderNotAllocated
    }
    recorder.prepareToRecord()
    recorder.isMeteringEnabled = true
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
    
    cycleCounter += 1
        
    // range from -160 dBFS to 0 dBFS
    let power = recorder.averagePower(forChannel: 0)
    
    let threshold: Float = -90
    
    // cut off any sounds below -90 dBFS to reduce background noise
    guard power > threshold else {
      return
    }
    
    fftAnalyzer.appendAndAnalyze(
      audioPower: power,
      time: Int(sampleRate * cycle) // `cycle` seconds at `sampeRate` Hz
    )
    
    guard cycleCounter <= Int(endTime) else {
      fftAnalyzer.analyzeCurrentDataSet()
      //TODO: stop the timer, end the session
      //TODO: need empty the data when start a new tracking
      return
    }
    
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
