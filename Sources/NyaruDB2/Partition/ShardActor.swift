import Foundation

/// Owns exactly one shard file and serializes every access to it.
///
/// One actor per shard means one `FileHandle` per shard, opened once and
/// reused for the shard's lifetime (the old engine re-read the whole file
/// via `Data(contentsOf:)` on every operation and leaked descriptors under
/// concurrency). Compression/decompression happens here so callers only ever
/// see raw JSON payloads.
actor ShardActor {
  let id: String
  private let file: SlottedFile
  private let compression: CompressionMethod

  init(id: String, url: URL, compression: CompressionMethod, fileProtection: FileProtection) throws
  {
    self.id = id
    self.compression = compression
    self.file = try SlottedFile(url: url, fileProtection: fileProtection)
  }

  var liveCount: Int { Int(file.liveCount) }

  /// True when opening this shard triggered crash recovery.
  var recoveredFromDirty: Bool { file.recoveredFromDirty }

  func sizeInBytes() -> UInt64 { file.sizeInBytes() }

  // MARK: - CRUD primitives

  /// Stores a JSON payload; returns a pointer to it.
  func insert(json: Data) throws -> RecordPointer {
    let stored = try Compressor.compress(json, method: compression)
    // Only keep the compressed form when it actually saves space.
    let (payload, method): (Data, CompressionMethod) =
      stored.count < json.count ? (stored, compression) : (json, .none)
    let offset = try file.append(payload: payload, compression: method)
    return RecordPointer(shardID: id, offset: offset)
  }

  /// Reads and decompresses the JSON payload at `offset`.
  /// Returns nil if the record was tombstoned.
  func read(at offset: UInt64) throws -> Data? {
    guard let record = try file.read(at: offset) else { return nil }
    return try Compressor.decompress(record.payload, method: record.compression)
  }

  /// Replaces the document at `offset`. If the new payload does not fit the
  /// immutable slot, the old slot is tombstoned and the payload re-appended.
  /// Returns the (possibly new) pointer.
  func update(at offset: UInt64, json: Data) throws -> RecordPointer {
    let stored = try Compressor.compress(json, method: compression)
    let (payload, method): (Data, CompressionMethod) =
      stored.count < json.count ? (stored, compression) : (json, .none)
    if try file.overwrite(at: offset, payload: payload, compression: method) {
      return RecordPointer(shardID: id, offset: offset)
    }
    try file.tombstone(at: offset)
    let newOffset = try file.append(payload: payload, compression: method)
    return RecordPointer(shardID: id, offset: newOffset)
  }

  func delete(at offset: UInt64) throws {
    try file.tombstone(at: offset)
  }

  /// All live documents, decompressed, with their offsets.
  func scanAll() throws -> [(offset: UInt64, json: Data)] {
    try file.scanLive().map {
      (offset: $0.offset, json: try Compressor.decompress($0.payload, method: $0.compression))
    }
  }

  // MARK: - Lifecycle

  func sync() throws {
    try file.sync()
  }

  func close() throws {
    try file.close()
  }
}
