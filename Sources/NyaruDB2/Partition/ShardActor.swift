import Crypto
import Foundation

actor ShardActor {
  let id: String
  private let url: URL
  private var file: SlottedFile  // Mudou para var para permitir reabrir no compact()
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

  var liveCount: Int { Int(file.liveCount) }
  var tombstoneCount: UInt32 { file.tombstoneCount }
  var deadBytes: UInt64 { file.deadBytes }
  var recoveredFromDirty: Bool { file.recoveredFromDirty }
  func sizeInBytes() -> UInt64 { file.sizeInBytes() }

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

  func delete(at offset: UInt64) throws {
    try file.tombstone(at: offset)
  }

  // MARK: - Iteration

  /// Iterates over live records without materializing an array.
  func forEachLive(_ block: (UInt64, Data) throws -> Void) async throws {
    try file.forEachLive { liveRecord in
      let data = try restorePayload(
        (payload: liveRecord.payload, compression: liveRecord.compression))
      try block(liveRecord.offset, data)
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

  // MARK: - Maintenance

  /// Compacts this specific shard file in place.
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
  // Isolated method that reads from the old file and writes to the new one WITHOUT decompressing/decrypting
  private func copyRawRecords(from oldShard: ShardActor) async throws {
    // Iterates over live records from the old file
    try await oldShard.forEachLiveRaw { offset, rawPayload, compression in
      // Writes the payload exactly as it came from disk
      _ = try file.appendRaw(payload: rawPayload, compression: compression)
    }
  }

  // Exposes the raw iterator on the old ShardActor
  func forEachLiveRaw(_ block: (UInt64, Data, CompressionMethod) throws -> Void) async throws {
    try file.forEachLive { liveRecord in
      // Since forEachLive already returns the raw payload from SlottedFile, we just pass it through!
      try block(liveRecord.offset, liveRecord.payload, liveRecord.compression)
    }
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
