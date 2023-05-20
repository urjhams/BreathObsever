import AVFoundation
import Combine

class BreathObsever: ObservableObject {

  let session = AVAudioSession.sharedInstance()
  let threshold: Int
  
  var recorder: AVAudioRecorder?
  
  @Published var isBreathing = false
  
  @Published var breathingUnit = 0
  
  init(threshold: Int = -55) throws {
    self.threshold = threshold
    try setupAudioRecorder()
  }
  
  func setupAudioRecorder() throws {
    // record if from phone's mic, playAndRecord if in AirPods
    //try AVInstance.setCategory(.record)
    try session.setCategory(
      .playAndRecord,
      options: [.allowBluetooth, .allowBluetoothA2DP]
    )
    
    guard let availableInputs = session.availableInputs else {
      return
    }
    
    if let _ = availableInputs.first(where: { description in
      // bluetooth hand free profile - like AirPods
      return description.portType == .bluetoothLE
    }) {
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
    recorder?.record()
  }
  
  ///  Record audio signal and return the represent value as decibel
  public func trackAudioSignal() {
    guard let recorder else {
      return
    }
    recorder.updateMeters()
    
    // Uses a weighted average of the average power and
    // peak power for the time period.
    
    // range from -160 dBFS to 0 dBFS
    let average = convertAudioSignal(recorder.averagePower(forChannel: 0))
    
    // range from -160 dBFS to 0 dBFS
    let peak = convertAudioSignal(recorder.peakPower(forChannel: 0))
    
    let combinedPower = average + peak
    
    // TODO: change the threshold
    isBreathing = (combinedPower > threshold)
    print("combine: \(combinedPower), breathing: \(isBreathing)")
    breathingUnit = combinedPower
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
