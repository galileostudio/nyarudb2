import Crypto
import Foundation

actor ShardActor {
  let id: String
  private let url: URL
  private var file: SlottedFile
  private let compression: CompressionMethod
  private let fileProtection: FileProtection
  private let encryptionKey: SymmetricKey?
  private let maxFragmentation: Double

  init(
    id: String, url: URL, compression: CompressionMethod, fileProtection: FileProtection,
    encryptionKey: SymmetricKey?, maxFragmentation: Double = 0.2
  ) throws {
    self.id = id
    self.url = url
    self.compression = compression
    self.fileProtection = fileProtection
    self.encryptionKey = encryptionKey
    self.maxFragmentation = maxFragmentation
    self.file = try SlottedFile(url: url, fileProtection: fileProtection)
  }

  @inlinable var liveCount: Int { Int(file.liveCount) }
  @inlinable var tombstoneCount: UInt32 { file.tombstoneCount }
  @inlinable var deadBytes: UInt64 { file.deadBytes }
  @inlinable var isEmpty: Bool { file.liveCount == 0 }

  var needsCompaction: Bool {
    let total = file.liveCount + file.tombstoneCount
    guard total > 100 else { return false }
    let ratio = Double(file.tombstoneCount) / Double(total)
    return ratio >= maxFragmentation
  }

  // MARK: - CRUD primitives

  func insert(data: Data) throws -> RecordPointer {
    let prepared = try preparePayload(data)
    let offset = try file.append(payload: prepared.payload, compression: prepared.method)
    return RecordPointer(shardID: id, offset: offset)
  }

  func read(at offset: UInt64) throws -> Data? {
    guard let record = try file.read(at: offset) else { return nil }
    return try restorePayload((payload: record.payload, compression: record.compression))
  }

  func update(at offset: UInt64, data: Data) throws -> RecordPointer {
    let prepared = try preparePayload(data)
    if try file.overwrite(at: offset, payload: prepared.payload, compression: prepared.method) {
      return RecordPointer(shardID: id, offset: offset)
    }
    try file.tombstone(at: offset)
    let newOffset = try file.append(payload: prepared.payload, compression: prepared.method)
    return RecordPointer(shardID: id, offset: newOffset)
  }

  @discardableResult
  func delete(at offset: UInt64) throws -> Bool {
    // Returns true if it was successfully tombstoned, false if it was already dead
    return try file.tombstone(at: offset)
  }

  // MARK: - Iteration

  /// Iterates over live records without materializing an array.
  internal func forEachLive(_ block: (UInt64, Data) throws -> Void) async throws {
    try file.forEachLive { liveRecord in
      let data = try restorePayload(
        (payload: liveRecord.payload, compression: liveRecord.compression))
      try block(liveRecord.offset, data)
    }
  }

  /// Iterates over raw payloads (zero-copy, no decryption/decompression).
  /// Used internally for fast compaction.
  internal func forEachLiveRaw(_ block: (UInt64, Data, CompressionMethod) throws -> Void)
    async throws
  {
    try file.forEachLive { liveRecord in
      try block(liveRecord.offset, liveRecord.payload, liveRecord.compression)
    }
  }

  /// REAL STREAMING: Reads records one by one without materializing the entire array in memory.
  nonisolated func scanLazy() -> AsyncThrowingStream<(offset: UInt64, data: Data), Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          try await self.forEachLive { offset, data in
            continuation.yield((offset: offset, data: data))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  // Pull-based batch read: the consumer drives the pace, so at most one
  // decoded batch lives in memory at a time (real backpressure, unlike the
  // previous AsyncThrowingStream whose unbounded buffer let a fast producer
  // materialize the whole shard behind a slow consumer).
  // `from == nil` starts at the beginning; a nil `nextPos` means exhausted.
  func readLiveBatch(from pos: UInt64?, maxCount: Int) throws
    -> (items: [(offset: UInt64, data: Data)], nextPos: UInt64?)
  {
    let batch = try file.readLiveBatch(
      from: pos ?? SlottedFile.fileHeaderSize, maxCount: maxCount)
    let items = try batch.records.map { record in
      (
        offset: record.offset,
        data: try restorePayload((payload: record.payload, compression: record.compression))
      )
    }
    return (items: items, nextPos: batch.nextPos)
  }

  // MARK: - Maintenance

  /// Compacts this shard file in place atomically.
  /// Uses SlottedFile directly to avoid actor reentrancy issues during copy.
  func compact() throws {
    let tempURL = url.appendingPathExtension("compact")
    try? FileManager.default.removeItem(at: tempURL)

    let tempFile = try SlottedFile(url: tempURL, fileProtection: fileProtection)

    // Zero-copy: copies raw payloads directly without decrypting/decompressing
    try file.forEachLive { liveRecord in
      _ = try tempFile.append(payload: liveRecord.payload, compression: liveRecord.compression)
    }
    try tempFile.sync()
    try tempFile.close()

    try file.close()
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    self.file = try SlottedFile(url: url, fileProtection: fileProtection)
  }

  // MARK: - Payload Preparation

  private func preparePayload(_ data: Data) throws -> (payload: Data, method: CompressionMethod) {
    var payload = data
    var method: CompressionMethod = .none

    if compression != .none {
      let stored = try Compressor.compress(data, method: compression)
      if stored.count < data.count {
        payload = stored
        method = compression
      }
    }

    if let key = encryptionKey {
      var wrapped = Data([method.byte])
      let sealedBox = try AES.GCM.seal(payload, using: key, authenticating: Data([method.byte]))
      guard let combined = sealedBox.combined else { throw NyaruError.encryptionFailed }
      wrapped.append(combined)
      return (wrapped, .none)
    }
    return (payload, method)
  }

  private func restorePayload(_ record: (payload: Data, compression: CompressionMethod)) throws
    -> Data
  {
    if let key = encryptionKey {
      guard record.payload.count > 1 else { throw NyaruError.decryptionFailed }
      let methodByte = record.payload[0]
      let encryptedData = record.payload.subdata(in: 1..<record.payload.count)

      let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
      let decrypted = try AES.GCM.open(sealedBox, using: key, authenticating: Data([methodByte]))

      if let method = CompressionMethod(byte: methodByte), method != .none {
        return try Compressor.decompress(decrypted, method: method)
      }
      return decrypted
    }
    return try Compressor.decompress(record.payload, method: record.compression)
  }

  // MARK: - Lifecycle

  func sync() throws {
    try file.sync()
  }

  func close() throws {
    try file.close()
  }
}
