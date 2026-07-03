import Foundation

/// Record header flag bits.
enum RecordFlags {
  static let tombstone: UInt8 = 1 << 0
  static let gzip: UInt8 = 1 << 1
  static let lzfse: UInt8 = 1 << 2
  static let lz4: UInt8 = 1 << 3
}

/// File protection level applied to shard files (iOS only; no-op elsewhere).
public enum FileProtection: String, CaseIterable, Codable, Sendable {
  case none
  case complete
  case completeUnlessOpen
  case completeUntilFirstUserAuthentication
}

/// A single slotted shard file.
///
/// Layout:
/// ```
/// FileHeader (32 bytes):
///   magic            4 bytes  "NYU2"
///   version          u16      currently 1
///   flags            u16      bit0 = dirty
///   liveCount        u32      live (non-tombstoned) records at last clean sync
///   reserved         20 bytes
///
/// Record (repeated until EOF):
///   slotCapacity     u32      IMMUTABLE size of the slot's data area
///   payloadLength    u32      bytes of the data area actually in use
///   flags            u8       bit0 tombstone, bits1-3 compression method
///   reserved         3 bytes
///   crc32            u32      CRC-32 of the stored payload bytes
///   data             slotCapacity bytes (payload + padding)
/// ```
///
/// Design invariants (each one exists because violating it caused a real,
/// catalogued corruption bug in the previous engine):
///
/// 1. `slotCapacity` is written once and NEVER changes. Navigation always
///    advances by `16 + slotCapacity`. Deletes and shrinking updates only
///    touch `payloadLength`/`flags`, so a reader can always walk the file
///    even across tombstones. (The old format used a single `size` field for
///    both navigation and payload length; shrinking it broke the walk.)
/// 2. All integers are little-endian and assembled byte-by-byte — no
///    unaligned loads, portable to any architecture.
/// 3. The dirty flag is set (and fsync'd) before the first mutation after a
///    clean state. On open with the dirty flag set, every record's CRC is
///    verified, corrupt records are tombstoned, and a torn trailing append
///    is truncated.
///
/// `SlottedFile` is NOT thread-safe. It is owned by exactly one `ShardActor`,
/// which serializes all access through a single `FileHandle`.
final class SlottedFile {
  static let magic: [UInt8] = [0x4E, 0x59, 0x55, 0x32]  // "NYU2"
  static let version: UInt16 = 1
  static let fileHeaderSize: UInt64 = 32
  static let recordHeaderSize: UInt64 = 16
  static let dirtyFlag: UInt16 = 1 << 0
  /// Slot capacities are rounded up to this granularity so records have
  /// headroom for small in-place growth.
  static let slotGranularity: UInt32 = 32
  /// Sanity ceiling for a single record (64 MiB). Anything above this in a
  /// header is treated as corruption.
  static let maxRecordSize: UInt32 = 64 * 1024 * 1024

  struct LiveRecord {
    let offset: UInt64
    let payload: Data
    let compression: CompressionMethod
  }

  private let url: URL
  private var handle: FileHandle
  private var fileSize: UInt64
  private(set) var liveCount: UInt32 = 0

  /// Exposes the real garbage count, rebuilt during `scan()` on open.
  var tombstoneCount: UInt32 { UInt32(freeSlots.count) }

  var deadBytes: UInt64 {
    freeSlots.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
  }

  var fragmentationRatio: Double {
    let deadBytes = freeSlots.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
    let totalUsableBytes = fileSize - SlottedFile.fileHeaderSize
    guard totalUsableBytes > 0 else { return 0.0 }
    return Double(deadBytes) / Double(totalUsableBytes)
  }

  /// True when this open found the dirty flag set and ran crash recovery.
  /// Callers use this to invalidate index snapshots.
  private(set) var recoveredFromDirty = false
  private var isDirty = false
  /// Tombstoned slots available for reuse: capacity -> offsets.
  /// Kept as a flat array sorted by capacity for best-fit lookup.
  private var freeSlots: [(offset: UInt64, capacity: UInt32)] = []

  /// Static buffer for the 3 reserved bytes in the record header.
  /// Avoids allocating an array on every write.
  private static let reservedBytes = Data(count: 3)

  var path: String { url.path }

  // MARK: - Open / create

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
      // Recovery finished; persist a clean header with the recomputed count.
      try sync()
    }
  }

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

  /// Walks every slot: rebuilds liveCount and the free list.
  /// With `verifyCRC`, corrupt records are tombstoned; with `repair`, a
  /// torn trailing write is truncated.
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
          // Torn append at the tail — cut it off.
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
          // Corrupt record: neutralize it so it can never be served.
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

  private func markDirtyIfNeeded() throws {
    guard !isDirty else { return }
    var flagBytes = Data()
    Binary.append(SlottedFile.dirtyFlag, to: &flagBytes)
    try handle.seek(toOffset: 6)
    try handle.write(contentsOf: flagBytes)
    try handle.synchronize()
    isDirty = true
  }

  /// Persists liveCount and clears the dirty flag.
  func sync() throws {
    // OPTIMIZATION: If no mutation occurred, skip I/O.
    guard isDirty else { return }

    var patch = Data()
    Binary.append(UInt16(0), to: &patch)  // flags: clean
    Binary.append(liveCount, to: &patch)  // liveCount
    try handle.seek(toOffset: 6)
    try handle.write(contentsOf: patch)
    try handle.synchronize()
    isDirty = false
  }

  func close() throws {
    try sync()
    try handle.close()
  }

  // MARK: - Record operations

  /// Appends a payload (or reuses a free slot) and returns its offset.
  func append(payload: Data, compression: CompressionMethod) throws -> UInt64 {
    try markDirtyIfNeeded()
    let length = UInt32(payload.count)

    // Best-fit reuse of a tombstoned slot.
    if let index = bestFitFreeSlot(for: length) {
      let slot = freeSlots.remove(at: index)
      try writeRecord(
        at: slot.offset, capacity: slot.capacity,
        payload: payload, compression: compression
      )
      liveCount += 1
      return slot.offset
    }

    // Append at EOF with rounded-up capacity.
    let capacity = SlottedFile.roundUpCapacity(length)
    let offset = fileSize
    try writeRecord(
      at: offset, capacity: capacity, payload: payload, compression: compression, pad: true)
    fileSize = offset + SlottedFile.recordHeaderSize + UInt64(capacity)
    liveCount += 1
    return offset
  }

  static func roundUpCapacity(_ length: UInt32) -> UInt32 {
    let g = slotGranularity
    if length == 0 { return g }
    return ((length + g - 1) / g) * g
  }

  private func bestFitFreeSlot(for length: UInt32) -> Int? {
    // freeSlots is sorted by capacity ascending; find the first fit.
    var low = 0
    var high = freeSlots.count
    while low < high {
      let mid = (low + high) / 2
      if freeSlots[mid].capacity < length { low = mid + 1 } else { high = mid }
    }
    return low < freeSlots.count ? low : nil
  }

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

    // OPTIMIZATION: Use a static Data instead of allocating [0,0,0] each write.
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

  /// Reads the record at `offset`. Returns nil for tombstones.
  /// The returned payload is still compressed as stored.
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

  /// Overwrites the record in place if the new payload fits the immutable
  /// slot capacity. Returns false (without writing) if it does not fit.
  func overwrite(at offset: UInt64, payload: Data, compression: CompressionMethod) throws -> Bool {
    try handle.seek(toOffset: offset)
    guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
      head.count == Int(SlottedFile.recordHeaderSize),
      let capacity = Binary.readUInt32(head, at: 0)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short header")
    }
    // Never resurrect a deleted slot: it may already be on the free list,
    // and handing the same offset to two live records corrupts every
    // index pointing at it.
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

  /// Marks the record at `offset` as deleted. slotCapacity is untouched, so
  /// file navigation remains valid; the slot becomes reusable.
  func tombstone(at offset: UInt64) throws {
    try handle.seek(toOffset: offset)
    guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
      head.count == Int(SlottedFile.recordHeaderSize),
      let capacity = Binary.readUInt32(head, at: 0)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short header")
    }
    let flags = head[head.startIndex + 8]
    if flags & RecordFlags.tombstone != 0 { return }  // already deleted
    try markDirtyIfNeeded()
    try writeTombstoneFlag(at: offset, existingFlags: flags)
    if liveCount > 0 { liveCount -= 1 }
    // Insert into the free list keeping capacity order.
    var low = 0
    var high = freeSlots.count
    while low < high {
      let mid = (low + high) / 2
      if freeSlots[mid].capacity < capacity { low = mid + 1 } else { high = mid }
    }
    freeSlots.insert((offset: offset, capacity: capacity), at: low)
  }

  private func writeTombstoneFlag(at offset: UInt64, existingFlags: UInt8) throws {
    try handle.seek(toOffset: offset + 8)
    try handle.write(contentsOf: Data([existingFlags | RecordFlags.tombstone]))
  }

  /// Approximate on-disk size in bytes.
  func sizeInBytes() -> UInt64 { fileSize }

  struct RawRecord {
    let offset: UInt64
    let payload: Data
    let compression: CompressionMethod
  }

  /// Reads the raw payload without decompression/decryption (for zero-copy compaction).
  func readRaw(at offset: UInt64) throws -> RawRecord? {
    try handle.seek(toOffset: offset)
    guard let head = try handle.read(upToCount: Int(SlottedFile.recordHeaderSize)),
      head.count == Int(SlottedFile.recordHeaderSize),
      let capacity = Binary.readUInt32(head, at: 0),
      capacity > 0,  // Validação extra
      let payloadLength = Binary.readUInt32(head, at: 4),
      payloadLength <= capacity
    else {  // Garante que o payload não é maior que o slot
      return nil
    }
    let flags = head[head.startIndex + 8]
    let payload = try handle.read(upToCount: Int(payloadLength)) ?? Data()
    return RawRecord(
      offset: offset, payload: payload, compression: CompressionMethod(recordFlags: flags))
  }

  /// Appends a raw payload directly to the new file, bypassing compression/encryption.
  func appendRaw(payload: Data, compression: CompressionMethod) throws -> UInt64 {
    try markDirtyIfNeeded()
    let length = UInt32(payload.count)

    // Reuse free slot if possible
    if let index = bestFitFreeSlot(for: length) {
      let slot = freeSlots.remove(at: index)
      try writeRecord(
        at: slot.offset, capacity: slot.capacity, payload: payload, compression: compression)
      liveCount += 1
      return slot.offset
    }

    // Append at EOF
    let capacity = SlottedFile.roundUpCapacity(length)
    let offset = fileSize
    try writeRecord(
      at: offset, capacity: capacity, payload: payload, compression: compression, pad: true)
    fileSize = offset + SlottedFile.recordHeaderSize + UInt64(capacity)
    liveCount += 1
    return offset
  }

  /// Reads the dirty flag from the header without opening a persistent FileHandle.
  /// Used during lazy open to check if crash recovery is needed.
  static func peekDirty(url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    try? handle.seek(toOffset: 6)
    guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
    let flags = Binary.readUInt16(data, at: 0) ?? 0
    return (flags & SlottedFile.dirtyFlag) != 0
  }
}
