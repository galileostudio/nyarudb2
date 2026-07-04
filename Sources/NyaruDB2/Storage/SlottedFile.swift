import Foundation

/// Defines flag-bit constants used in the record header flags byte.
///
/// Bit layout:
/// - Bit 0: tombstone (record is deleted)
/// - Bit 1: gzip compression
/// - Bit 2: lzfse compression
/// - Bit 3: lz4 compression
enum RecordFlags {
  /// The record is tombstoned (deleted). The slot capacity remains valid
  /// for file navigation, but the record should not be served.
  static let tombstone: UInt8 = 1 << 0
  /// Payload is compressed with gzip.
  static let gzip: UInt8 = 1 << 1
  /// Payload is compressed with Apple LZFSE.
  static let lzfse: UInt8 = 1 << 2
  /// Payload is compressed with Apple LZ4.
  static let lz4: UInt8 = 1 << 3
}

/// Describes the file protection level applied to shard files on iOS.
///
/// This is a no-op on non-Apple platforms. On iOS, the value is mapped to
/// the corresponding `Foundation.FileProtectionType` and applied to every
/// shard file at creation time.
public enum FileProtection: String, CaseIterable, Codable, Sendable {
  /// No file protection. The file is always accessible.
  case none
  /// The file is accessible only when the device is unlocked.
  case complete
  /// The file is accessible while the device is unlocked, or after unlock
  /// until the file handle is closed.
  case completeUnlessOpen
  /// The file is accessible from the first user authentication after boot
  /// until the device is shut down.
  case completeUntilFirstUserAuthentication
}

/// A single slotted shard file that stores records with immutable slot
/// capacities, CRC-32 integrity checks, and a dirty-flag crash-recovery
/// mechanism.
///
/// **File layout:**
/// ```
/// [FileHeader] [Record] [Record] ...
///
/// FileHeader (32 bytes):
///   magic            4 bytes  0x4E 0x59 0x55 0x32  ("NYU2")
///   version          u16      currently 1
///   flags            u16      bit0 = dirty flag
///   liveCount        u32      live record count at last clean sync
///   reserved         20 bytes
///
/// Record (variable-length, min 16 + slotGranularity bytes):
///   slotCapacity     u32      IMMUTABLE size of the data area
///   payloadLength    u32      bytes of the data area actually in use
///   flags            u8       bit0=tombstone, bits1-3=compression
///   reserved         3 bytes
///   crc32            u32      CRC-32 of the stored payload bytes
///   data             slotCapacity bytes (payload + padding)
/// ```
///
/// **Design invariants** (each one exists because violating it caused a
/// real, catalogued corruption bug in the previous engine):
///
/// 1. **`slotCapacity` is immutable.** It is written once when the slot is
///    created and never changes. Navigation always advances by
///    `16 + slotCapacity`. Deletes and shrinking updates only touch
///    `payloadLength` and `flags`, so a reader can always walk the file
///    even across tombstones. (The old format used a single `size` field for
///    both navigation and payload length; shrinking it broke the walk.)
///
/// 2. **All integers are little-endian**, assembled byte by byte — no
///    unaligned loads, portable to any architecture including ARM64.
///
/// 3. **Dirty-flag crash recovery.** The dirty flag is set (and fsync'd)
///    before the first mutation after a clean state. On open with the dirty
///    flag set, every record's CRC is verified, corrupt records are
///    tombstoned, and a torn trailing append is truncated.
///
/// **Thread safety.** `SlottedFile` is NOT thread-safe. It is owned by
/// exactly one `ShardActor`, which serialises all access.
final class SlottedFile {
  /// Magic bytes identifying the file format: `"NYU2"`.
  static let magic: [UInt8] = [0x4E, 0x59, 0x55, 0x32]
  /// Current file format version.
  static let version: UInt16 = 1
  /// Size of the file header in bytes.
  static let fileHeaderSize: UInt64 = 32
  /// Size of the record header (everything before the payload data area).
  static let recordHeaderSize: UInt64 = 16
  /// Bitmask for the dirty flag in the header flags field.
  static let dirtyFlag: UInt16 = 1 << 0
  /// Slot capacities are rounded up to this granularity so records have
  /// headroom for small in-place growth without relocation.
  static let slotGranularity: UInt32 = 32
  /// Maximum allowed payload size per record (64 MiB). Anything larger in a
  /// header is treated as corruption.
  static let maxRecordSize: UInt32 = 64 * 1024 * 1024

  /// A live (non-tombstoned) record read from the file.
  struct LiveRecord {
    /// Byte offset of the record header within the file.
    let offset: UInt64
    /// The raw payload data (still compressed as stored).
    let payload: Data
    /// The compression method used when the payload was written.
    let compression: CompressionMethod
  }

  private let url: URL
  private var handle: FileHandle
  private var fileSize: UInt64
  private(set) var liveCount: UInt32 = 0

  /// The number of tombstoned (deleted) slots, rebuilt during `scan()`.
  var tombstoneCount: UInt32 { UInt32(freeSlots.count) }

  /// Total bytes consumed by tombstoned slots (available for reuse).
  var deadBytes: UInt64 {
    freeSlots.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
  }

  /// Ratio of dead bytes to total usable file bytes.
  var fragmentationRatio: Double {
    let deadBytes = freeSlots.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
    let totalUsableBytes = fileSize - SlottedFile.fileHeaderSize
    guard totalUsableBytes > 0 else { return 0.0 }
    return Double(deadBytes) / Double(totalUsableBytes)
  }

  /// Whether this open found the dirty flag set and ran crash recovery.
  /// Callers use this to decide whether index snapshots need rebuilding.
  private(set) var recoveredFromDirty = false
  private var isDirty = false
  /// Tombstoned slots available for reuse, sorted by capacity ascending.
  /// Each entry stores the offset and the immutable slot capacity.
  private var freeSlots: [(offset: UInt64, capacity: UInt32)] = []

  /// A static, pre-allocated buffer of 3 zero bytes for the reserved field
  /// in every record header. Avoids allocating a new array on every write.
  private static let reservedBytes = Data(count: 3)

  var path: String { url.path }

  // MARK: - Open / create

  /// Opens an existing shard file or creates a new one with a valid header.
  ///
  /// On creation, a file header is written with magic bytes, version 1,
  /// clean flags, and zero live count. On open, the header is validated
  /// and the file is scanned to rebuild `liveCount` and the free slot list.
  /// If the dirty flag is set, crash recovery (CRC verification + repair)
  /// is performed.
  ///
  /// - Parameters:
  ///   - url: The file URL for the shard.
  ///   - fileProtection: iOS file protection level.
  /// - Throws: `NyaruError.invalidFileFormat` if the magic or version is
  ///   wrong, `NyaruError.ioError` if the file cannot be opened.
  init(url: URL, fileProtection: FileProtection = .none) throws {
    self.url = url
    let fm = FileManager.default
    let existed = fm.fileExists(atPath: url.path)
    if !existed {
      var header = Data()
      header.append(contentsOf: SlottedFile.magic)
      Binary.append(SlottedFile.version, to: &header)
      Binary.append(UInt16(0), to: &header)  // flags: clean
      Binary.append(UInt32(0), to: &header)  // liveCount
      header.append(Data(count: 20))  // reserved
      guard fm.createFile(atPath: url.path, contents: header) else {
        throw NyaruError.ioError("Could not create file at \(url.path)")
      }
      SlottedFile.applyFileProtection(fileProtection, at: url)
    }
    do {
      self.handle = try FileHandle(forUpdating: url)
    } catch {
      throw NyaruError.ioError("Could not open \(url.path): \(error)")
    }
    let attrs = try? fm.attributesOfItem(atPath: url.path)
    self.fileSize = (attrs?[.size] as? UInt64) ?? SlottedFile.fileHeaderSize

    try validateHeaderAndScan()
  }

  /// Applies the given file protection level to the file (iOS only).
  private static func applyFileProtection(_ protection: FileProtection, at url: URL) {
    #if os(iOS) || os(tvOS) || os(watchOS)
      guard protection != .none else { return }
      let value: Foundation.FileProtectionType
      switch protection {
      case .none: return
      case .complete: value = .complete
      case .completeUnlessOpen: value = .completeUnlessOpen
      case .completeUntilFirstUserAuthentication: value = .completeUntilFirstUserAuthentication
      }
      try? FileManager.default.setAttributes(
        [.protectionKey: value], ofItemAtPath: url.path
      )
    #endif
  }

  /// Validates the file header and scans all records to rebuild state.
  ///
  /// If the dirty flag is set, scan runs with CRC verification and repair —
  /// corrupt records are tombstoned and torn trailing writes are truncated.
  private func validateHeaderAndScan() throws {
    guard fileSize >= SlottedFile.fileHeaderSize else {
      throw NyaruError.invalidFileFormat("File shorter than header: \(url.lastPathComponent)")
    }
    try handle.seek(toOffset: 0)
    guard let header = try handle.read(upToCount: Int(SlottedFile.fileHeaderSize)),
      header.count == Int(SlottedFile.fileHeaderSize)
    else {
      throw NyaruError.ioError("Could not read file header")
    }
    let magicBytes = [UInt8](header.prefix(4))
    guard magicBytes == SlottedFile.magic else {
      throw NyaruError.invalidFileFormat("Bad magic in \(url.lastPathComponent)")
    }
    guard let version = Binary.readUInt16(header, at: 4), version == SlottedFile.version else {
      throw NyaruError.invalidFileFormat("Unsupported version in \(url.lastPathComponent)")
    }
    let flags = Binary.readUInt16(header, at: 6) ?? 0
    let wasDirty = (flags & SlottedFile.dirtyFlag) != 0

    try scan(verifyCRC: wasDirty, repair: wasDirty)
    if wasDirty {
      recoveredFromDirty = true
      try sync()
    }
  }

  /// Iterates over every live record and invokes the block with a `LiveRecord`.
  ///
  /// Tombstoned records are skipped. The file is walked sequentially by
  /// advancing by `recordHeaderSize + slotCapacity` for every slot.
  ///
  /// - Parameter block: A closure called with each live record.
  /// - Throws: `NyaruError.corruptedRecord` if a record header is invalid
  ///   or a payload is truncated. Re-throws errors from the block.
  func forEachLive(_ block: (LiveRecord) throws -> Void) throws {
    var pos = SlottedFile.fileHeaderSize
    while pos + SlottedFile.recordHeaderSize <= fileSize {
      try handle.seek(toOffset: pos)
      guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
        head.count == Int(SlottedFile.recordHeaderSize),
        let capacity = Binary.readUInt32(head, at: 0),
        let payloadLength = Binary.readUInt32(head, at: 4),
        payloadLength <= capacity,
        pos + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize
      else { break }

      let flags = head[head.startIndex + 8]
      if flags & RecordFlags.tombstone == 0 {
        guard let payload = try handle.read(upToCount: Int(payloadLength)),
          payload.count == Int(payloadLength)
        else {
          throw NyaruError.corruptedRecord(offset: pos, reason: "short payload")
        }
        try block(
          LiveRecord(
            offset: pos,
            payload: payload,
            compression: CompressionMethod(recordFlags: flags)
          )
        )
      }
      pos += SlottedFile.recordHeaderSize + UInt64(capacity)
    }
  }

  /// Walks every slot in the file to rebuild `liveCount` and the free-slot
  /// list. When `verifyCRC` is true, corrupt records are tombstoned; when
  /// `repair` is true, a torn trailing append is truncated.
  ///
  /// - Parameters:
  ///   - verifyCRC: Whether to check CRC-32 on each live record and
  ///     tombstoned mismatches.
  ///   - repair: Whether to truncate a torn append at the end of the file.
  private func scan(verifyCRC: Bool, repair: Bool) throws {
    liveCount = 0
    freeSlots = []
    var pos = SlottedFile.fileHeaderSize

    while pos + SlottedFile.recordHeaderSize <= fileSize {
      try handle.seek(toOffset: pos)
      guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
        head.count == Int(SlottedFile.recordHeaderSize),
        let capacity = Binary.readUInt32(head, at: 0),
        let payloadLength = Binary.readUInt32(head, at: 4)
      else { break }

      let recordFlags = head[head.startIndex + 8]
      let storedCRC = Binary.readUInt32(head, at: 12) ?? 0

      let headerLooksValid =
        capacity > 0
        && capacity <= SlottedFile.maxRecordSize
        && payloadLength <= capacity
        && pos + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize

      if !headerLooksValid {
        if repair {
          try handle.truncate(atOffset: pos)
          fileSize = pos
        }
        break
      }

      let isTombstone = (recordFlags & RecordFlags.tombstone) != 0
      if isTombstone {
        freeSlots.append((offset: pos, capacity: capacity))
      } else if verifyCRC {
        try handle.seek(toOffset: pos + SlottedFile.recordHeaderSize)
        let payload = try handle.read(upToCount: Int(payloadLength)) ?? Data()
        if payload.count != Int(payloadLength)
          || Compressor.crc32Checksum(payload) != storedCRC
        {
          try writeTombstoneFlag(at: pos, existingFlags: recordFlags)
          freeSlots.append((offset: pos, capacity: capacity))
        } else {
          liveCount += 1
        }
      } else {
        liveCount += 1
      }
      pos += SlottedFile.recordHeaderSize + UInt64(capacity)
    }
    freeSlots.sort { $0.capacity < $1.capacity }
  }

  // MARK: - Dirty flag / sync

  /// Sets the dirty flag in the file header and immediately fsyncs it, but
  /// only when this is the first mutation since the last clean state.
  ///
  /// This is called before **every** mutation — append, overwrite, tombstone,
  /// and appendRaw. The dirty flag tells a future open that crash recovery
  /// (CRC verification + torn-write repair) is required.
  ///
  /// After all mutations are done, `sync()` must be called to clear the
  /// dirty flag and persist the updated `liveCount`. If the process crashes
  /// between `markDirtyIfNeeded()` and the next `sync()`, the dirty flag
  /// remains set and recovery runs on the next open.
  private func markDirtyIfNeeded() throws {
    guard !isDirty else { return }
    var flagBytes = Data()
    Binary.append(SlottedFile.dirtyFlag, to: &flagBytes)
    try handle.seek(toOffset: 6)
    try handle.write(contentsOf: flagBytes)
    try handle.synchronize()
    isDirty = true
  }

  /// Persists the live count and clears the dirty flag.
  ///
  /// After a successful `sync()`, a crash on a clean file requires no
  /// recovery — all records up to the last sync are consistent. If no
  /// mutations have occurred since the last sync, this is a no-op.
  func sync() throws {
    guard isDirty else { return }

    var patch = Data()
    Binary.append(UInt16(0), to: &patch)  // flags: clean
    Binary.append(liveCount, to: &patch)  // liveCount
    try handle.seek(toOffset: 6)
    try handle.write(contentsOf: patch)
    try handle.synchronize()
    isDirty = false
  }

  /// Syncs and closes the file handle.
  func close() throws {
    try sync()
    try handle.close()
  }

  // MARK: - Record operations

  /// Appends a payload to the end of the file, or reuses a tombstoned slot
  /// of sufficient capacity (best-fit).
  ///
  /// The slot capacity is rounded up to `slotGranularity` so future in-place
  /// updates can grow without relocation.
  ///
  /// - Parameters:
  ///   - payload: The payload data to store.
  ///   - compression: The compression method used on the payload.
  /// - Returns: The byte offset of the newly written record header.
  func append(payload: Data, compression: CompressionMethod) throws -> UInt64 {
    try markDirtyIfNeeded()
    let length = UInt32(payload.count)

    if let index = bestFitFreeSlot(for: length) {
      let slot = freeSlots.remove(at: index)
      try writeRecord(
        at: slot.offset, capacity: slot.capacity,
        payload: payload, compression: compression
      )
      liveCount += 1
      return slot.offset
    }

    let capacity = SlottedFile.roundUpCapacity(length)
    let offset = fileSize
    try writeRecord(
      at: offset, capacity: capacity, payload: payload, compression: compression, pad: true)
    fileSize = offset + SlottedFile.recordHeaderSize + UInt64(capacity)
    liveCount += 1
    return offset
  }

  /// Rounds up a payload length to the next multiple of `slotGranularity`.
  ///
  /// - Parameter length: The payload length.
  /// - Returns: The rounded-up slot capacity.
  static func roundUpCapacity(_ length: UInt32) -> UInt32 {
    let g = slotGranularity
    if length == 0 { return g }
    return ((length + g - 1) / g) * g
  }

  /// Finds the index of the smallest free slot that fits the given length
  /// (best-fit strategy). Returns `nil` if no slot is large enough.
  ///
  /// - Parameter length: The payload length to fit.
  /// - Returns: The index in `freeSlots`, or `nil`.
  private func bestFitFreeSlot(for length: UInt32) -> Int? {
    var low = 0
    var high = freeSlots.count
    while low < high {
      let mid = (low + high) / 2
      if freeSlots[mid].capacity < length { low = mid + 1 } else { high = mid }
    }
    return low < freeSlots.count ? low : nil
  }

  /// Writes a complete record (header + payload) at the given offset.
  ///
  /// - Parameters:
  ///   - offset: Byte offset for the record header.
  ///   - capacity: The immutable slot capacity.
  ///   - payload: The payload data (must be <= capacity).
  ///   - compression: The compression method used.
  ///   - pad: Whether to zero-fill the remaining bytes of the slot.
  /// - Precondition: `payload.count <= Int(capacity)`.
  private func writeRecord(
    at offset: UInt64,
    capacity: UInt32,
    payload: Data,
    compression: CompressionMethod,
    pad: Bool = false
  ) throws {
    precondition(payload.count <= Int(capacity), "payload exceeds slot capacity")
    var record = Data(capacity: Int(SlottedFile.recordHeaderSize) + payload.count)
    Binary.append(capacity, to: &record)
    Binary.append(UInt32(payload.count), to: &record)
    record.append(compression.flagBit)
    record.append(Self.reservedBytes)
    Binary.append(Compressor.crc32Checksum(payload), to: &record)
    record.append(payload)
    if pad {
      let padding = Int(capacity) - payload.count
      if padding > 0 { record.append(Data(count: padding)) }
    }
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: record)
  }

  /// Appends multiple records in a single I/O operation.
  ///
  /// This is an optimization for batch inserts that writes all records in one
  /// contiguous block at the end of the file. Unlike `append(payload:compression:)`,
  /// this method skips free-slot reuse and always writes sequentially to EOF,
  /// which is faster for bulk operations.
  ///
  /// The total buffer size is pre-calculated and allocated once, minimizing
  /// memory allocations and system calls. A single `seek` and `write` operation
  /// writes all records to disk.
  ///
  /// - Parameter payloads: An array of tuples containing the payload `Data` and
  ///   its associated `CompressionMethod` for each record.
  /// - Returns: An array of `UInt64` offsets where each record was written.
  /// - Throws: `NyaruError.ioError` if the write operation fails, or
  ///   `NyaruError.compressionFailed` if compression fails during header writing.
  ///
  /// - Note: This method marks the file as dirty before writing, so crash
  ///   recovery will handle any incomplete operations.
  ///
  /// - Warning: This method does NOT reuse tombstoned slots. For single
  ///   record insertions or when space reuse is desired, use `append(payload:compression:)`
  ///   instead.
  func appendBatch(payloads: [(data: Data, compression: CompressionMethod)]) throws -> [UInt64] {
    try markDirtyIfNeeded()
    if payloads.isEmpty { return [] }

    // Calculate total buffer size to allocate everything at once in memory
    var totalBufferSize = 0
    var capacities = [UInt32]()
    for (payload, _) in payloads {
      let capacity = SlottedFile.roundUpCapacity(UInt32(payload.count))
      capacities.append(capacity)
      totalBufferSize += Int(SlottedFile.recordHeaderSize) + Int(capacity)
    }

    var buffer = Data(capacity: totalBufferSize)
    var offsets = [UInt64]()
    var currentOffset = fileSize

    for (i, payloadInfo) in payloads.enumerated() {
      let payload = payloadInfo.data
      let capacity = capacities[i]

      offsets.append(currentOffset)

      // Build the header
      Binary.append(capacity, to: &buffer)
      Binary.append(UInt32(payload.count), to: &buffer)
      buffer.append(payloadInfo.compression.flagBit)
      buffer.append(Self.reservedBytes)
      Binary.append(Compressor.crc32Checksum(payload), to: &buffer)

      // Add payload and padding
      buffer.append(payload)
      let padding = Int(capacity) - payload.count
      if padding > 0 { buffer.append(Data(count: padding)) }

      currentOffset += SlottedFile.recordHeaderSize + UInt64(capacity)
    }

    // ONE seek and ONE write for all records
    try handle.seek(toOffset: fileSize)
    try handle.write(contentsOf: buffer)

    fileSize = currentOffset
    liveCount += UInt32(payloads.count)

    return offsets
  }

  /// Reads the record at the given offset and returns it as a `LiveRecord`.
  ///
  /// The returned payload is still compressed — decompression is the
  /// caller's responsibility.
  ///
  /// - Parameter offset: Byte offset of the record header.
  /// - Returns: A `LiveRecord`, or `nil` if the slot is tombstoned.
  /// - Throws: `NyaruError.corruptedRecord` if the header or CRC is invalid.
  func read(at offset: UInt64) throws -> LiveRecord? {
    guard offset + SlottedFile.recordHeaderSize <= fileSize else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "offset beyond EOF")
    }
    try handle.seek(toOffset: offset)
    guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
      head.count == Int(SlottedFile.recordHeaderSize),
      let capacity = Binary.readUInt32(head, at: 0),
      let payloadLength = Binary.readUInt32(head, at: 4)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short header")
    }
    guard payloadLength <= capacity,
      offset + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "invalid header")
    }
    let flags = head[head.startIndex + 8]
    if flags & RecordFlags.tombstone != 0 { return nil }

    let storedCRC = Binary.readUInt32(head, at: 12) ?? 0
    guard let payload = try handle.read(upToCount: Int(payloadLength)),
      payload.count == Int(payloadLength)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short payload")
    }
    guard Compressor.crc32Checksum(payload) == storedCRC else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "CRC mismatch")
    }
    return LiveRecord(
      offset: offset,
      payload: payload,
      compression: CompressionMethod(recordFlags: flags)
    )
  }

  /// Overwrites the record in place if the new payload fits the existing slot
  /// capacity. Returns `false` if the payload does not fit (no data is written).
  ///
  /// - Parameters:
  ///   - offset: Byte offset of the record to overwrite.
  ///   - payload: The new payload data.
  ///   - compression: The compression method used.
  /// - Returns: `true` if the record was overwritten in place, `false` if it
  ///   does not fit and the caller should tombstone + re-append.
  /// - Throws: `NyaruError.corruptedRecord` if the header is invalid or the
  ///   slot is already tombstoned.
  func overwrite(at offset: UInt64, payload: Data, compression: CompressionMethod) throws -> Bool {
    try handle.seek(toOffset: offset)
    guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
      head.count == Int(SlottedFile.recordHeaderSize),
      let capacity = Binary.readUInt32(head, at: 0)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short header")
    }
    let existingFlags = head[head.startIndex + 8]
    guard existingFlags & RecordFlags.tombstone == 0 else {
      throw NyaruError.corruptedRecord(
        offset: offset, reason: "attempt to overwrite a tombstoned slot"
      )
    }
    guard UInt32(payload.count) <= capacity else { return false }
    try markDirtyIfNeeded()
    try writeRecord(at: offset, capacity: capacity, payload: payload, compression: compression)
    return true
  }

  /// Tombstones the record at the given offset. The slot capacity is
  /// preserved so file navigation remains valid, and the slot becomes
  /// available for future reuse.
  ///
  /// - Parameter offset: Byte offset of the record to tombstone.
  /// - Returns: `true` if the record was live and is now tombstoned,
  ///   `false` if it was already tombstoned.
  @discardableResult
  func tombstone(at offset: UInt64) throws -> Bool {
    try handle.seek(toOffset: offset)
    guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
      head.count == Int(SlottedFile.recordHeaderSize),
      let capacity = Binary.readUInt32(head, at: 0)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short header")
    }
    let flags = head[head.startIndex + 8]
    if flags & RecordFlags.tombstone != 0 { return false }
    try markDirtyIfNeeded()
    try writeTombstoneFlag(at: offset, existingFlags: flags)
    if liveCount > 0 { liveCount -= 1 }
    var low = 0
    var high = freeSlots.count
    while low < high {
      let mid = (low + high) / 2
      if freeSlots[mid].capacity < capacity { low = mid + 1 } else { high = mid }
    }
    freeSlots.insert((offset: offset, capacity: capacity), at: low)
    return true
  }

  /// Writes the tombstone bit into an existing record header at the given
  /// offset, preserving all other flag bits.
  ///
  /// - Parameters:
  ///   - offset: Byte offset of the record header.
  ///   - existingFlags: The current flags byte value.
  private func writeTombstoneFlag(at offset: UInt64, existingFlags: UInt8) throws {
    try handle.seek(toOffset: offset + 8)
    try handle.write(contentsOf: Data([existingFlags | RecordFlags.tombstone]))
  }

  /// Returns the current file size in bytes.
  func sizeInBytes() -> UInt64 { fileSize }

  /// Reads the dirty flag from the file header without opening a persistent
  /// `FileHandle`. Used during lazy open to check if crash recovery is needed
  /// before fully loading the file.
  ///
  /// - Parameter url: The file URL.
  /// - Returns: `true` if the dirty flag is set.
  static func peekDirty(url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    try? handle.seek(toOffset: 6)
    guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
    let flags = Binary.readUInt16(data, at: 0) ?? 0
    return (flags & SlottedFile.dirtyFlag) != 0
  }

  // MARK: - Cursor-based batch reads (pull-driven streaming)

  /// A batch of live records and a cursor for resuming.
  struct LiveBatch {
    /// The records in this batch.
    let records: [LiveRecord]
    /// The file position to resume from, or `nil` if the scan reached EOF.
    let nextPos: UInt64?
  }

  /// Reads up to `maxCount` live records starting from the given position.
  ///
  /// The returned cursor is a plain file position — the caller holds no
  /// `FileHandle` state between batches. Records appended after a batch was
  /// read may or may not be observed by later batches (no snapshot isolation).
  ///
  /// - Parameters:
  ///   - pos: The byte position to start from (pass `fileHeaderSize` for the
  ///     first call).
  ///   - maxCount: The maximum number of live records to return.
  /// - Returns: A `LiveBatch` of records and the next position cursor.
  /// - Throws: `NyaruError.corruptedRecord` if a payload is truncated.
  func readLiveBatch(from pos: UInt64, maxCount: Int) throws -> LiveBatch {
    var records: [LiveRecord] = []
    var cursor = max(pos, SlottedFile.fileHeaderSize)
    while records.count < maxCount, cursor + SlottedFile.recordHeaderSize <= fileSize {
      try handle.seek(toOffset: cursor)
      guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
        head.count == Int(SlottedFile.recordHeaderSize),
        let capacity = Binary.readUInt32(head, at: 0),
        let payloadLength = Binary.readUInt32(head, at: 4),
        payloadLength <= capacity,
        cursor + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize
      else { return LiveBatch(records: records, nextPos: nil) }
      let flags = head[head.startIndex + 8]
      if flags & RecordFlags.tombstone == 0 {
        guard let payload = try handle.read(upToCount: Int(payloadLength)),
          payload.count == Int(payloadLength)
        else {
          throw NyaruError.corruptedRecord(offset: cursor, reason: "short payload")
        }
        records.append(
          LiveRecord(
            offset: cursor,
            payload: payload,
            compression: CompressionMethod(recordFlags: flags)
          )
        )
      }
      cursor += SlottedFile.recordHeaderSize + UInt64(capacity)
    }
    let atEOF = cursor + SlottedFile.recordHeaderSize > fileSize
    return LiveBatch(records: records, nextPos: atEOF ? nil : cursor)
  }
}
