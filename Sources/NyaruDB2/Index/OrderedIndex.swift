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
  ///   - maxCount: Stop after collecting this many pointers (`nil` = all).
  ///     Results are collected in ascending key order, so the first
  ///     `maxCount` pointers are the lowest-keyed matches.
  /// - Returns: The pointers in the range, in ascending key order.
  @inlinable
  public func range(
    lower: FieldValue?, lowerInclusive: Bool,
    upper: FieldValue?, upperInclusive: Bool,
    maxCount: Int? = nil
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
    if let maxCount {
      out.reserveCapacity(maxCount)
      for i in start..<safeEnd {
        for pointer in postings[i] {
          out.append(pointer)
          if out.count >= maxCount { return out }
        }
      }
      return out
    }

    let total = postings[start..<safeEnd].reduce(0) { $0 + $1.count }
    out.reserveCapacity(total)
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

  /// Removes a batch of `(key, pointer)` entries in a single sweep — the
  /// removal analogue of `bulkLoad`. Removing entries one at a time shifts
  /// the tail of the key array on every emptied key, which is quadratic for
  /// large batches; this rebuilds the arrays once instead.
  ///
  /// - Parameter entries: The entries to remove. Pointers not present under
  ///   their key are ignored.
  public func bulkRemove(_ entries: [(key: FieldValue, pointer: RecordPointer)]) {
    if entries.isEmpty { return }

    // Victims as a Set per key: membership checks make the sweep O(p) per
    // posting list instead of O(p × v) with firstIndex per victim. A pointer
    // is never live under the same key twice, so set semantics are exact.
    var toRemove: [FieldValue: Set<RecordPointer>] = [:]
    toRemove.reserveCapacity(entries.count)
    for entry in entries {
      toRemove[entry.key, default: []].insert(entry.pointer)
    }

    var newKeys: [FieldValue] = []
    var newPostings: [[RecordPointer]] = []
    newKeys.reserveCapacity(keys.count)
    newPostings.reserveCapacity(postings.count)
    var count = 0

    for i in keys.indices {
      guard let victims = toRemove[keys[i]] else {
        newKeys.append(keys[i])
        newPostings.append(postings[i])
        count += postings[i].count
        continue
      }
      var list = postings[i]
      list.removeAll { victims.contains($0) }
      if !list.isEmpty {
        newKeys.append(keys[i])
        newPostings.append(list)
        count += list.count
      }
    }

    keys = newKeys
    postings = newPostings
    _entryCount = count
  }

  /// Removes every occurrence of the given pointer across all keys in a
  /// single pass. Keys whose posting lists become empty are removed.
  ///
  /// Used when a record disappears (stale pointer, corruption) and its index
  /// keys are unknown.
  ///
  /// - Parameter pointer: The record pointer to purge from the index.
  public func removeAll(pointer: RecordPointer) {
    var i = 0
    while i < postings.count {
      if let j = postings[i].firstIndex(of: pointer) {
        postings[i].remove(at: j)
        _entryCount -= 1
        if postings[i].isEmpty {
          keys.remove(at: i)
          postings.remove(at: i)
          continue
        }
      }
      i += 1
    }
  }

  /// Rewrites pointer offsets after shard compaction using per-shard offset
  /// maps, without re-reading or re-parsing any document.
  ///
  /// For every pointer whose shard appears in `mapping`:
  /// - If the old offset has a new offset, the pointer is rewritten.
  /// - If the old offset is absent (the record no longer exists), the stale
  ///   entry is dropped.
  ///
  /// Pointers into shards not present in `mapping` are kept unchanged.
  ///
  /// - Parameter mapping: Shard ID → (old offset → new offset).
  public func compactRemap(_ mapping: [String: [UInt64: UInt64]]) {
    var newKeys: [FieldValue] = []
    var newPostings: [[RecordPointer]] = []
    newKeys.reserveCapacity(keys.count)
    newPostings.reserveCapacity(postings.count)
    var count = 0

    for i in keys.indices {
      var list: [RecordPointer] = []
      list.reserveCapacity(postings[i].count)
      for pointer in postings[i] {
        guard let shardMap = mapping[pointer.shardID] else {
          list.append(pointer)
          continue
        }
        if let newOffset = shardMap[pointer.offset] {
          list.append(RecordPointer(shardID: pointer.shardID, offset: newOffset))
        }
        // Absent from the map: the record did not survive compaction — drop it.
      }
      if !list.isEmpty {
        newKeys.append(keys[i])
        newPostings.append(list)
        count += list.count
      }
    }

    keys = newKeys
    postings = newPostings
    _entryCount = count
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
  ///
  /// Uses `withUnsafeBufferPointer` to access the `keys` array without
  /// bounds-checking overhead on every `keys[mid]` access in the search loop.
  @usableFromInline internal func lowerBound(_ key: FieldValue) -> Int {
    keys.withUnsafeBufferPointer { keys in
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
  }

  /// Returns the index of the first key that is greater than the given key.
  @usableFromInline internal func upperBound(_ key: FieldValue) -> Int {
    keys.withUnsafeBufferPointer { keys in
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
  }

  // MARK: - Persistence

  /// Magic bytes for the binary snapshot format: `"NYI1"`.
  private static let snapshotMagic: [UInt8] = [0x4E, 0x59, 0x49, 0x31]

  /// Serialises the index to disk using a hand-rolled binary layout, gzip
  /// compression, and optional AES-256-GCM encryption.
  ///
  /// The binary layout is roughly an order of magnitude faster to encode and
  /// decode than Codable+MsgPack for large indexes, and it interns shard IDs
  /// into a string table so each pointer costs 10 bytes instead of carrying
  /// a repeated string:
  /// ```
  /// "NYI1" | u16 version | u32 shardCount | shardCount × (u16 len + utf8)
  /// u32 keyCount
  /// keyCount × ( FieldValue | u32 postingCount
  ///              | postingCount × (u16 shardIdx + u64 offset) )
  /// FieldValue: u8 tag — 0 null, 1 false, 2 true,
  ///             3 int (+ i64), 4 double (+ f64 bits),
  ///             5 string (+ u32 len + utf8)
  /// ```
  /// The whole payload is then gzip-compressed and, when a key is provided,
  /// AES-GCM sealed — same envelope as before.
  ///
  /// - Parameters:
  ///   - url: The destination file URL.
  ///   - encryptionKey: Optional AES-256-GCM key.
  /// - Throws: `NyaruError.encryptionFailed` if sealing fails.
  public func persist(to url: URL, encryptionKey: SymmetricKey?) throws {
    try Self.persist(snapshot(), to: url, encryptionKey: encryptionKey)
  }

  /// An O(1) copy-on-write capture of the index contents. The arrays are
  /// value types sharing storage with the live index — encoding a snapshot
  /// off the owning actor is safe, and concurrent mutations simply pay the
  /// CoW copy.
  struct Snapshot: Sendable {
    let keys: [FieldValue]
    let postings: [[RecordPointer]]
    let entryCount: Int
  }

  /// Captures the current contents for out-of-actor persistence.
  func snapshot() -> Snapshot {
    Snapshot(keys: keys, postings: postings, entryCount: _entryCount)
  }

  /// Encodes, compresses, optionally seals, and atomically writes a
  /// snapshot. Static so the expensive part can run detached from the
  /// actor that owns the index.
  static func persist(_ snapshot: Snapshot, to url: URL, encryptionKey: SymmetricKey?) throws {
    let data = encodeBinary(snapshot)
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
  /// Reads the binary snapshot format; snapshots written by older versions
  /// (Codable+MsgPack) are decoded through the legacy path, so upgrades do
  /// not force an index rebuild.
  ///
  /// - Parameters:
  ///   - url: The source file URL.
  ///   - encryptionKey: Optional AES-256-GCM key.
  /// - Returns: A fully restored `OrderedIndex`, or an empty index if the
  ///   file is empty.
  /// - Throws: `NyaruError.decryptionFailed` if decryption fails, or a
  ///   decoding error if neither format matches.
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
    if let index = decodeBinary(data) {
      return index
    }
    // Legacy snapshot (Codable + MsgPack) from a previous version.
    return try MsgPackDecoder().decode(OrderedIndex.self, from: data)
  }

  // MARK: - Binary snapshot codec

  private static func encodeBinary(_ snapshot: Snapshot) -> Data {
    let keys = snapshot.keys
    let postings = snapshot.postings

    // Intern shard IDs.
    var shardTable: [String] = []
    var shardIndexByID: [String: UInt16] = [:]
    for posting in postings {
      for pointer in posting where shardIndexByID[pointer.shardID] == nil {
        shardIndexByID[pointer.shardID] = UInt16(shardTable.count)
        shardTable.append(pointer.shardID)
      }
    }

    // Rough size estimate: 10 bytes per posting + ~16 per key.
    var out = Data(capacity: 64 + snapshot.entryCount * 10 + keys.count * 16)
    out.append(contentsOf: Self.snapshotMagic)
    Binary.append(UInt16(1), to: &out)  // version
    Binary.append(UInt32(shardTable.count), to: &out)
    for shardID in shardTable {
      let utf8 = Data(shardID.utf8)
      Binary.append(UInt16(utf8.count), to: &out)
      out.append(utf8)
    }

    Binary.append(UInt32(keys.count), to: &out)
    for i in keys.indices {
      switch keys[i] {
      case .null:
        out.append(0)
      case .bool(let b):
        out.append(b ? 2 : 1)
      case .int(let v):
        out.append(3)
        Binary.append(UInt64(bitPattern: v), to: &out)
      case .double(let d):
        out.append(4)
        Binary.append(d.bitPattern, to: &out)
      case .string(let s):
        out.append(5)
        let utf8 = Data(s.utf8)
        Binary.append(UInt32(utf8.count), to: &out)
        out.append(utf8)
      }

      Binary.append(UInt32(postings[i].count), to: &out)
      for pointer in postings[i] {
        Binary.append(shardIndexByID[pointer.shardID] ?? 0, to: &out)
        Binary.append(pointer.offset, to: &out)
      }
    }
    return out
  }

  private static func decodeBinary(_ data: Data) -> OrderedIndex? {
    guard data.count >= 10, [UInt8](data.prefix(4)) == snapshotMagic,
      Binary.readUInt16(data, at: 4) == 1,
      let shardCount = Binary.readUInt32(data, at: 6)
    else { return nil }

    var pos = 10
    var shardTable: [String] = []
    shardTable.reserveCapacity(Int(shardCount))
    for _ in 0..<shardCount {
      guard let len = Binary.readUInt16(data, at: pos),
        pos + 2 + Int(len) <= data.count,
        let shardID = String(
          data: data[data.startIndex + pos + 2..<data.startIndex + pos + 2 + Int(len)],
          encoding: .utf8)
      else { return nil }
      shardTable.append(shardID)
      pos += 2 + Int(len)
    }

    guard let keyCount = Binary.readUInt32(data, at: pos) else { return nil }
    pos += 4

    let index = OrderedIndex()
    index.keys.reserveCapacity(Int(keyCount))
    index.postings.reserveCapacity(Int(keyCount))
    var total = 0

    for _ in 0..<keyCount {
      guard pos < data.count else { return nil }
      let tag = data[data.startIndex + pos]
      pos += 1
      let key: FieldValue
      switch tag {
      case 0: key = .null
      case 1: key = .bool(false)
      case 2: key = .bool(true)
      case 3:
        guard let bits = Binary.readUInt64(data, at: pos) else { return nil }
        key = .int(Int64(bitPattern: bits))
        pos += 8
      case 4:
        guard let bits = Binary.readUInt64(data, at: pos) else { return nil }
        key = .double(Double(bitPattern: bits))
        pos += 8
      case 5:
        guard let len = Binary.readUInt32(data, at: pos),
          pos + 4 + Int(len) <= data.count,
          let s = String(
            data: data[data.startIndex + pos + 4..<data.startIndex + pos + 4 + Int(len)],
            encoding: .utf8)
        else { return nil }
        key = .string(s)
        pos += 4 + Int(len)
      default:
        return nil
      }

      guard let postingCount = Binary.readUInt32(data, at: pos) else { return nil }
      pos += 4
      var list: [RecordPointer] = []
      list.reserveCapacity(Int(postingCount))
      for _ in 0..<postingCount {
        guard let shardIdx = Binary.readUInt16(data, at: pos),
          Int(shardIdx) < shardTable.count,
          let offset = Binary.readUInt64(data, at: pos + 2)
        else { return nil }
        // Interned lookup: every pointer shares the same String storage.
        list.append(RecordPointer(shardID: shardTable[Int(shardIdx)], offset: offset))
        pos += 10
      }
      index.keys.append(key)
      index.postings.append(list)
      total += list.count
    }

    guard pos == data.count else { return nil }
    index._entryCount = total
    return index
  }
}
