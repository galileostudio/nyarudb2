import Crypto
import Foundation
import SwiftMsgpack

/// An in-memory sorted array-based index that maps `FieldValue` keys to
/// posting lists of `RecordPointer` values.
///
/// **Architecture choice.** This index uses a sorted array with binary search,
/// giving O(log n) point lookups and trivially correct range scans — the same
/// asymptotic performance as a B-tree. An array is significantly simpler to
/// implement, test, and debug. Since the entire index is kept in memory,
/// the O(n) insertion cost of shifting array elements is acceptable for the
/// typical mobile workloads NyaruDB targets (hundreds to low thousands of
/// unique keys).
///
/// Persistence is O(n): the entire array is serialised at once using MsgPack
/// and compressed with gzip. For the expected key counts this is negligible.
///
/// **Class semantics.** `OrderedIndex` is a `final class` rather than a value
/// type to avoid Swift's Copy-on-Write (COW) penalties during bulk inserts.
/// With COW, mutating an array-backed value type duplicates the entire
/// internal storage on every mutation, which would make building indexes from
/// a large shard scan quadratic.
///
/// **Thread safety.** The `@unchecked Sendable` conformance is safe because
/// `OrderedIndex` is always accessed from within a single `CollectionCore`
/// actor, which serialises all mutations.
public final class OrderedIndex: Codable, @unchecked Sendable {
  /// The sorted array of unique keys.
  @usableFromInline internal private(set) var keys: [FieldValue] = []
  /// The posting lists parallel to `keys`: `postings[i]` contains all pointers
  /// whose document has the value `keys[i]` for the indexed field.
  @usableFromInline internal private(set) var postings: [[RecordPointer]] = []

  /// The total number of index entries (sum of all posting-list lengths).
  public var entryCount: Int { postings.reduce(0) { $0 + $1.count } }
  /// The number of unique keys in the index.
  public var uniqueKeyCount: Int { keys.count }
  /// Whether the index contains no keys.
  public var isEmpty: Bool { keys.isEmpty }

  public init() {}

  // MARK: - Search

  /// Returns whether the given key exists in the index.
  ///
  /// - Parameter key: The key to look up.
  /// - Returns: `true` if at least one record is indexed under this key.
  @inlinable
  public func contains(_ key: FieldValue) -> Bool {
    let pos = lowerBound(key)
    return pos < keys.count && keys[pos] == key
  }

  /// Returns all record pointers indexed under the given key.
  ///
  /// - Parameter key: The key to look up.
  /// - Returns: The posting list for that key, or an empty array if the key
  ///   is not present.
  @inlinable
  public func search(_ key: FieldValue) -> [RecordPointer] {
    let pos = lowerBound(key)
    if pos < keys.count && keys[pos] == key {
      return postings[pos]
    }
    return []
  }

  /// Returns all record pointers whose keys fall within the specified range.
  ///
  /// Each bound can be `nil` (unbounded on that side). The inclusivity of
  /// each bound is controlled separately.
  ///
  /// - Parameters:
  ///   - lower: The lower bound, or `nil` for no lower bound.
  ///   - lowerInclusive: Whether the lower bound is inclusive.
  ///   - upper: The upper bound, or `nil` for no upper bound.
  ///   - upperInclusive: Whether the upper bound is inclusive.
  /// - Returns: All pointers in the range, deduplicated across keys.
  @inlinable
  public func range(
    lower: FieldValue?, lowerInclusive: Bool,
    upper: FieldValue?, upperInclusive: Bool
  ) -> [RecordPointer] {
    let start: Int
    if let lower = lower {
      start = lowerInclusive ? lowerBound(lower) : upperBound(lower)
    } else {
      start = 0
    }

    let end: Int
    if let upper = upper {
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

  /// Inserts a pointer for the given key. If the key already exists, the
  /// pointer is appended to its posting list.
  ///
  /// - Parameters:
  ///   - key: The index key.
  ///   - pointer: The record pointer to insert.
  public func insert(key: FieldValue, pointer: RecordPointer) {
    let pos = lowerBound(key)
    if pos < keys.count && keys[pos] == key {
      postings[pos].append(pointer)
    } else {
      keys.insert(key, at: pos)
      postings.insert([pointer], at: pos)
    }
  }

  /// Removes a specific pointer from the posting list for the given key.
  /// If the posting list becomes empty, the key entry is removed entirely.
  ///
  /// - Parameters:
  ///   - key: The index key.
  ///   - pointer: The record pointer to remove.
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
  ///
  /// Assumes the key has not changed — this is used when a record is updated
  /// in place (same key, same shard) and only the file offset changes.
  ///
  /// - Parameters:
  ///   - key: The index key.
  ///   - old: The old pointer to replace.
  ///   - new: The new pointer.
  /// - Returns: `true` if the replacement was performed, `false` if the old
  ///   pointer was not found.
  @discardableResult
  public func replace(key: FieldValue, old: RecordPointer, new: RecordPointer) -> Bool {
    let pos = lowerBound(key)
    guard pos < keys.count, keys[pos] == key else { return false }
    guard let i = postings[pos].firstIndex(of: old) else { return false }

    if postings[pos].contains(new) {
      postings[pos].remove(at: i)
    } else {
      postings[pos][i] = new
    }
    return true
  }

  // MARK: - Binary Search Helpers

  /// Returns the index of the first key that is not less than the given key
  /// (i.e. the insertion point that maintains sort order).
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

  /// Returns the index of the first key that is greater than the given key.
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

  /// Serialises the index to disk using MsgPack encoding, gzip compression,
  /// and optional AES-256-GCM encryption.
  ///
  /// The on-disk format is:
  /// ```
  /// if encrypted: AES-GCM(gzip(MsgPack(OrderedIndex)))
  /// else:         gzip(MsgPack(OrderedIndex))
  /// ```
  ///
  /// - Parameters:
  ///   - url: The destination file URL.
  ///   - encryptionKey: Optional AES-256-GCM key.
  /// - Throws: `NyaruError.encryptionFailed` if sealing fails.
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

  /// Loads an index from disk, handling decompression and optional decryption.
  ///
  /// - Parameters:
  ///   - url: The source file URL.
  ///   - encryptionKey: Optional AES-256-GCM key.
  /// - Returns: A fully restored `OrderedIndex`, or an empty index if the
  ///   file is empty.
  /// - Throws: `NyaruError.decryptionFailed` if decryption fails.
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
