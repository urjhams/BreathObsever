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
  public static let sampleRate = 24000.0 //44100.0
  
  /// The number of sample per frame  (must be power of 2)
  public static let samples = 512
  
  /// use for overlaping (should be halp of the samples)
  public static let hopCount = 256
  
  /// The flag that indcate the data is collecting
  public private(set) var collectingData = false
    
  /// The window sequence for normalizing
  let hanningWindow = vDSP.window(
    ofType: Float.self,
    usingSequence: .hanningNormalized,
    count: samples,
    isHalfWindow: false
  )
  
  static let samplesToCalculate = sampleRate * 10
  
  /// A buffer that contains the raw audio data from AVFoundation that used to calculate the respiratory rate
  var rawAudioData = [Int16]()
  
  /// A buffer that contains the raw audio data from AVFoundation that used to present the amplitude
  var rawBufferAudioData = [Int16]()
  
  /// A reusable array that contains the current frame of time-domain audio data as single-precision
  /// values.
  var timeDomainBuffer = [Float](repeating: 0, count: samples)
  
  /// 512 samples with 24000 hz -> there are approximately 47 frames in the looping each 1 second
  static let amplitudesPerSec = 47
  
  var amplitudeLoopCounter = 0
  /// The container that store the amplitudes value of each frame until we filled enough for 5 seconds data
  /// to calculate the respiratory rate.
  var accumulatedAmplitudes = [Float](repeating: 0, count: amplitudesPerSec * 5)
  
  /*
   The main parts of the capture architecture are sessions, inputs, and outputs:
   Capture sessions connect one or more inputs to one or more outputs. Inputs are sources of media,
   including capture devices like the cameras and microphones built into an iOS device or Mac.
   Outputs acquire media from inputs to produce useful data, such as movie files written to disk
   or raw pixel buffers available for live processing.
  */
  var session: AVCaptureSession?
  
  /// Audio engine for recording
  private var audioEngine: AVAudioEngine?
  
  let audioOutput = AVCaptureAudioDataOutput()
  
  let captureQueue = DispatchQueue(
    label: "captureQueue",
    qos: .userInitiated,
    attributes: [],
    autoreleaseFrequency: .workItem
  )
  
  let sessionQueue = DispatchQueue(
    label: "sessionQueue",
    attributes: [],
    autoreleaseFrequency: .workItem
  )
  
  public static let windowTime = 5
  
  /// samples limit at the point where we reach this limit, we apply the respiratory rate calculation
  /// (each 5 seconds)
  public static let samplesLimit = sampleRate * Double(windowTime)
  
  public override init() { 
    super.init()
    configureAudioEngine()
    configureCaptureSession()
    audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
  }
  
  deinit {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil
    session = nil
  }
  
  /// The subject that recieves the latest data of audio amplitude
  public var amplitudeSubject = PassthroughSubject<Float, Never>()
  
  /// The sujbect that recieves the latest data of audio power in decibel
  public var powerSubject = PassthroughSubject<Float, Never>()
  
  /// The subject that recieves the latest data of calculated respiratory rate
  public var respiratoryRate = CurrentValueSubject<Float, Error>(0.0)
  
}

extension BreathObsever {
  func processData(values: [Int16]) {
    // convert the buffer data to the timeDomainBuffer
    vDSP.convertElements(of: values, to: &timeDomainBuffer)
    
    // apply Hanning window to smoothing the data
    vDSP.multiply(timeDomainBuffer, hanningWindow, result: &timeDomainBuffer)
  }
}

extension BreathObsever {
  func calculateRespiratoryRate(from data: [Int16]) {
    
    guard let scriptPath = Bundle.module.path(forResource: "rr", ofType: "py") else {
      return
    }
    
    let parameter = data.map { String($0) }.joined(separator: ",")
    
    let command = "python3 \(scriptPath) \(parameter)"
    
    let process = Process()
    // progress configuration
    process.arguments = ["-c", command]
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    
    let outputPipe = Pipe()
    
    process.standardOutput = outputPipe
    do {
      try process.run()
      if let outputData = try outputPipe.fileHandleForReading.readToEnd() {
        
        let output = String(decoding: outputData, as: UTF8.self)
          .replacingOccurrences(of: "\n", with: "")
        
        DispatchQueue.main.async {
          // TODO: put this into current value of respiratory rate
          // TODO: at the time of call this function, send a nil value to passthrough subject, temporary put that into dataStorage array. When the actual output returned, send that value to passthrough subject again. So when revieved, if the value not nil and there is the nil value stand at the last of the array in dataStorage, replace it with that non-nil value. Otherwise, just append as normal
          // TODO: check the doc of the lowest and highest RR so set the output inside that boundary only.
          print(output)
        }
      }
    } catch {
      print(error.localizedDescription)
    }
  }
}

extension BreathObsever {
  
  private func configureAudioEngine() {
    let newEngine = AVAudioEngine()
    audioEngine = newEngine
  }
  
  private func configureCaptureSession() {
    session = AVCaptureSession()
    
    // bandpass filter at 500 to 5000 Hz
    let bandpassFilter = AVAudioUnitEQ(numberOfBands: 1)
    let topFrequency: Float = 5000 // in Hz
    let bottomFrequency: Float = 500  // in Hz
    let centerFrequency = (topFrequency + bottomFrequency) / 2
    let bandWidth = centerFrequency / (topFrequency - bottomFrequency)
    bandpassFilter.bands[0].filterType = .bandPass
    bandpassFilter.bands[0].bandwidth = bandWidth
    bandpassFilter.bands[0].frequency = centerFrequency
    bandpassFilter.bands[0].bypass = false
    audioEngine?.attach(bandpassFilter)
    
    // Connect audio engine nodes
    if let audioNode = audioEngine?.inputNode {
      let format = audioNode.outputFormat(forBus: 0)
      audioEngine?.connect(audioNode, to: bandpassFilter, format: format)
    }
    
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      break
    case .notDetermined:
      sessionQueue.suspend()
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        if !granted {
          fatalError("App requires microphone access.")
        } else {
          self.configureCaptureSession()
          self.sessionQueue.resume()
        }
      }
      return
    default:
      // Users can add authorization by choosing Settings > Privacy >
      // Microphone on an iOS device, or System Preferences >
      // Security & Privacy > Microphone on a macOS device.
      fatalError("App requires microphone access.")
    }
    
    guard let session else {
      fatalError("cannot allocate capture session")
    }
    
    session.beginConfiguration()
    #if os(macOS)
    audioOutput.audioSettings = [
      AVSampleRateKey: Self.sampleRate, // 24 Khz is the sample rate of Apple's airpod
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMBitDepthKey: 16,
      AVNumberOfChannelsKey: 1
    ]
    #endif
    
    if session.canAddOutput(audioOutput) {
      session.addOutput(audioOutput)
    } else {
      fatalError("Can't add `audioOutput`.")
    }
    
    let type: AVCaptureDevice.DeviceType = if #available(macOS 14.0, *) {
      .microphone
    } else {
      // Fallback on earlier versions
      .builtInMicrophone
    }
    
    let discoverySession = AVCaptureDevice
      .DiscoverySession(deviceTypes: [type], mediaType: .audio, position: .unspecified)
    
    let devices = discoverySession.devices
    
    // 200e 4c is the modelID of airpod pro
    let microphone = devices.first(where: { device in device.modelID == "200e 4c"}) ??
    AVCaptureDevice.default(type, for: .audio, position: .unspecified)
    
    guard
      let microphone,
      let microphoneInput = try? AVCaptureDeviceInput(device: microphone) else {
      fatalError("Can't create microphone.")
    }
    
    if session.canAddInput(microphoneInput) {
      session.addInput(microphoneInput)
    }
    
    session.commitConfiguration()
  }
}

extension BreathObsever {
  public func startAnalyzing() throws {
    try sessionQueue.asyncAndWait { [weak self] in
      guard case .authorized = AVCaptureDevice.authorizationStatus(for: .audio) else {
        return
      }
      self?.session?.startRunning()
      try self?.audioEngine?.start()
      
      // Wait for one seconds and set the flag to true to start collecting data
      // since the first few pack of Data normally contain loss
      self?.sessionQueue.asyncAfter(deadline: .now() + 1) {
        self?.collectingData = true
      }
    }
  }
  
  public func stopAnalyzing() {
    sessionQueue.async { [weak self] in
      self?.session?.stopRunning()
      self?.audioEngine?.stop()
      self?.collectingData = false
    }
  }
}
