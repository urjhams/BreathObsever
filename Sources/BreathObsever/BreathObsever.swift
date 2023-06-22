import AVFoundation
import Combine

public class BreathObsever: ObservableObject {
  
  public enum ObserverError: Error {
    case recorderNotAllocated
    case notRecording
  }

  let session = AVAudioSession.sharedInstance()
  
  /// timer
  let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
  
  var cancellables = Set<AnyCancellable>()
  
  /// A flag that indicate that currentlly recording
  @Published
  public var isTracking = false {
    didSet {
      isTracking ? startTrackAudioSignal() : stopTrackAudioSignal()
    }
  }
  
  /// A flag that indicate if the setupAudioRecorder() has run successfully
  @Published
  public var successfullySetupRecord = false
  
  public var recorder: AVAudioRecorder?
  
  @Published
  public var digitalPowerLevel: Double = 0
  
  @Published
  public var convertedPowerLevel: Int = 0
  
  // TODO: now we need a model to store the powerlevel array's peaks (up and down)
  // then use them to indicate cognitive load level
  
  public init() {
    
    // setup audio recorder, if failed, the recorder will be nil
    try? setupAudioRecorder()
    
    setupTimer()
  }
}

// MARK: - setup
extension BreathObsever {
  
  private func setupTimer() {
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
    recorder?.prepareToRecord()
    recorder?.isMeteringEnabled = true
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
  /// audio signal in decibels (dB), which is not a 0-1000 scale.
  /// To convert the result to a 0-1000 scale, you can first convert the decibel value to a linear
  /// scale and then map it to the desired range.
  private func convertAudioSignal(_ value: Float) -> Int {
    Int(pow(10, value / 20) * 1000)
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
