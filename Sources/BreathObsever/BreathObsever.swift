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
  
  var audioBuffer: [Float] = []
  var normalizedData: [Float] = []
  
  var fftSetup: vDSP_DFT_Setup?
  
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
    
    setupFFT()
  }
  
  deinit {
    // free memory of the fftSetup as it is used in low level memory.
    if let fftSetup {
      vDSP_DFT_DestroySetup(fftSetup)
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
    
    // add value to buffer
    audioBuffer.append(power)
    
    if audioBuffer.count >= Int(sampleRate * cycle) { // `cycle` seconds at `sampeRate` Hz
      normalizedData = normalizeData(audioBuffer)
      analyzePeaks(normalizedData)
      audioBuffer.removeFirst(441)  // remove the oldest 0.01 seconds of Data at sample rate 44100
    }
    
    guard cycleCounter <= Int(endTime) else {
      normalizedData = normalizeData(audioBuffer)
      analyzePeaks(normalizedData)
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

// MARK: - FFT Analyze
extension BreathObsever {
  
  private func setupFFT() {
    let length = vDSP_Length(1024)
    fftSetup = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD)
  }
  
  private func normalizeData(_ data: [Float]) -> [Float] {
    var normalizedData = data
    let dataSize = vDSP_Length(data.count)
    
    normalizedData.withUnsafeMutableBufferPointer { buffer in
      vDSP_vsmul(buffer.baseAddress!, 1, [2.0 / Float(dataSize)], buffer.baseAddress!, 1, dataSize)
    }
    
    return normalizedData
  }
  
  func analyzePeaks(_ data: [Float]) {
    guard let fftSetup else {
      return
    }
    
    var realIn = [Float](repeating: 0, count: data.count)
    var imagIn = [Float](repeating: 0, count: data.count)
    var realOut = [Float](repeating: 0, count: data.count)
    var imagOut = [Float](repeating: 0, count: data.count)
    
    //fill in real input part with audio samples
    for i in 0..<data.count {
      realIn[i] = data[i]
    }
    
    // perform fft
    vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)
    
    var complex: DSPSplitComplex?
    //wrap the result inside a complex vector representation used in the vDSP framework
    realOut.withUnsafeMutableBufferPointer { real in
      imagOut.withUnsafeMutableBufferPointer { imaginary in
        guard
          let realOutAddress = real.baseAddress,
          let imagOutAddress = imaginary.baseAddress
        else {
          return
        }
        complex = .init(realp: realOutAddress, imagp: imagOutAddress)
      }
    }
    
    guard var complex else {
      return
    }
    
    // create and store the result in magnitudes array
    var magnitudes = [Float](repeating: 0, count: data.count)
    vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(data.count))
    
    // Find local maxima in the magnitudes array
    var peaks: [(index: Int, magnitude: Float)] = []
    for index in 1..<(magnitudes.count - 1) {
      if magnitudes[index] > magnitudes[index - 1] && magnitudes[index] > magnitudes[index + 1] {
        peaks.append((index: index, magnitude: magnitudes[index]))
      }
    }
    
    // Calculate distances between consecutive peaks
    var peakDistances: [Int] = []
    for index in 1..<peaks.count {
      let distance = peaks[index].index - peaks[index - 1].index
      peakDistances.append(distance)
    }
    
    print("Detected Peaks: \(peaks)")
    print("Peak Distances: \(peakDistances)")
  }
}
