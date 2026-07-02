import Foundation

/// Owns exactly one shard file and serializes every access to it.
///
/// One actor per shard means one `FileHandle` per shard, opened once and
/// reused for the shard's lifetime (the old engine re-read the whole file
/// via `Data(contentsOf:)` on every operation and leaked descriptors under
/// concurrency). Compression/decompression happens here so callers only ever
/// see raw document payloads (JSON, MessagePack, etc).
actor ShardActor {
  let id: String
  private let file: SlottedFile
  private let compression: CompressionMethod

  // Controle de lixo para auto-compactação
  private var tombstoneCount: UInt32 = 0
  private let autoCompactThreshold: Double = 0.2  // 20% de lixo

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

  /// Verifica se a porcentagem de tombstones (lixo) ultrapassou o limite.
  /// Se sim, o CollectionCore deve disparar a compactação.
  var needsCompaction: Bool {
    let total = file.liveCount + tombstoneCount
    // Só compacta se tiver mais de 100 registros para evitar overhead em arquivos pequenos
    guard total > 100 else { return false }
    let ratio = Double(tombstoneCount) / Double(total)
    return ratio >= autoCompactThreshold
  }

  // MARK: - CRUD primitives

  /// Stores a document payload; returns a pointer to it.
  func insert(data: Data) throws -> RecordPointer {
    let stored = try Compressor.compress(data, method: compression)
    // Only keep the compressed form when it actually saves space.
    let (payload, method): (Data, CompressionMethod) =
      stored.count < data.count ? (stored, compression) : (data, .none)
    let offset = try file.append(payload: payload, compression: method)
    return RecordPointer(shardID: id, offset: offset)
  }

  /// Reads and decompresses the document payload at `offset`.
  /// Returns nil if the record was tombstoned.
  func read(at offset: UInt64) throws -> Data? {
    guard let record = try file.read(at: offset) else { return nil }
    return try Compressor.decompress(record.payload, method: record.compression)
  }

  /// Replaces the document at `offset`. If the new payload does not fit the
  /// immutable slot, the old slot is tombstoned and the payload re-appended.
  /// Returns the (possibly new) pointer.
  func update(at offset: UInt64, data: Data) throws -> RecordPointer {
    let stored = try Compressor.compress(data, method: compression)
    let (payload, method): (Data, CompressionMethod) =
      stored.count < data.count ? (stored, compression) : (data, .none)

    if try file.overwrite(at: offset, payload: payload, compression: method) {
      // Coube no slot original, não gera lixo
      return RecordPointer(shardID: id, offset: offset)
    }

    // Não coube, vira lixo (tombstone) e reescreve no final
    try file.tombstone(at: offset)
    tombstoneCount += 1
    let newOffset = try file.append(payload: payload, compression: method)
    return RecordPointer(shardID: id, offset: newOffset)
  }

  func delete(at offset: UInt64) throws {
    try file.tombstone(at: offset)
    tombstoneCount += 1
  }

  /// All live documents, decompressed, with their offsets.
  func scanAll() throws -> [(offset: UInt64, data: Data)] {
    try file.scanLive().map {
      (offset: $0.offset, data: try Compressor.decompress($0.payload, method: $0.compression))
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
