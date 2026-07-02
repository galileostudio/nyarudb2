import Foundation

/// A stable reference to a record on disk.
///
/// Always carries the shard id. Storing bare offsets (the old design) caused
/// cross-shard lookup and delete corruption: the same offset is valid in
/// every shard file, so an unqualified offset silently addressed the wrong
/// document. Every index entry in NyaruDB is a `RecordPointer`.
public struct RecordPointer: Hashable, Codable, Sendable {
  public let shardID: String
  public let offset: UInt64

  public init(shardID: String, offset: UInt64) {
    self.shardID = shardID
    self.offset = offset
  }
}
