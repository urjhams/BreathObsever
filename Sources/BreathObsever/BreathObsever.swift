import AVFoundation
import Combine

public class BreathObsever: ObservableObject {
  
  public enum ObserverError: Error {
    case recorderNotAllocated
    case notRecording
    case noTimerAllocated
  }

  let session = AVAudioSession()
  
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
  
  private var recorder: AVAudioRecorder?
  
  @Published
  public var digitalPowerLevel: Double = 0
  
  @Published
  public var convertedPowerLevel: Int = 0
  
  // TODO: now we need a model to store the powerlevel array's peaks (up and down)
  // then use them to indicate cognitive load level
  
  // TODO: the model will have a timer(?) to track the density of the peaks in an amount of time
  // -> the breathing pattern is fast or slow -> cognitive load/ calmness level(?)
  
  var audioBuffer: [Float] = []
  let sampleRate = 44100
  lazy var bufferSize = Int(10 * (1 / cycle)) // 10 seconds
//  let fftBufferSize = 1024  // size for FFT analysis
  
//  let threshold: Float = 0.02
  
  var analyzeTimer: Timer?
  
  public init(cycle: TimeInterval) {
    self.cycle = cycle
    // setup audio recorder, if failed, the recorder will be nil
    // try? setupAudioRecorder()
  }
}

// MARK: - setup
extension BreathObsever {
  
  public func assignTimer(timer: AnyPublisher<Date, Never>) throws {
    self.timer = timer
    try setupTimer()
    hasTimer = true
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
  
  public func setupAudioRecorder() throws {
    
    defer {
      successfullySetupRecord = true
    }
    
    // record if from phone's mic, playAndRecord if in AirPods
    //try AVInstance.setCategory(.record)
    try session.setCategory(
      .playAndRecord,             // should use playAndRecord instead just Record
      mode: .measurement,
      options: [
        // Allow the use of Bluetooth devices
        .allowBluetooth,
        .allowBluetoothA2DP,
        .allowAirPlay
      ]
    )
    
    guard let availableInputs = session.availableInputs else {
      return
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
    
    let channel = 0
    
    // range from -160 dBFS to 0 dBFS
    let power = recorder.averagePower(forChannel: channel)
    
    // Convert dB value to linear scale
    digitalPowerLevel = Double(power)
    
    let convtered = convertAudioSignal(power)
    
    // this converted power level is used for real time data
    convertedPowerLevel = convtered
    
    // append the data to the buffer to normalizing
    updateAudioBuffer(with: [Float(convtered)])
    
  }
  
  private func updateAudioBuffer(with data: [Float]) {
    audioBuffer.append(contentsOf: data)
    if audioBuffer.count > bufferSize {
      audioBuffer.removeFirst(audioBuffer.count - bufferSize)
    }
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
    analyzeTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [weak self] _ in
      guard self?.isTracking ?? false else {
        return
      }
      self?.performFFTAnalysis()
    })
  }
  public func stopTrackAudioSignal() {
    recorder?.stop()
    analyzeTimer?.invalidate()
    analyzeTimer = nil
  }
}

import Accelerate

extension BreathObsever {
  
  func performFFTAnalysis() {
    guard audioBuffer.count >= bufferSize else {
      return
    }
        
    // perform FFT analysis
    var realPart = audioBuffer
    var imaginaryPart = [Float](repeating: 0, count: bufferSize)
    realPart.withUnsafeMutableBufferPointer { realPointee in
      imaginaryPart.withUnsafeMutableBufferPointer { imaginaryPointee in
        
        guard
          let real = realPointee.baseAddress,
          let imaginary = imaginaryPointee.baseAddress
        else {
          return
        }
        
        var splitComplex = DSPSplitComplex(realp: real, imagp: imaginary)
        
        let log2n = vDSP_Length(log2(Float(bufferSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
          return
        }
        
        vDSP_fft_zip(setup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_destroy_fftsetup(setup)
        
        // Calculate magnitude values
        var magnitude: [Float] = .init(repeating: 0.0, count: bufferSize)
        vDSP_zvmags(&splitComplex, 1, &magnitude, 1, vDSP_Length(bufferSize))
        
        // normalize FFT values
        let normalizedValues = normalizeFFTValues(magnitude)
        
      }
    }
  }
  
  func normalizeFFTValues(_ values: [Float]) -> [Int] {
    let max = values.max() ?? 1.0
    // linear normalization between 0 and 10000
    return values.map { Int(($0 / max) * 10000) }
  }
  
}
