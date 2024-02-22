import AVFoundation
import Accelerate

public class FilterParameter {
  let b0: Double
  let b1: Double
  let b2: Double
  let a1: Double
  let a2: Double
  
  init(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
    self.b0 = b0
    self.b1 = b1
    self.b2 = b2
    self.a1 = a1
    self.a2 = a2
  }
}

public final class BandPassFilter: FilterParameter {
  public init(sampleRate: Double, frequencyLow: Double, frequencyHigh: Double) {
    let centerFrequency = (frequencyLow + frequencyHigh) / 2.0
    let bandwidth = frequencyHigh - frequencyLow
    
    let w0: Double = 2.0 * Double.pi * centerFrequency / sampleRate
    let alpha: Double = sin(w0) * sinh(log(2.0) * bandwidth * w0 / sin(w0))
    
    let a0: Double = 1.0 + alpha
    let a1: Double = -2.0 * cos(w0)
    let a2: Double = 1.0 - alpha
    let b0: Double = alpha
    let b1: Double = 0.0
    let b2: Double = -alpha
    
    super.init(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
  }
  
  public init(sampleRate: Double, frequency: Double, width: Double) {
    let w0: Double = 2.0 * Double.pi * frequency / sampleRate
    let alpha: Double = sin(w0) * sinh(log(2.0) / 2.0 * width * w0 / sin(w0))
    
    let a0: Double = 1.0 + alpha
    let a1: Double = -2.0 * cos(w0)
    let a2: Double = 1.0 - alpha
    let b0: Double = alpha
    let b1: Double = 0.0
    let b2: Double = -1.0 * alpha
    
    super.init(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
  }
}
