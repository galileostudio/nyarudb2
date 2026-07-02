import Crypto
import Foundation

/// Owns exactly one shard file and serializes every access to it.
///
/// One actor per shard means one `FileHandle` per shard, opened once and
/// reused for the shard's lifetime. Compression and AES-GCM Encryption
/// happen here so callers only ever see raw document payloads.
actor ShardActor {
  let id: String
  private let file: SlottedFile
  private let compression: CompressionMethod
  private let encryptionKey: SymmetricKey?

  private var tombstoneCount: UInt32 = 0
  private let autoCompactThreshold: Double = 0.2

  init(
    id: String, url: URL, compression: CompressionMethod, fileProtection: FileProtection,
    encryptionKey: SymmetricKey?
  ) throws {
    self.id = id
    self.compression = compression
    self.encryptionKey = encryptionKey
    self.file = try SlottedFile(url: url, fileProtection: fileProtection)
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

  // MARK: - Payload Preparation

  /// Comprime e Criptografa o dado antes de ir pro disco.
  private func preparePayload(_ data: Data) throws -> (payload: Data, method: CompressionMethod) {
    // 1. Comprime
    var payload = data
    var method: CompressionMethod = .none

    if compression != .none {
      let stored = try Compressor.compress(data, method: compression)
      if stored.count < data.count {
        payload = stored
        method = compression
      }
    }

    // 2. Criptografa (se houver chave)
    if let key = encryptionKey {
      // Prefixa com 1 byte indicando o método de compressão original
      var wrapped = Data([method.byte])

      // AES-GCM cria um Nonce único e um Tag de autenticação automaticamente.
      // combined = [12 bytes nonce][ciphertext][16 bytes tag]
      let sealedBox = try AES.GCM.seal(payload, using: key)
      guard let combined = sealedBox.combined else {
        throw NyaruError.encryptionFailed
      }
      wrapped.append(combined)

      // Retorna o pacote criptografado. O SlottedFile não deve comprimir isso (.none)
      return (wrapped, .none)
    }

    // Se não tiver criptografia, retorna normal
    return (payload, method)
  }

  /// Descriptografa e Descomprime o dado vindo do disco.
  private func restorePayload(_ record: (payload: Data, compression: CompressionMethod)) throws
    -> Data
  {
    // Se tiver chave de criptografia, o payload está envolvido
    if let key = encryptionKey {
      guard record.payload.count > 1 else {
        throw NyaruError.decryptionFailed
      }

      // Primeiro byte é o método de compressão original
      let methodByte = record.payload[0]
      let encryptedData = record.payload.subdata(in: 1..<record.payload.count)

      // Abre a caixa AES-GCM (se a chave estiver errada ou o dado foi alterado, lança erro)
      let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
      let decrypted = try AES.GCM.open(sealedBox, using: key)

      // Descomprime se necessário
      if let method = CompressionMethod(byte: methodByte), method != .none {
        return try Compressor.decompress(decrypted, method: method)
      }
      return decrypted
    }

    // Se não tiver criptografia, apenas descomprime
    return try Compressor.decompress(record.payload, method: record.compression)
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

  func scanAll() throws -> [(offset: UInt64, data: Data)] {
    try file.scanLive().map {
      (
        offset: $0.offset,
        data: try restorePayload((payload: $0.payload, compression: $0.compression))
      )
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
