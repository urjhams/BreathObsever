import AVFoundation
import Combine

public class BreathObsever: ObservableObject {

  let session = AVAudioSession.sharedInstance()
  
  let threshold: Int
  
  public var recorder: AVAudioRecorder?
  
  // TODO: maybe we remove this?
  @Published var isBreathing = false
  
  @Published public var breathingUnit = 0
  
  // TODO: temporary use default threshold as -55
  public init(threshold: Int = -55) {
    self.threshold = threshold
    
    // setup audio recorder, if failed, the recorder will be nil
    try? setupAudioRecorder()
  }
}

// MARK: - setup
extension BreathObsever {
  public func setupAudioRecorder() throws {
    // record if from phone's mic, playAndRecord if in AirPods
    //try AVInstance.setCategory(.record)
    try session.setCategory(.playAndRecord, options: [.allowBluetooth, .allowBluetoothA2DP])
    
    guard let availableInputs = session.availableInputs else {
      return
    }
    
    let availableBluetoothLE = availableInputs.first(where: { description in
      // bluetooth hand free profile, BLE - like AirPods
      return [.bluetoothLE, .bluetoothHFP].contains(description.portType)
    })
    
    if availableBluetoothLE != nil  {
      try audioRecordWithAirPod()
    }
    
    // note: in the future if we use the 3rd party headphones,
    // use switch input.portType instead
    // and find out which one is `.bluetoothLE`
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
  @discardableResult
  public func trackAudioSignal() -> Int {
    guard let recorder, recorder.isRecording else {
      return -1
    }
    
    recorder.updateMeters()
    
    // Uses a weighted average of the average power and
    // peak power for the time period.
    
    let channel = 0
    
    // range from -160 dBFS to 0 dBFS
    let average = convertAudioSignal(recorder.averagePower(forChannel: channel))
    
    // range from -160 dBFS to 0 dBFS
    let peak = convertAudioSignal(recorder.peakPower(forChannel: channel))
    
    let combinedPower = average + peak
    
    // TODO: change the threshold
    // TODO: do we need some kind of validation to set threshold?
    // like tell the user to breath normal, silent, and heavy
    // then we get the threshold
    // May be also use voice recogniztion to decide is user speaking or not
    // so it is an exception
    
    // assign the breathing indicator
    isBreathing = (combinedPower > threshold)
    
    print("combine: \(combinedPower), breathing: \(isBreathing)")
    
    // assign the breathing unit publisher
    breathingUnit = combinedPower
    
    return combinedPower
  }
  
  /// The peakPower(forChannel:) function in AVFoundation returns the peak power of an
  /// audio signal in decibels (dB), which is not a 0-1000 scale.
  /// To convert the result to a 0-100 scale, you can first convert the decibel value to a linear
  /// scale and then map it to the desired range.
  private func convertAudioSignal(_ value: Float) -> Int {
    let linearValue = pow(10, value / 20)
    return Int(linearValue * 1000)
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
