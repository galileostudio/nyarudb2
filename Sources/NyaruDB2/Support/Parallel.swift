import Foundation

/// Chunked parallel map for CPU-bound transforms (compression, encryption,
/// encoding). Uses `DispatchQueue.concurrentPerform` to saturate all cores
/// while preserving element order.
///
/// Small inputs run serially — thread fan-out costs more than it saves below
/// a few dozen elements.
enum Parallel {
  /// The element count below which `map` runs serially.
  static let serialThreshold = 32

  /// Maps `transform` over `items` in parallel, preserving order.
  ///
  /// The transform must be safe to call concurrently from multiple threads
  /// (pure, or touching only immutable/locked state). If any invocation
  /// throws, one of the thrown errors is rethrown and the partial results
  /// are discarded.
  ///
  /// - Parameter serialThreshold: Inputs smaller than this run serially.
  ///   Lower it when each element is expensive enough (e.g. compressing a
  ///   whole index snapshot) to amortise thread fan-out even for a handful
  ///   of items.
  static func map<T, R>(
    _ items: [T], serialThreshold: Int = Parallel.serialThreshold,
    _ transform: (T) throws -> R
  ) throws -> [R] {
    if items.count < serialThreshold {
      return try items.map(transform)
    }

    let count = items.count
    let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    // A few chunks per core keeps stragglers from serialising the tail.
    let chunkCount = min(count, coreCount * 4)
    let chunkSize = (count + chunkCount - 1) / chunkCount

    let errorLock = NSLock()
    nonisolated(unsafe) var firstError: Error?
    nonisolated(unsafe) var results = [R?](repeating: nil, count: count)

    results.withUnsafeMutableBufferPointer { output in
      nonisolated(unsafe) let out = output
      items.withUnsafeBufferPointer { source in
        nonisolated(unsafe) let input = source
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
          let start = chunkIndex * chunkSize
          let end = min(start + chunkSize, count)
          // Ceil-division chunk sizing can leave trailing chunks empty.
          guard start < end else { return }
          for i in start..<end {
            do {
              out[i] = try transform(input[i])
            } catch {
              errorLock.lock()
              if firstError == nil { firstError = error }
              errorLock.unlock()
              return
            }
          }
        }
      }
    }

    if let error = firstError { throw error }
    return results.map { $0! }
  }
}
