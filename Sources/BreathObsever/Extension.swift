import Foundation

extension Collection {
  /// Returns the element at the specified index if it is within bounds, otherwise nil.
  subscript (safe index: Index) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}

extension UnsafeMutablePointer where Pointee == Float {
  func array(count: Int) -> [Float] {
    Array(UnsafeMutableBufferPointer(start: self, count: count))
  }
}

