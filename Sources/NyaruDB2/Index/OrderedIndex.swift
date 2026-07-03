import Crypto
import Foundation
import SwiftMsgpack

/// A sorted array-based index mapping `FieldValue` keys to `[RecordPointer]`.
///
/// Architecture choice: a sorted array with binary search gives the same O(log n)
/// point lookups and trivially correct range scans as a B-tree, but is significantly
/// simpler to implement correctly and test. Since the index is kept entirely in memory,
/// the O(n) insertion cost of shifting array elements is acceptable for typical mobile
/// workloads. Persistence is O(n) (serializing the whole array at once).
///
/// Implemented as a `final class` to avoid Swift's Copy-on-Write (COW) performance
/// penalties during bulk inserts, which would otherwise duplicate the entire array
/// on every mutation.
public final class OrderedIndex: Codable, @unchecked Sendable {
  @usableFromInline internal private(set) var keys: [FieldValue] = []
  @usableFromInline internal private(set) var postings: [[RecordPointer]] = []

  public var entryCount: Int { postings.reduce(0) { $0 + $1.count } }
  public var uniqueKeyCount: Int { keys.count }
  public var isEmpty: Bool { keys.isEmpty }

  public init() {}

  // MARK: - Search

  @inlinable
  public func contains(_ key: FieldValue) -> Bool {
    let pos = lowerBound(key)
    return pos < keys.count && keys[pos] == key
  }

  @inlinable
  public func search(_ key: FieldValue) -> [RecordPointer] {
    let pos = lowerBound(key)
    if pos < keys.count && keys[pos] == key {
      return postings[pos]
    }
    return []
  }

  @inlinable
  public func range(
    lower: FieldValue?, lowerInclusive: Bool,
    upper: FieldValue?, upperInclusive: Bool
  ) -> [RecordPointer] {
    let start: Int
    if let lower = lower {
      // If inclusive, we start at the first element >= lower (lowerBound)
      // If exclusive, we start at the first element > lower (upperBound)
      start = lowerInclusive ? lowerBound(lower) : upperBound(lower)
    } else {
      start = 0
    }

    let end: Int
    if let upper = upper {
      // If inclusive, we stop after the last element <= upper (upperBound)
      // If exclusive, we stop before the first element >= upper (lowerBound)
      end = upperInclusive ? upperBound(upper) : lowerBound(upper)
    } else {
      end = keys.count
    }

    guard start <= end, start < keys.count else { return [] }
    let safeEnd = min(end, keys.count)

    var out: [RecordPointer] = []
    for i in start..<safeEnd {
      out.append(contentsOf: postings[i])
    }
    return out
  }

  // MARK: - Mutation

  public func insert(key: FieldValue, pointer: RecordPointer) {
    let pos = lowerBound(key)
    if pos < keys.count && keys[pos] == key {
      postings[pos].append(pointer)
    } else {
      keys.insert(key, at: pos)
      postings.insert([pointer], at: pos)
    }
  }

  public func remove(key: FieldValue, pointer: RecordPointer) {
    let pos = lowerBound(key)
    guard pos < keys.count, keys[pos] == key else { return }

    if let i = postings[pos].firstIndex(of: pointer) {
      postings[pos].remove(at: i)
      if postings[pos].isEmpty {
        keys.remove(at: pos)
        postings.remove(at: pos)
      }
    }
  }

  /// Replaces `old` pointer with `new` pointer for a given key.
  /// Assumes the key itself has not changed.
  @discardableResult
  public func replace(key: FieldValue, old: RecordPointer, new: RecordPointer) -> Bool {
    let pos = lowerBound(key)
    guard pos < keys.count, keys[pos] == key else { return false }
    guard let i = postings[pos].firstIndex(of: old) else { return false }

    // Prevent duplicate pointers if `new` already exists in the posting list
    if postings[pos].contains(new) {
      postings[pos].remove(at: i)
    } else {
      postings[pos][i] = new
    }
    return true
  }

  // MARK: - Binary Search Helpers

  @usableFromInline internal func lowerBound(_ key: FieldValue) -> Int {
    var low = 0
    var high = keys.count
    while low < high {
      let mid = (low + high) / 2
      if keys[mid] < key {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  @usableFromInline internal func upperBound(_ key: FieldValue) -> Int {
    var low = 0
    var high = keys.count
    while low < high {
      let mid = (low + high) / 2
      if keys[mid] <= key {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  // MARK: - Persistence

  /// Persists the index to disk using MsgPack + Gzip, optionally encrypted with AES-GCM.
  public func persist(to url: URL, encryptionKey: SymmetricKey?) throws {
    let data = try MsgPackEncoder().encode(self)
    let compressed = try Compressor.compress(data, method: .gzip)

    let finalData: Data
    if let key = encryptionKey {
      let sealedBox = try AES.GCM.seal(compressed, using: key)
      guard let combined = sealedBox.combined else {
        throw NyaruError.encryptionFailed
      }
      finalData = combined
    } else {
      finalData = compressed
    }

    try finalData.write(to: url, options: .atomic)
  }

  /// Loads the index from disk, handling decompression and decryption.
  public static func load(from url: URL, encryptionKey: SymmetricKey?) throws -> OrderedIndex {
    let raw = try Data(contentsOf: url, options: .alwaysMapped)
    guard !raw.isEmpty else {
      return OrderedIndex()
    }

    let decompressed: Data
    if let key = encryptionKey {
      do {
        let sealedBox = try AES.GCM.SealedBox(combined: raw)
        decompressed = try AES.GCM.open(sealedBox, using: key)
      } catch {
        throw NyaruError.decryptionFailed
      }
    } else {
      decompressed = raw
    }

    let data = try Compressor.decompress(decompressed, method: .gzip)
    return try MsgPackDecoder().decode(OrderedIndex.self, from: data)
  }
}
