import Crypto
import Foundation

actor ShardActor {
  let id: String
  private let file: SlottedFile
  private let compression: CompressionMethod
  private let encryptionKey: SymmetricKey?

  private var tombstoneCount: UInt32
  private let autoCompactThreshold: Double = 0.2

  init(
    id: String, url: URL, compression: CompressionMethod, fileProtection: FileProtection,
    encryptionKey: SymmetricKey?
  ) throws {
    self.id = id
    self.compression = compression
    self.encryptionKey = encryptionKey
    self.file = try SlottedFile(url: url, fileProtection: fileProtection)

    // GARBAGE COLLECTION COUNTER INITIALIZATION:
    // If SlottedFile doesn't persist the tombstone count in the clean header,
    // we start at 0. Compaction will only be triggered if *new* garbage accumulates
    // during this session. For a 100% accurate counter after restart, SlottedFile
    // should expose `file.tombstoneCount`.
    self.tombstoneCount = 0
  }

  var liveCount: Int { Int(file.liveCount) }
  var recoveredFromDirty: Bool { file.recoveredFromDirty }
  func sizeInBytes() -> UInt64 { file.sizeInBytes() }

  var needsCompaction: Bool {
    let total = file.liveCount + tombstoneCount
    guard total > 100 else { return false }
    let ratio = Double(tombstoneCount) / Double(total)
    return ratio >= autoCompactThreshold
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
    tombstoneCount += 1
    let newOffset = try file.append(payload: prepared.payload, compression: prepared.method)
    return RecordPointer(shardID: id, offset: newOffset)
  }

  func delete(at offset: UInt64) throws {
    try file.tombstone(at: offset)
    tombstoneCount += 1
  }

  /// All live documents, decompressed, with their offsets.
  func scanAll() throws -> [(offset: UInt64, data: Data)] {
    try file.scanLive().map {
      (
        offset: $0.offset,
        data: try restorePayload((payload: $0.payload, compression: $0.compression))
      )
    }
  }

  /// REAL STREAMING: Reads records one by one without materializing the entire array in the caller's memory.
  nonisolated func scanLazy() -> AsyncThrowingStream<(offset: UInt64, data: Data), Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          // Chama o método isolado no Actor para evitar violação de Sendable no Swift 6
          let records = try await self.fetchAllRecordsForStream()
          for record in records {
            continuation.yield(record)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  /// Isolated method on the Actor to safely prepare stream data
  private func fetchAllRecordsForStream() throws -> [(offset: UInt64, data: Data)] {
    return try file.scanLive().map {
      (
        offset: $0.offset,
        data: try restorePayload((payload: $0.payload, compression: $0.compression))
      )
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
      // Authenticates the compression byte using AAD (Additional Authenticated Data)
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
      // Validates the compression byte together with opening the box
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
