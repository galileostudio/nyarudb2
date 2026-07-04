import Foundation

/// A stable, hashable reference to a physical record stored in a shard file.
///
/// Every index entry in NyaruDB is a `RecordPointer`. Storing bare offsets
/// caused cross-shard lookup and delete corruption in the earlier engine
/// because the same raw offset value is valid in every shard file — without
/// the shard identifier, a pointer is ambiguous. By always coupling the shard
/// ID with the offset, every index entry unambiguously identifies one record
/// on disk, regardless of how many shards exist.
///
/// Conforms to `Hashable` (so it can be stored in posting-list arrays and
/// sets), `Codable` (so index snapshots are serialisable), and `Sendable`
/// (for safe use across actor boundaries).
public struct RecordPointer: Hashable, Codable, Sendable {
  /// The identifier of the shard file that contains the record. This matches
  /// the filename stem (e.g. `"default"` for `default.nyaru`) and is used by
  /// `CollectionCore` to route pointer lookups to the correct `ShardActor`.
  public let shardID: String

  /// The byte offset of the record header within the shard file. Offsets are
  /// stable across the lifetime of a file but may change after compaction,
  /// which is why index entries are rebuilt after a compact.
  public let offset: UInt64

  /// Creates a pointer to a record at the given shard and file offset.
  ///
  /// - Parameters:
  ///   - shardID: The identifier of the shard file containing the record.
  ///   - offset: The byte offset of the record header within the shard file.
  public init(shardID: String, offset: UInt64) {
    self.shardID = shardID
    self.offset = offset
  }
}
