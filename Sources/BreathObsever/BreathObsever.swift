import AVFoundation
import Combine

public class BreathObsever: ObservableObject {
  
  public enum ObserverError: Error {
    case recorderNotAllocated
    case notRecording
    case noTimerAllocated
  }

  let session = AVAudioSession.sharedInstance()
  
  //TODO: might need to switch between .default and .measurement to see if also use the environment mic, how it is
  /// The mode category.
  ///
  /// We should use `measurement` mode to use only the primary microphone (The airpod pro has 2 mics, one primary for voice),
  /// one for noise cancellation which will record the environment sounds so it could affect the accuration of output data we desired.
  private var mode: AVAudioSession.Mode = .measurement
  
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
  
  public var hasTimer = false
  
  /// A flag that indicate if the setupAudioRecorder() has run successfully
  @Published
  public var successfullySetupRecord = false
  
  private var recorder: AVAudioRecorder?
  
  @Published
  public var digitalPowerLevel: Double = 0
  
  @Published
  public var convertedPowerLevel: Int = 0
  
  // TODO: now we need a model to store the powerlevel array's peaks (up and down)
  // then use them to indicate cognitive load level
  
  // TODO: the model will have a timer(?) to track the density of the peaks in an amount of time
  // -> the breathing pattern is fast or slow -> cognitive load/ calmness level(?)
  
  public init() {
        
    // setup audio recorder, if failed, the recorder will be nil
    try? setupAudioRecorder()
    
    try? setupTimer()
  }
}

// MARK: - setup
extension BreathObsever {
  
  public func assignTimer(timer: AnyPublisher<Date, Never>) throws {
    self.timer = timer
    hasTimer = true
    try setupTimer()
  }
  
  private func setupTimer() throws {
    guard let timer else {
      throw ObserverError.noTimerAllocated
    }
    timer
      .sink { [unowned self] _ in
        guard self.isTracking else {
          return
        }
        try? self.trackAudioSignal()
      }
      .store(in: &cancellables)
  }
  
  private func setupAudioRecorder() throws {
    
    defer {
      successfullySetupRecord = true
    }
    
    // record if from phone's mic, playAndRecord if in AirPods
    //try AVInstance.setCategory(.record)
    try session.setCategory(
      .record,
      mode: mode,
      options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
    )
    
    guard let availableInputs = session.availableInputs else {
      return
    }
    
    let availableBluetoothLE = availableInputs.first(where: { description in
      // bluetooth hand free profile, BLE - like AirPods
      [.bluetoothLE, .bluetoothHFP, .airPlay].contains(description.portType)
    })
    
    if availableBluetoothLE != nil  {
      try audioRecordWithAirPod()
    }
  }
  
  private func audioRecordWithAirPod() throws {
    try session.setActive(true, options: .notifyOthersOnDeactivation)
    
    let filePaths = NSTemporaryDirectory()
    let url = URL(fileURLWithPath: filePaths).appendingPathComponent("tempRecord")
    
    var settings = [String: Any]()
    // 192 kHz is the highest commonly used sample rate
    settings[AVSampleRateKey] = 192000.0
    settings[AVFormatIDKey] = Int(kAudioFormatAppleLossless)
    settings[AVNumberOfChannelsKey] = 1
    settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
    
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
    
    // Uses a weighted average of the average power and
    // peak power for the time period.
        
    let channel = 0
    
    // range from -160 dBFS to 0 dBFS
    let power = recorder.averagePower(forChannel: channel)
    
    digitalPowerLevel = Double(power)
    
    convertedPowerLevel = convertAudioSignal(power)
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
