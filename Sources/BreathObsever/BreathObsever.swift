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
  
  /// The number of sample per frame
  static let samples = 512
  static let hopCount = 256
  
  let forwardDCT = vDSP.DCT(count: samples, transformType: .II)!
  
  /// The window sequence for normalizing
  let hanningWindow = vDSP.window(
    ofType: Float.self,
    usingSequence: .hanningNormalized,
    count: samples,
    isHalfWindow: false
  )
  
  /// A buffer that contains the raw audio data from AVFoundation.
  var rawAudioData = [Int16]()
  
  /// A reusable array that contains the current frame of time-domain audio data as single-precision
  /// values.
  var timeDomainBuffer = [Float](repeating: 0, count: samples)
  
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
  
  /// audio sample buffer size
  let bufferSize: UInt32 = 1024
  
  /// samples limit at the point where we reach this limit, we apply the respiratory rate calculation
  /// (each 5 seconds)
  static let samplesLimit = 24000 * 5
    
  static let amplitudeSamplesCapacity = 50
  
  ///Tthe samples of amplitude for 5 seconds
  /// Because we get the amplitude value in each 0.1 second (10Hz), so we need the array of size 10 * 5 = 50
  var amplitudeSamples: [Float] = {
    var array = [Float]()
    array.reserveCapacity(amplitudeSamplesCapacity)
    return array
  }()
  
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
  
}

extension BreathObsever {
  func processData(values: [Int16]) {
    print(values)
    // convert the buffer data to the timeDomainBuffer
    vDSP.convertElements(of: values, to: &timeDomainBuffer)
    
    
    // apply Hanning window to smoothing the data
    vDSP.multiply(timeDomainBuffer, hanningWindow, result: &timeDomainBuffer)
    
    // get the abs value as amplitudes
    vDSP.absolute(timeDomainBuffer, result: &timeDomainBuffer)
    
  }
}

extension BreathObsever {
  
  private func configureAudioEngine() {
    let newEngine = AVAudioEngine()
    audioEngine = newEngine
  }
  
  private func configureCaptureSession() {
    session = AVCaptureSession()
    
    // bandpass filter at 10 to 1000 Hz
    let bandpassFilter = AVAudioUnitEQ(numberOfBands: 1)
    let topFrequency: Float = 1000 // in Hz
    let bottomFrequency: Float = 10  // in Hz
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
      AVSampleRateKey: 24000, // 24 Khz is the sample rate of Apple's airpod
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
    try sessionQueue.asyncAndWait {
      [weak self] in
      guard case .authorized = AVCaptureDevice.authorizationStatus(for: .audio) else {
        return
      }
      self?.session?.startRunning()
      try self?.audioEngine?.start()
    }
  }
  
  public func stopAnalyzing() {
    sessionQueue.async { [weak self] in
      self?.session?.stopRunning()
      self?.audioEngine?.stop()
    }
  }
}
