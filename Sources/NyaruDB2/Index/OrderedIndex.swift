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
  /// Cached total entry count to avoid O(unique-key-count) reduction on every call.
  private var _entryCount: Int = 0

  /// The total number of index entries (sum of all posting-list lengths).
  public var entryCount: Int { _entryCount }
  /// The number of unique keys in the index.
  public var uniqueKeyCount: Int { keys.count }
  /// Whether the index contains no keys.
  public var isEmpty: Bool { keys.isEmpty }

  public init() {}

  private enum CodingKeys: String, CodingKey { case keys, postings }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keys = try container.decode([FieldValue].self, forKey: .keys)
    postings = try container.decode([[RecordPointer]].self, forKey: .postings)
    _entryCount = postings.reduce(0) { $0 + $1.count }
  }

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
    _entryCount += 1
  }

  /// Efficiently loads a batch of index entries in O(n + m) time.
  ///
  /// This method performs a bulk insertion of multiple index entries without
  /// causing O(n²) array-shifting overhead. It uses a single-pass merge algorithm
  /// that combines existing keys with new entries in one operation.
  ///
  /// The algorithm works as follows:
  ///   1. Sorts incoming entries by key (O(m log m))
  ///   2. Allocates new arrays with pre-calculated capacity (O(1) amortized)
  ///   3. Merges existing and new entries in a single pass (O(n + m))
  ///   4. Groups multiple pointers for duplicate keys
  ///
  /// - Parameter entries: An array of `(key: FieldValue, pointer: RecordPointer)`
  ///   tuples representing the new entries to load.
  ///
  /// - Complexity: O(n + m log m) where n is the existing entry count and
  ///   m is the number of new entries.
  ///
  /// - Note: This method replaces the entire internal storage with newly
  ///   allocated arrays, which is acceptable for batch operations where the
  ///   index is being rebuilt. For incremental inserts, prefer `insert(key:pointer:)`.
  ///
  /// - SeeAlso: `insert(key:pointer:)` for single-entry insertion,
  ///   `rebuildAllIndexes()` for rebuilding indexes from scratch.

  public func bulkLoad(_ entries: [(key: FieldValue, pointer: RecordPointer)]) {
    if entries.isEmpty { return }
    // Sort incoming entries
    let sortedEntries = entries.sorted { $0.key < $1.key }

    var newKeys: [FieldValue] = []
    var newPostings: [[RecordPointer]] = []
    // Pre-allocate to avoid array growth overhead
    newKeys.reserveCapacity(keys.count + sortedEntries.count)
    newPostings.reserveCapacity(postings.count + sortedEntries.count)

    var i = 0  // existing index
    var j = 0  // new entries

    // Single-pass merge
    while i < keys.count && j < sortedEntries.count {
      let existingKey = keys[i]
      let newKey = sortedEntries[j].key

      if newKey < existingKey {
        // Insert all pointers for this new key
        var group: [RecordPointer] = []
        while j < sortedEntries.count && sortedEntries[j].key == newKey {
          group.append(sortedEntries[j].pointer)
          j += 1
        }
        newKeys.append(newKey)
        newPostings.append(group)
      } else if existingKey < newKey {
        // Keep existing
        newKeys.append(keys[i])
        newPostings.append(postings[i])
        i += 1
      } else {
        // Merge: add new pointers to existing key
        var group = postings[i]
        while j < sortedEntries.count && sortedEntries[j].key == newKey {
          group.append(sortedEntries[j].pointer)
          j += 1
        }
        newKeys.append(keys[i])
        newPostings.append(group)
        i += 1
      }
    }

    // Append remaining existing
    while i < keys.count {
      newKeys.append(keys[i])
      newPostings.append(postings[i])
      i += 1
    }

    // Append remaining new
    while j < sortedEntries.count {
      let newKey = sortedEntries[j].key
      var group: [RecordPointer] = []
      while j < sortedEntries.count && sortedEntries[j].key == newKey {
        group.append(sortedEntries[j].pointer)
        j += 1
      }
      newKeys.append(newKey)
      newPostings.append(group)
    }

    self.keys = newKeys
    self.postings = newPostings
    self._entryCount = newPostings.reduce(0) { $0 + $1.count }
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
      _entryCount -= 1
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

    if old == new { return true }

    if postings[pos].contains(new) {
      // `new` is already present (phantom duplicate): remove `old`, no net count change.
      postings[pos].remove(at: i)
      _entryCount -= 1
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
