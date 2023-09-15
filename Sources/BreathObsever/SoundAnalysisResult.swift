import Foundation
import SoundAnalysis
import Combine

/// An observer that forwards Sound Analysis results to a combine subject.
///
/// Sound Analysis emits classification outcomes to observer objects. When classification completes, an
/// observer receives termination messages that indicate the reason. A subscriber receives a stream of
/// results and a termination message with an error, if necessary.
public class SoundAnalysisResult: NSObject, SNResultsObserving {
  
  private let subject: PassthroughSubject<SNClassificationResult, Error>
  
  init(subject: PassthroughSubject<SNClassificationResult, Error>) {
    self.subject = subject
  }
  
  public func request(_ request: SNRequest, didProduce result: SNResult) {
    guard let result = result as? SNClassificationResult else {
      return
    }
    subject.send(result)
  }
  
  public func requestDidComplete(_ request: SNRequest) {
    subject.send(completion: .finished)
  }
  
  public func request(_ request: SNRequest, didFailWithError error: Error) {
    subject.send(completion: .failure(error))
  }
}
