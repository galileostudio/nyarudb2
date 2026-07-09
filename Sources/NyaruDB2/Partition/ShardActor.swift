import Crypto
import Foundation

/// Manages a single shard file, providing CRUD operations, iteration,
/// compaction, and transparent encryption/compression of payloads.
///
/// Each shard is backed by one `SlottedFile` instance and is owned by exactly
/// one `CollectionCore`. All file I/O is serialised through the Swift actor
/// concurrency model — multiple calls to the same `ShardActor` are executed
/// sequentially, guaranteeing thread safety without locks.
///
/// **Payload lifecycle.** When data is written, `ShardActor` applies
/// compression (if beneficial) and AES-256-GCM encryption (if a key is
/// configured). The compression method byte is packed into the first byte of
/// the encrypted payload so the method is available after decryption without
/// external metadata. On read, the reverse happens: decrypt, decompress.
actor ShardActor {
  /// The unique shard identifier, also used as the filename stem
  /// (e.g. `"default"` for `default.nyaru`).
  let id: String
  private let url: URL
  private var file: SlottedFile
  private let compression: CompressionMethod
  private let fileProtection: FileProtection
  private let encryptionKey: SymmetricKey?
  private let maxFragmentation: Double

  /// Pre-computed single-byte Data values (0–3) for AES-GCM authentication,
  /// avoiding `Data([UInt8])` allocation on every read/write.
  private static let _authData: [Data] = (0...3).map { Data([UInt8($0)]) }

  /// Whether the open of this shard found the dirty flag set and ran crash
  /// recovery. Captured at init — the backing file is swapped on compaction.
  let recoveredFromDirtyAtOpen: Bool

  /// I/O accumulated by files this actor has already retired (compaction
  /// swaps the backing `SlottedFile`).
  private var retiredBytesRead: UInt64 = 0
  private var retiredBytesWritten: UInt64 = 0

  /// Cumulative bytes read/written by this shard since open, including
  /// compaction rewrites.
  var ioBytes: (read: UInt64, written: UInt64) {
    (retiredBytesRead + file.ioBytesRead, retiredBytesWritten + file.ioBytesWritten)
  }

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
    let file = try SlottedFile(url: url, fileProtection: fileProtection)
    self.file = file
    self.recoveredFromDirtyAtOpen = file.recoveredFromDirty
    if file.recoveredFromDirty {
      NyaruLogger.log.warning(
        "Shard recovered from dirty state",
        metadata: ["shard": "\(id)", "path": "\(url.path)"])
    }
  }

  /// The total number of bytes consumed by tombstoned slots.
  @inlinable var deadBytes: UInt64 { file.deadBytes }

  /// Whether the tombstone ratio exceeds `maxFragmentation`, indicating that
  /// compaction is recommended.
  ///
  /// The ratio is computed as `tombstoneCount / (liveCount + tombstoneCount)`.
  /// Shards with fewer than 100 total records are never considered fragmented
  /// regardless of the ratio.
  var needsCompaction: Bool {
    let total = file.liveCount + file.tombstoneCount
    guard total > 100 else { return false }
    let ratio = Double(file.tombstoneCount) / Double(total)
    return ratio >= maxFragmentation
  }

  // MARK: - CRUD primitives

  /// Inserts a new record and returns a pointer pointing to it.
  ///
  /// The data is compressed (if beneficial) and encrypted (if a key is
  /// configured) before being appended to the slotted file. A tombstoned
  /// slot may be reused if one of sufficient capacity exists.
  ///
  /// - Parameter data: The raw (uncompressed, unencrypted) payload.
  /// - Returns: A `RecordPointer` that permanently identifies the record.
  /// - Throws: `NyaruError.compressionFailed` or `NyaruError.encryptionFailed`.
  func insert(data: Data) throws -> RecordPointer {
    let prepared = try preparePayload(data)
    let offset = try file.append(payload: prepared.payload, compression: prepared.method)
    return RecordPointer(shardID: id, offset: offset)
  }

  /// Processes and inserts multiple documents in a single actor hop and disk write.
  ///
  /// This method is optimized for bulk inserts by preparing all payloads in memory
  /// first (compression + encryption), then writing all records to disk in a single
  /// I/O operation. This minimizes both actor hops and system calls, providing
  /// a significant performance boost for batch operations.
  ///
  /// The workflow consists of two phases:
  ///   1. **CPU-bound phase**: Each document payload is prepared (compressed and
  ///      encrypted if configured) entirely in memory.
  ///   2. **I/O phase**: All prepared records are written to disk in a single
  ///      contiguous block using `appendBatch(payloads:)`.
  ///
  /// - Parameter datas: An array of raw document `Data` payloads to insert.
  /// - Returns: An array of `RecordPointer` values, one for each inserted document,
  ///   containing the shard ID and the offset where each record was written.
  /// - Throws: `NyaruError.encryptionFailed` or `NyaruError.compressionFailed`
  ///   if payload preparation fails, or `NyaruError.ioError` if the write fails.
  ///
  /// - Note: This method is actor-isolated and performs the entire operation
  ///   synchronously on the calling actor. For large batches, the CPU-bound
  ///   preparation phase may be significant.
  ///
  /// - SeeAlso: `preparePayload(_:)` for the compression/encryption details,
  ///   and `appendBatch(payloads:)` for the batch write implementation.
  func insertMany(datas: [Data]) throws -> [RecordPointer] {
    if datas.isEmpty { return [] }

    // Prepare all payloads in memory (CPU bound, no I/O). Compression and
    // encryption of each record are independent, so this saturates all cores.
    let preparedPayloads = try Parallel.map(datas) { data in
      let prepared = try self.preparePayload(data)
      return (data: prepared.payload, compression: prepared.method)
    }

    // Single I/O call for all records
    let offsets = try file.appendBatch(payloads: preparedPayloads)

    return offsets.map { RecordPointer(shardID: id, offset: $0) }
  }

  /// Reads the record at the given offset, returning the decrypted and
  /// decompressed payload.
  ///
  /// - Parameter offset: The byte offset of the record header.
  /// - Returns: The restored payload, or `nil` if the slot is tombstoned.
  /// - Throws: `NyaruError.decryptionFailed` or `NyaruError.decompressionFailed`.
  func read(at offset: UInt64) throws -> Data? {
    guard let record = try file.read(at: offset) else { return nil }
    return try restorePayload((payload: record.payload, compression: record.compression))
  }

  /// Updates a record in place if the new payload fits the existing slot
  /// capacity; otherwise tombstoning the old record and appending a new one.
  ///
  /// - Parameters:
  ///   - offset: The byte offset of the record to update.
  ///   - data: The new (uncompressed, unencrypted) payload.
  /// - Returns: A `RecordPointer` — the same offset if updated in place,
  ///   or a new offset if relocated.
  /// - Throws: `NyaruError.compressionFailed`, `NyaruError.encryptionFailed`,
  ///   or `NyaruError.corruptedRecord` if the slot is tombstoned.
  func update(at offset: UInt64, data: Data) throws -> RecordPointer {
    let prepared = try preparePayload(data)
    if try file.overwrite(at: offset, payload: prepared.payload, compression: prepared.method) {
      return RecordPointer(shardID: id, offset: offset)
    }
    try file.tombstone(at: offset)
    let newOffset = try file.append(payload: prepared.payload, compression: prepared.method)
    return RecordPointer(shardID: id, offset: newOffset)
  }

  /// Tombstones the record at the given offset, marking it as deleted and
  /// adding its slot to the free list for future reuse.
  ///
  /// - Parameter offset: The byte offset of the record to delete.
  /// - Returns: `true` if the record was live and is now tombstoned,
  ///   `false` if it was already dead.
  @discardableResult
  func delete(at offset: UInt64) throws -> Bool {
    return try file.tombstone(at: offset)
  }

  // MARK: - Batch reads

  func readBatch(offsets: [UInt64]) throws -> [Data] {
    // I/O phase: gather raw records serially (the file handle is not
    // shareable), then restore (decrypt + decompress) in parallel.
    var raw: [(payload: Data, compression: CompressionMethod)] = []
    raw.reserveCapacity(offsets.count)
    for offset in offsets {
      if let record = try file.read(at: offset) {
        raw.append((payload: record.payload, compression: record.compression))
      }
    }
    return try Parallel.map(raw) { try self.restorePayload($0) }
  }

  /// Reads every live record in the shard, restoring payloads in parallel.
  ///
  /// Materialises the whole shard — the right trade-off for full scans and
  /// index rebuilds that collect everything anyway, because decompression
  /// and decryption run across all cores.
  func readAllLive() throws -> [(offset: UInt64, data: Data)] {
    var raw: [(offset: UInt64, payload: Data, compression: CompressionMethod)] = []
    try file.forEachLive { liveRecord in
      raw.append((liveRecord.offset, liveRecord.payload, liveRecord.compression))
    }
    return try Parallel.map(raw) { item in
      (offset: item.offset, data: try self.restorePayload((item.payload, item.compression)))
    }
  }

  #if DEBUG
    /// Test-only fault injection for `tombstoneMany`. `.beforeWork` throws
    /// before touching the file (no tombstones land); `.afterWork` performs
    /// all tombstones and then throws (the work landed but the caller sees
    /// a failure). One-shot: the fault clears when it fires.
    enum InjectedTombstoneFault { case none, beforeWork, afterWork }
    private var injectedTombstoneFault: InjectedTombstoneFault = .none
    func injectTombstoneManyFault(_ fault: InjectedTombstoneFault) {
      injectedTombstoneFault = fault
    }
  #endif

  /// Tombstones multiple records in a single actor hop without reading their
  /// payloads. Used when the caller already knows each document's index keys.
  ///
  /// - Parameter offsets: The record offsets to delete.
  /// - Returns: Whether each record was live and is now tombstoned, in
  ///   input order.
  func tombstoneMany(offsets: [UInt64]) throws -> [Bool] {
    #if DEBUG
      if injectedTombstoneFault == .beforeWork {
        injectedTombstoneFault = .none
        throw NyaruError.ioError("injected tombstoneMany fault (before work)")
      }
    #endif
    var out: [Bool] = []
    out.reserveCapacity(offsets.count)
    for offset in offsets {
      out.append(try file.tombstone(at: offset))
    }
    #if DEBUG
      if injectedTombstoneFault == .afterWork {
        injectedTombstoneFault = .none
        throw NyaruError.ioError("injected tombstoneMany fault (after work)")
      }
    #endif
    return out
  }

  /// Reads and tombstones multiple records in a single actor hop.
  ///
  /// - Parameter offsets: The record offsets to delete.
  /// - Returns: The restored payload for each offset that was live (`nil`
  ///   for offsets that were already dead), in input order.
  func deleteMany(offsets: [UInt64]) throws -> [Data?] {
    var raw: [(payload: Data, compression: CompressionMethod)?] = []
    raw.reserveCapacity(offsets.count)
    for offset in offsets {
      if let record = try file.read(at: offset) {
        raw.append((record.payload, record.compression))
        try file.tombstone(at: offset)
      } else {
        raw.append(nil)
      }
    }
    return try Parallel.map(raw) { item in
      try item.map { try self.restorePayload($0) }
    }
  }

  /// Reads a batch of live records starting at the given position.
  ///
  /// The consumer drives the pace — at most one decoded batch is kept in
  /// memory at a time. Pass `nil` for `pos` to start from the beginning;
  /// a `nil` `nextPos` in the return value signals that the shard is
  /// exhausted.
  ///
  /// - Parameters:
  ///   - pos: The position to resume from, or `nil` to start at the beginning.
  ///   - maxCount: The maximum number of records to return.
  /// - Returns: A tuple of decoded items and the next position cursor.
  /// - Throws: `NyaruError.corruptedRecord` if a record header is invalid.
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

  /// Compacts the shard file atomically by copying only live records to a
  /// temporary file, then swapping them.
  ///
  /// The compaction process:
  /// 1. Writes all live records (raw, without decryption/recompression) to a
  ///    `.compact` temp file.
  /// 2. Syncs and closes the temp file.
  /// 3. Closes the current file and atomically replaces it with the temp file.
  /// 4. Re-opens the new file.
  ///
  /// This is a blocking operation (synchronous I/O inside the actor) but is
  /// designed to be fast because it avoids decrypting and re-encrypting every
  /// record — the compressed payloads are copied as-is.
  ///
  /// - Returns: A map of old record offset → new record offset for every live
  ///   record, so callers can remap index pointers without re-reading or
  ///   re-parsing any document.
  func compact() throws -> [UInt64: UInt64] {
    try compact(dropping: []).mapping
  }

  /// Compacts the shard while also dropping the records at `drop` (used by
  /// large-fraction batch deletes: the few survivors are rewritten and the
  /// deleted records are simply never copied — no per-record tombstone write).
  ///
  /// The dropped records are absent from the returned survivor map, so a
  /// single `OrderedIndex.compactRemap` remaps survivors and drops the deleted
  /// pointers for free, without needing their index keys.
  ///
  /// - Parameter drop: File offsets of records to omit from the rewrite.
  /// - Returns: The survivor old→new offset map and the number of live records
  ///   actually dropped (`liveBefore − survivors`).
  func compact(dropping drop: Set<UInt64>) throws -> (mapping: [UInt64: UInt64], dropped: Int) {
    let oldFileSize = file.sizeInBytes()
    let liveBefore = file.liveCount
    let tombstonesBefore = file.tombstoneCount

    let tempURL = url.appendingPathExtension("compact")
    try? FileManager.default.removeItem(at: tempURL)

    let tempFile = try SlottedFile(url: tempURL, fileProtection: fileProtection)

    // Stream live records into the temp file in bounded chunks. Payload
    // slices alias the scan buffer (zero copy) and are flushed before the
    // chunk grows past a few MiB, so peak memory stays at roughly the file
    // size plus one chunk instead of three full copies of every payload.
    // The stored CRCs travel along so nothing is re-checksummed.
    let flushThreshold = 4 << 20
    var oldOffsets: [UInt64] = []
    var newOffsets: [UInt64] = []
    var chunk: [(data: Data, compression: CompressionMethod)] = []
    var chunkCRCs: [UInt32] = []
    var chunkBytes = 0
    try file.forEachLiveSlice { liveRecord in
      if drop.contains(liveRecord.offset) { return }  // deleted — never copied
      oldOffsets.append(liveRecord.offset)
      chunk.append((data: liveRecord.payload, compression: liveRecord.compression))
      chunkCRCs.append(liveRecord.crc)
      chunkBytes += liveRecord.payload.count
      if chunkBytes >= flushThreshold {
        newOffsets.append(
          contentsOf: try tempFile.appendBatch(payloads: chunk, precomputedCRCs: chunkCRCs))
        chunk.removeAll(keepingCapacity: true)
        chunkCRCs.removeAll(keepingCapacity: true)
        chunkBytes = 0
      }
    }
    if !chunk.isEmpty {
      newOffsets.append(
        contentsOf: try tempFile.appendBatch(payloads: chunk, precomputedCRCs: chunkCRCs))
      chunk.removeAll()
      chunkCRCs.removeAll()
    }
    let mapping = Dictionary(uniqueKeysWithValues: zip(oldOffsets, newOffsets))
    let newSize = tempFile.sizeInBytes()

    try tempFile.sync()
    // Both files retire here — bank their I/O counters before the swap.
    retiredBytesRead += file.ioBytesRead + tempFile.ioBytesRead
    retiredBytesWritten += file.ioBytesWritten + tempFile.ioBytesWritten
    try tempFile.close()
    try file.close()

    _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    // The temp file's sidecar is now orphaned; the adopting open below writes
    // a fresh one for the final path.
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + ".state"))

    // The compacted file's state is fully known — adopt it without rescanning.
    self.file = try SlottedFile(
      adoptingCleanFileAt: url, expectedSize: newSize, liveCount: UInt32(oldOffsets.count))
    let saved = oldFileSize > newSize ? Int64(oldFileSize) - Int64(newSize) : 0
    NyaruLogger.log.debug(
      "Shard compacted",
      metadata: [
        "shard": "\(id)",
        "liveBefore": "\(liveBefore)",
        "tombstonesBefore": "\(tombstonesBefore)",
        "liveAfter": "\(file.liveCount)",
        "sizeBefore": "\(oldFileSize)",
        "sizeAfter": "\(newSize)",
        "bytesSaved": "\(saved)",
      ])
    return (mapping, Int(liveBefore) - oldOffsets.count)
  }

  // MARK: - Payload Preparation

  /// Prepares a payload for storage by optionally compressing and encrypting it.
  ///
  /// Compression is applied only if the compressed result is smaller than the
  /// original. When encryption is enabled, the compression method byte is
  /// prepended to the compressed payload and the whole block is encrypted with
  /// AES-GCM, authenticated with the method byte.
  ///
  /// - Parameter data: The raw uncompressed, unencrypted payload.
  /// - Returns: A tuple of the prepared payload and the compression method
  ///   used (`.none` if compression was not beneficial or encryption was
  ///   applied, since encryption outputs are incompressible).
  /// - Throws: `NyaruError.compressionFailed` or `NyaruError.encryptionFailed`.
  nonisolated private func preparePayload(_ data: Data) throws
    -> (payload: Data, method: CompressionMethod)
  {
    var payload = data
    var method: CompressionMethod = .none

    if compression != .none && data.count >= 80 {
      let stored = try Compressor.compress(data, method: compression)
      if stored.count < data.count {
        payload = stored
        method = compression
      }
    }

    if let key = encryptionKey {
      var wrapped = Data([method.byte])
      let sealedBox = try AES.GCM.seal(payload, using: key, authenticating: Self._authData[Int(method.byte)])
      guard let combined = sealedBox.combined else { throw NyaruError.encryptionFailed }
      wrapped.append(combined)
      return (wrapped, .none)
    }
    return (payload, method)
  }

  /// Restores a payload that was stored with `preparePayload`.
  ///
  /// If the shard is encrypted, the first byte contains the compression method.
  /// The rest is AES-GCM authenticated data. After decryption, the compression
  /// method byte is used to determine whether further decompression is needed.
  ///
  /// - Parameter record: A tuple of the stored payload and its on-disk
  ///   compression method (which is `.none` for encrypted records).
  /// - Returns: The original uncompressed, unencrypted data.
  /// - Throws: `NyaruError.decryptionFailed` or `NyaruError.decompressionFailed`.
  nonisolated private func restorePayload(
    _ record: (payload: Data, compression: CompressionMethod)
  ) throws -> Data {
    if let key = encryptionKey {
      guard record.payload.count > 1 else { throw NyaruError.decryptionFailed }
      let methodByte = record.payload[0]
      // slice without copy — SealedBox(combined:) accepts DataProtocol
      let sealedBox = try AES.GCM.SealedBox(combined: record.payload.dropFirst())
      let decrypted = try AES.GCM.open(sealedBox, using: key, authenticating: Self._authData[Int(methodByte)])

      if let method = CompressionMethod(byte: methodByte), method != .none {
        return try Compressor.decompress(decrypted, method: method)
      }
      return decrypted
    }
    return try Compressor.decompress(record.payload, method: record.compression)
  }

  // MARK: - Lifecycle

  /// Flushes the shard's dirty flag and live count to disk.
  func sync() throws {
    try file.sync()
  }

  /// Syncs and closes the underlying file handle.
  func close() throws {
    try file.close()
  }
}
