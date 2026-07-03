import Crypto
import Foundation
import SwiftMsgpack

/// In-memory ordered index: sorted unique keys with posting lists of
/// `RecordPointer`s.
///
/// Why not the old B-tree: the previous engine serialized the *entire*
/// B-tree to JSON and loaded it fully into memory anyway, so the B-tree
/// bought nothing over a sorted array while carrying real, catalogued bugs
/// (regressed `splitChild` reading a key after removal, broken removal
/// path, full document payloads duplicated inside nodes). A sorted array
/// with binary search gives the same O(log n) point lookups, trivially
/// correct range scans, O(n) snapshot persistence (the old code was O(n²)
/// re-serializing per insert), and a fraction of the code to audit. If the
/// index ever needs to be paged from disk, swap this type behind
/// `IndexStore` for a paged structure.
///
/// Values are `RecordPointer`s (shard-qualified), never document payloads.
struct OrderedIndex: Codable {
  private(set) var keys: [FieldValue] = []
  private(set) var postings: [[RecordPointer]] = []

  var entryCount: Int {
    postings.reduce(0) { $0 + $1.count }
  }
  var uniqueKeyCount: Int { keys.count }

  /// lower_bound: first position with keys[pos] >= key.
  private func lowerBound(_ key: FieldValue) -> Int {
    var low = 0
    var high = keys.count
    while low < high {
      let mid = (low + high) / 2
      if keys[mid] < key { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// upper_bound: first position with keys[pos] > key.
  private func upperBound(_ key: FieldValue) -> Int {
    var low = 0
    var high = keys.count
    while low < high {
      let mid = (low + high) / 2
      if keys[mid] <= key { low = mid + 1 } else { high = mid }
    }
    return low
  }

  mutating func insert(key: FieldValue, pointer: RecordPointer) {
    let pos = lowerBound(key)
    if pos < keys.count && keys[pos] == key {
      postings[pos].append(pointer)
    } else {
      keys.insert(key, at: pos)
      postings.insert([pointer], at: pos)
    }
  }

  mutating func remove(key: FieldValue, pointer: RecordPointer) {
    let pos = lowerBound(key)
    guard pos < keys.count, keys[pos] == key else { return }
    postings[pos].removeAll { $0 == pointer }
    if postings[pos].isEmpty {
      keys.remove(at: pos)
      postings.remove(at: pos)
    }
  }

  /// Replaces one pointer with another under the same key (in-place moves).
  mutating func replace(key: FieldValue, old: RecordPointer, new: RecordPointer) {
    let pos = lowerBound(key)
    guard pos < keys.count, keys[pos] == key else { return }
    if let i = postings[pos].firstIndex(of: old) {
      postings[pos][i] = new
    }
  }

  func search(_ key: FieldValue) -> [RecordPointer] {
    let pos = lowerBound(key)
    guard pos < keys.count, keys[pos] == key else { return [] }
    return postings[pos]
  }

  /// Range scan with inclusive/exclusive bounds. Nil bound = unbounded.
  func range(
    lower: FieldValue?, lowerInclusive: Bool,
    upper: FieldValue?, upperInclusive: Bool
  ) -> [RecordPointer] {
    let start: Int
    if let lower {
      start = lowerInclusive ? lowerBound(lower) : upperBound(lower)
    } else {
      start = 0
    }
    let end: Int
    if let upper {
      end = upperInclusive ? upperBound(upper) : lowerBound(upper)
    } else {
      end = keys.count
    }
    guard start < end else { return [] }
    var result: [RecordPointer] = []
    for i in start..<end {
      result.append(contentsOf: postings[i])
    }
    return result
  }

  func contains(_ key: FieldValue) -> Bool {
    let pos = lowerBound(key)
    return pos < keys.count && keys[pos] == key
  }

  func persist(to url: URL, encryptionKey: SymmetricKey?) throws {
    let data = try MsgPackEncoder().encode(self)
    let compressed = try Compressor.compress(data, method: .gzip)

    let finalData: Data
    if let key = encryptionKey {
      let sealedBox = try AES.GCM.seal(compressed, using: key)
      finalData = sealedBox.combined!
    } else {
      finalData = compressed
    }
    try finalData.write(to: url, options: .atomic)
  }

  static func load(from url: URL, encryptionKey: SymmetricKey?) throws -> OrderedIndex {
    let raw = try Data(contentsOf: url, options: .alwaysMapped)
    let decompressed: Data

    if let key = encryptionKey {
      let sealedBox = try AES.GCM.SealedBox(combined: raw)
      decompressed = try AES.GCM.open(sealedBox, using: key)
    } else {
      decompressed = raw
    }

    let data = try Compressor.decompress(decompressed, method: .gzip)
    return try MsgPackDecoder().decode(OrderedIndex.self, from: data)
  }
}
