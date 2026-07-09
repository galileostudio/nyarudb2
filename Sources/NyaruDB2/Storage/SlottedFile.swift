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
    /// The CRC-32 stored in the record header. Carrying it along lets
    /// compaction rewrite records without recomputing checksums.
    let crc: UInt32
  }

  private let url: URL
  private var handle: RawFile
  private var fileSize: UInt64
  private(set) var liveCount: UInt32 = 0

  /// The number of tombstoned (deleted) slots, rebuilt during `scan()`.
  var tombstoneCount: UInt32 { UInt32(freeSlots.count) }

  /// Total bytes consumed by tombstoned slots (available for reuse).
  var deadBytes: UInt64 { _deadBytes }

  /// Ratio of dead bytes to total usable file bytes.
  var fragmentationRatio: Double {
    let totalUsableBytes = fileSize - SlottedFile.fileHeaderSize
    guard totalUsableBytes > 0 else { return 0.0 }
    return Double(_deadBytes) / Double(totalUsableBytes)
  }

  /// Whether this open found the dirty flag set and ran crash recovery.
  /// Callers use this to decide whether index snapshots need rebuilding.
  private(set) var recoveredFromDirty = false

  /// Cumulative I/O through this file's descriptor, for `CollectionMetrics`.
  var ioBytesRead: UInt64 { handle.bytesRead }
  var ioBytesWritten: UInt64 { handle.bytesWritten }
  private var isDirty = false
  /// Tombstoned slots available for reuse, sorted by capacity ascending.
  /// Each entry stores the offset and the immutable slot capacity.
  private var freeSlots: [(offset: UInt64, capacity: UInt32)] = []
  /// Cached sum of all free-slot capacities; updated incrementally to avoid O(N) reduce.
  private var _deadBytes: UInt64 = 0

  /// A static, pre-allocated buffer of 3 zero bytes for the reserved field
  /// in every record header. Avoids allocating a new array on every write.
  private static let reservedBytes = Data(count: 3)

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
    self.handle = try RawFile(path: url.path)
    self.fileSize = try handle.size()

    try validateHeaderAndScan()
  }

  /// Opens a freshly compacted file whose state is fully known, skipping the
  /// full-file scan entirely: zero free slots, a clean dirty flag, and the
  /// given live count. Falls back to a defensive full validation if the file
  /// size on disk does not match what the compaction produced.
  ///
  /// - Parameters:
  ///   - url: The file URL (already swapped into place).
  ///   - expectedSize: The size the compacted file must have.
  ///   - liveCount: The number of live records written during compaction.
  init(adoptingCleanFileAt url: URL, expectedSize: UInt64, liveCount: UInt32) throws {
    self.url = url
    self.handle = try RawFile(path: url.path)
    self.fileSize = try handle.size()
    guard fileSize == expectedSize else {
      try validateHeaderAndScan()
      return
    }
    self.liveCount = liveCount
    freeSlots = []
    _deadBytes = 0
    writeStateSidecar()
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
    let header = try handle.read(count: Int(SlottedFile.fileHeaderSize), at: 0)
    guard header.count == Int(SlottedFile.fileHeaderSize) else {
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

    if wasDirty {
      // Crash recovery: never trust the sidecar — verify everything.
      NyaruLogger.log.warning(
        "Starting crash recovery for shard",
        metadata: ["path": "\(url.path)"])
      try scan(verifyCRC: true, repair: true)
      recoveredFromDirty = true
      try sync()
      NyaruLogger.log.info(
        "Crash recovery complete",
        metadata: [
          "path": "\(url.path)",
          "liveCount": "\(self.liveCount)",
          "tombstoneCount": "\(tombstoneCount)",
        ])
    } else if !loadStateSidecar() {
      NyaruLogger.log.debug(
        "Sidecar missing or invalid, scanning shard",
        metadata: ["path": "\(url.path)"])
      try scan(verifyCRC: false, repair: false)
      // Persist the state so the next clean open skips the scan.
      writeStateSidecar()
    }
  }

  // MARK: - Clean-state sidecar

  /// The sidecar persists the scan-derived state (live count, free slots) at
  /// clean-sync time, so a clean open avoids reading the entire data region —
  /// O(1) startup regardless of file size. It is trusted only when the dirty
  /// flag is clear AND the recorded file size matches the file on disk; any
  /// crash (dirty flag set) or mismatch falls back to a full scan, so a stale
  /// or corrupt sidecar can never inject wrong state.
  private var stateURL: URL { URL(fileURLWithPath: url.path + ".state") }
  /// Magic bytes for the sidecar format: `"NYS1"`.
  private static let stateMagic: [UInt8] = [0x4E, 0x59, 0x53, 0x31]

  /// Best-effort write of the sidecar — failure just means the next open
  /// falls back to scanning.
  ///
  /// Format v2 ends with a CRC-32 of everything before it. The structural
  /// checks (magic, version, file size, exact byte count) catch truncation
  /// and staleness but not bit rot — and a corrupt slot list is not a
  /// statistics bug: it would hand a live record's slot to best-fit reuse.
  private func writeStateSidecar() {
    var out = Data()
    out.append(contentsOf: Self.stateMagic)
    Binary.append(UInt16(2), to: &out)  // version
    Binary.append(fileSize, to: &out)
    Binary.append(liveCount, to: &out)
    Binary.append(UInt32(freeSlots.count), to: &out)
    for slot in freeSlots {
      Binary.append(slot.offset, to: &out)
      Binary.append(slot.capacity, to: &out)
    }
    Binary.append(Compressor.crc32Checksum(out), to: &out)
    try? out.write(to: stateURL, options: .atomic)
  }

  /// Attempts to adopt the sidecar state. Returns `false` (caller must scan)
  /// when the sidecar is missing, malformed, from another version, fails its
  /// content CRC, or does not match the current file size. Version 1
  /// sidecars (no CRC) are rejected — the open scans once and rewrites v2.
  private func loadStateSidecar() -> Bool {
    guard let data = try? Data(contentsOf: stateURL) else { return false }
    let slotsStart = 22
    guard data.count >= slotsStart + 4,
      [UInt8](data.prefix(4)) == Self.stateMagic,
      Binary.readUInt16(data, at: 4) == 2,
      Binary.readUInt64(data, at: 6) == fileSize,
      let live = Binary.readUInt32(data, at: 14),
      let slotCount = Binary.readUInt32(data, at: 18),
      data.count == slotsStart + Int(slotCount) * 12 + 4,
      let storedCRC = Binary.readUInt32(data, at: data.count - 4),
      Compressor.crc32Checksum(data.prefix(data.count - 4)) == storedCRC
    else { return false }

    var slots: [(offset: UInt64, capacity: UInt32)] = []
    slots.reserveCapacity(Int(slotCount))
    var dead: UInt64 = 0
    for i in 0..<Int(slotCount) {
      let base = slotsStart + i * 12
      guard let slotOffset = Binary.readUInt64(data, at: base),
        let slotCapacity = Binary.readUInt32(data, at: base + 8)
      else { return false }
      slots.append((offset: slotOffset, capacity: slotCapacity))
      dead += UInt64(slotCapacity)
    }
    liveCount = live
    freeSlots = slots
    _deadBytes = dead
    return true
  }

  /// Iterates over every live record and invokes the block with a `LiveRecord`.
  ///
  /// Tombstoned records are skipped. The file is walked sequentially by
  /// advancing by `recordHeaderSize + slotCapacity` for every slot. Payloads
  /// are copied out of the scan buffer, so they are safe to retain.
  ///
  /// - Parameter block: A closure called with each live record.
  /// - Throws: `NyaruError.corruptedRecord` if a record header is invalid
  ///   or a payload is truncated. Re-throws errors from the block.
  func forEachLive(_ block: (LiveRecord) throws -> Void) throws {
    try forEachLive(copyingPayloads: true, block)
  }

  /// Zero-copy variant of `forEachLive`: payloads are slices of the scan
  /// window.
  ///
  /// **Retention trap.** A `Data` slice keeps its parent buffer alive, so
  /// retaining a payload past the callback pins its whole scan window
  /// (`scanChunkSize`) in memory. Use this only when payloads are consumed
  /// promptly (written out, parsed) — compaction's bounded chunk flush is
  /// the intended shape — and use `forEachLive` when payloads outlive the
  /// iteration.
  func forEachLiveSlice(_ block: (LiveRecord) throws -> Void) throws {
    try forEachLive(copyingPayloads: false, block)
  }

  private func forEachLive(copyingPayloads: Bool, _ block: (LiveRecord) throws -> Void) throws {
    _ = try walkSlots { record, payload in
      guard record.flags & RecordFlags.tombstone == 0 else { return }
      let bytes = try payload()
      try block(
        LiveRecord(
          offset: record.offset,
          payload: copyingPayloads ? Data(bytes) : bytes,
          compression: CompressionMethod(recordFlags: record.flags),
          crc: record.crc
        )
      )
    }
  }

  /// The sliding-window size for whole-file walks. Bounds the resident
  /// memory of scans and recovery at O(window) instead of O(file) — a 1 GB
  /// shard no longer pins 1 GB to be iterated.
  static let scanChunkSize = 4 << 20

  /// A record slot yielded by `walkSlots`.
  private struct WalkedSlot {
    let offset: UInt64
    let capacity: UInt32
    let payloadLength: UInt32
    let flags: UInt8
    let crc: UInt32
  }

  /// Walks every record slot using a sliding window of `scanChunkSize`
  /// bytes, invoking `body` with the parsed header and a lazy payload
  /// accessor. Records that straddle the window boundary are refilled from
  /// the record's offset; records larger than the window are read directly.
  /// Tombstoned slots never touch payload bytes.
  ///
  /// The payload accessor returns a slice of the current window (zero copy)
  /// or a fresh buffer for straddling records — either way it is only valid
  /// during the callback unless copied.
  ///
  /// - Returns: The offset of the first slot with an invalid header (a torn
  ///   append or trailing garbage — the caller decides whether to truncate),
  ///   or `nil` when the walk reached the end of the file cleanly.
  private func walkSlots(
    _ body: (WalkedSlot, _ payload: () throws -> Data) throws -> Void
  ) throws -> UInt64? {
    guard fileSize > SlottedFile.fileHeaderSize else { return nil }
    let headerSize = Int(SlottedFile.recordHeaderSize)
    var pos = SlottedFile.fileHeaderSize
    var window = Data()
    var windowStart = pos

    func refill(at offset: UInt64) throws {
      window = try handle.read(count: SlottedFile.scanChunkSize, at: offset)
      windowStart = offset
    }
    try refill(at: pos)

    while pos < fileSize {
      var rel = Int(pos - windowStart)
      if rel + headerSize > window.count {
        try refill(at: pos)
        rel = 0
        // Fewer than headerSize bytes remain on disk: torn trailing bytes.
        if window.count < headerSize { return pos }
      }

      guard let capacity = Binary.readUInt32(window, at: rel),
        let payloadLength = Binary.readUInt32(window, at: rel + 4),
        capacity > 0,
        capacity <= SlottedFile.maxRecordSize,
        payloadLength <= capacity,
        pos + UInt64(headerSize) + UInt64(capacity) <= fileSize
      else { return pos }

      let slot = WalkedSlot(
        offset: pos,
        capacity: capacity,
        payloadLength: payloadLength,
        flags: window[window.startIndex + rel + 8],
        crc: Binary.readUInt32(window, at: rel + 12) ?? 0
      )

      let payloadEndRel = rel + headerSize + Int(payloadLength)
      if payloadEndRel <= window.count {
        let w = window
        let start = w.startIndex + rel + headerSize
        try body(slot) { w[start..<(w.startIndex + payloadEndRel)] }
      } else {
        // The payload crosses the window boundary (or exceeds the window):
        // one direct read of exactly the payload, deferred until asked for.
        let payloadOffset = pos + UInt64(headerSize)
        try body(slot) {
          let data = try handle.read(count: Int(payloadLength), at: payloadOffset)
          guard data.count == Int(payloadLength) else {
            throw NyaruError.corruptedRecord(
              offset: slot.offset, reason: "payload truncated mid-record")
          }
          return data
        }
      }
      pos += UInt64(headerSize) + UInt64(capacity)
    }
    return nil
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

    guard fileSize > SlottedFile.fileHeaderSize else {
      _deadBytes = 0
      return
    }

    // Chunked walk: recovery of an arbitrarily large shard runs in O(window)
    // memory, and CRC verification checksums window slices without copying.
    let tornOffset = try walkSlots { slot, payload in
      if slot.flags & RecordFlags.tombstone != 0 {
        freeSlots.append((offset: slot.offset, capacity: slot.capacity))
      } else if verifyCRC {
        if Compressor.crc32Checksum(try payload()) != slot.crc {
          try writeTombstoneFlag(at: slot.offset, existingFlags: slot.flags)
          freeSlots.append((offset: slot.offset, capacity: slot.capacity))
        } else {
          liveCount += 1
        }
      } else {
        liveCount += 1
      }
    }
    // An invalid header mid-file is a torn append (or trailing garbage —
    // which, left in place, would hide every future append behind it).
    if let tornOffset, repair {
      try handle.truncate(to: tornOffset)
      fileSize = tornOffset
    }
    freeSlots.sort { $0.capacity < $1.capacity }
    _deadBytes = freeSlots.reduce(UInt64(0)) { $0 + UInt64($1.capacity) }
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
    try handle.write(flagBytes, at: 6)
    try handle.sync()
    isDirty = true
  }

  /// Persists the live count and clears the dirty flag.
  ///
  /// After a successful `sync()`, a crash on a clean file requires no
  /// recovery — all records up to the last sync are consistent. If no
  /// mutations have occurred since the last sync, this is a no-op.
  func sync() throws {
    guard isDirty else { return }

    // Write the sidecar BEFORE clearing the dirty flag: it is only ever
    // trusted on a clean open, so a crash in between leaves the flag set and
    // forces a full recovery scan.
    writeStateSidecar()

    var patch = Data()
    Binary.append(UInt16(0), to: &patch)  // flags: clean
    Binary.append(liveCount, to: &patch)  // liveCount
    try handle.write(patch, at: 6)
    try handle.sync()
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

    while let index = bestFitFreeSlot(for: length) {
      let slot = freeSlots.remove(at: index)
      _deadBytes -= min(_deadBytes, UInt64(slot.capacity))
      guard isReusableSlot(slot) else {
        // The on-disk header disagrees with the free list (corrupt or stale
        // state) — never overwrite. The slot is forgotten; if it really was
        // dead, the next compaction reclaims it.
        continue
      }
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

  /// Defence in depth for free-slot reuse: a corrupt sidecar (or any bug in
  /// free-list bookkeeping) could list a LIVE record's slot as free, and
  /// best-fit would silently overwrite it — data loss, not a statistics
  /// error. One 16-byte pread confirms the on-disk header agrees with the
  /// free list — tombstoned, same capacity — before the slot is written over.
  private func isReusableSlot(_ slot: (offset: UInt64, capacity: UInt32)) -> Bool {
    let headerSize = Int(SlottedFile.recordHeaderSize)
    guard let header = try? handle.read(count: headerSize, at: slot.offset),
      header.count == headerSize,
      Binary.readUInt32(header, at: 0) == slot.capacity,
      header[header.startIndex + 8] & RecordFlags.tombstone != 0
    else { return false }
    return true
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
    try handle.write(record, at: offset)
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
  func appendBatch(
    payloads: [(data: Data, compression: CompressionMethod)],
    precomputedCRCs: [UInt32]? = nil
  ) throws -> [UInt64] {
    try markDirtyIfNeeded()
    if payloads.isEmpty { return [] }

    // CRCs are either supplied by the caller (compaction reuses the stored
    // ones) or computed here across all cores.
    let crcs = precomputedCRCs ?? Parallel.map(payloads) { Compressor.crc32Checksum($0.data) }

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
      Binary.append(crcs[i], to: &buffer)

      // Add payload and padding
      buffer.append(payload)
      let padding = Int(capacity) - payload.count
      if padding > 0 { buffer.append(Data(count: padding)) }

      currentOffset += SlottedFile.recordHeaderSize + UInt64(capacity)
    }

    // ONE write for all records
    try handle.write(buffer, at: fileSize)

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
    let headerSize = Int(SlottedFile.recordHeaderSize)

    // Speculative read: header plus up to ~4 KiB of payload in ONE syscall.
    // Most records fit entirely, making a point read a single pread; larger
    // payloads fall back to one extra read for the remainder.
    let speculative = Int(min(UInt64(4096), fileSize - offset))
    let chunk = try handle.read(count: speculative, at: offset)
    guard chunk.count >= headerSize,
      let capacity = Binary.readUInt32(chunk, at: 0),
      let payloadLength = Binary.readUInt32(chunk, at: 4)
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "short header")
    }
    guard payloadLength <= capacity,
      offset + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "invalid header")
    }
    let flags = chunk[chunk.startIndex + 8]
    if flags & RecordFlags.tombstone != 0 { return nil }

    let storedCRC = Binary.readUInt32(chunk, at: 12) ?? 0
    let payloadEnd = headerSize + Int(payloadLength)
    let payload: Data
    if payloadEnd <= chunk.count {
      payload = Data(chunk[chunk.startIndex + headerSize..<chunk.startIndex + payloadEnd])
    } else {
      let have = chunk.count - headerSize
      let rest = try handle.read(
        count: Int(payloadLength) - have, at: offset + UInt64(chunk.count))
      guard rest.count == Int(payloadLength) - have else {
        throw NyaruError.corruptedRecord(offset: offset, reason: "short payload")
      }
      var assembled = Data(capacity: Int(payloadLength))
      assembled.append(chunk[(chunk.startIndex + headerSize)...])
      assembled.append(rest)
      payload = assembled
    }
    guard Compressor.crc32Checksum(payload) == storedCRC else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "CRC mismatch")
    }
    return LiveRecord(
      offset: offset,
      payload: payload,
      compression: CompressionMethod(recordFlags: flags),
      crc: storedCRC
    )
  }

  /// The largest byte span coalesced into a single pread by
  /// `readRecords(atSortedOffsets:)`. Offsets farther apart than this start a
  /// fresh read, so a sparse pointer set never forces one huge allocation.
  static let maxCoalescedReadSpan: UInt64 = 8 * 1024 * 1024

  /// Speculative bytes read past the last offset in a coalesced span, so the
  /// final record's payload usually lands in the buffer without a second read.
  private static let coalescedReadTail: UInt64 = 4096

  /// Reads the records at the given offsets, coalescing physically-adjacent
  /// offsets into shared `pread` calls.
  ///
  /// An index range scan resolves to a run of contiguous offsets; reading
  /// them one `read(at:)` at a time issues one syscall (and one ~4 KiB
  /// speculative allocation) per record. This groups offsets that fall within
  /// `maxCoalescedReadSpan` of each other into a single window read and slices
  /// each record out of it. Records whose payload straddles the window tail
  /// fall back to a direct `read(at:)`.
  ///
  /// - Parameter offsets: Record header offsets, **sorted ascending**.
  /// - Returns: One entry per input offset, in order. A `nil` entry means the
  ///   slot was tombstoned — identical to `read(at:)` returning `nil`.
  /// - Throws: `NyaruError.corruptedRecord` on the same conditions as
  ///   `read(at:)` (offset beyond EOF, invalid header, CRC mismatch).
  func readRecords(atSortedOffsets offsets: [UInt64]) throws -> [LiveRecord?] {
    var out = [LiveRecord?](repeating: nil, count: offsets.count)
    var i = 0
    while i < offsets.count {
      let spanStart = offsets[i]
      guard spanStart + SlottedFile.recordHeaderSize <= fileSize else {
        throw NyaruError.corruptedRecord(offset: spanStart, reason: "offset beyond EOF")
      }
      // Extend the span while the next offset stays within one window.
      var j = i
      while j + 1 < offsets.count,
        offsets[j + 1] - spanStart <= SlottedFile.maxCoalescedReadSpan
      {
        j += 1
      }
      let windowEnd = min(fileSize, offsets[j] + SlottedFile.coalescedReadTail)
      let window = try handle.read(count: Int(windowEnd - spanStart), at: spanStart)
      for k in i...j {
        out[k] = try parseRecord(at: offsets[k], from: window, windowStart: spanStart)
      }
      i = j + 1
    }
    return out
  }

  /// Parses the record whose header begins at `offset` from bytes already
  /// held in `window` (which starts at file position `windowStart`). When the
  /// header or payload is not fully materialised in the window — the record
  /// straddles the window tail — it falls back to a self-contained
  /// `read(at:)` for that single record.
  ///
  /// The validation and CRC check mirror `read(at:)` exactly, so both paths
  /// accept and reject the same records.
  private func parseRecord(at offset: UInt64, from window: Data, windowStart: UInt64) throws
    -> LiveRecord?
  {
    let headerSize = Int(SlottedFile.recordHeaderSize)
    let rel = Int(offset - windowStart)
    guard rel + headerSize <= window.count,
      let capacity = Binary.readUInt32(window, at: rel),
      let payloadLength = Binary.readUInt32(window, at: rel + 4)
    else {
      // Header not fully in the window: read this record on its own.
      return try read(at: offset)
    }
    guard payloadLength <= capacity,
      offset + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize
    else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "invalid header")
    }
    let flags = window[window.startIndex + rel + 8]
    if flags & RecordFlags.tombstone != 0 { return nil }

    let payloadStart = rel + headerSize
    let payloadEnd = payloadStart + Int(payloadLength)
    guard payloadEnd <= window.count else {
      // Payload straddles the window tail: read this record on its own.
      return try read(at: offset)
    }
    let storedCRC = Binary.readUInt32(window, at: rel + 12) ?? 0
    let payload = Data(
      window[window.startIndex + payloadStart..<window.startIndex + payloadEnd])
    guard Compressor.crc32Checksum(payload) == storedCRC else {
      throw NyaruError.corruptedRecord(offset: offset, reason: "CRC mismatch")
    }
    return LiveRecord(
      offset: offset,
      payload: payload,
      compression: CompressionMethod(recordFlags: flags),
      crc: storedCRC
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
    let head = try handle.read(count: Int(SlottedFile.recordHeaderSize), at: offset)
    guard head.count == Int(SlottedFile.recordHeaderSize),
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
    let head = try handle.read(count: Int(SlottedFile.recordHeaderSize), at: offset)
    guard head.count == Int(SlottedFile.recordHeaderSize),
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
    _deadBytes += UInt64(capacity)
    return true
  }

  /// Writes the tombstone bit into an existing record header at the given
  /// offset, preserving all other flag bits.
  ///
  /// - Parameters:
  ///   - offset: Byte offset of the record header.
  ///   - existingFlags: The current flags byte value.
  private func writeTombstoneFlag(at offset: UInt64, existingFlags: UInt8) throws {
    try handle.write(Data([existingFlags | RecordFlags.tombstone]), at: offset + 8)
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
    guard let file = try? RawFile(path: url.path, readOnly: true) else { return false }
    defer { try? file.close() }
    guard let data = try? file.read(count: 2, at: 6), data.count == 2 else { return false }
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
    let startPos = max(pos, SlottedFile.fileHeaderSize)
    guard startPos + SlottedFile.recordHeaderSize <= fileSize else {
      return LiveBatch(records: records, nextPos: nil)
    }

    let headerSize = Int(SlottedFile.recordHeaderSize)
    // Read a chunk large enough to hold most of the requested records in one
    // syscall. Records whose payload straddles the chunk boundary fall back to
    // a single seek+read rather than forcing an oversized allocation.
    let chunkEnd = min(fileSize, startPos + UInt64(maxCount) * 1024)
    let chunkSize = Int(chunkEnd - startPos)

    let chunkData = try handle.read(count: chunkSize, at: startPos)
    guard !chunkData.isEmpty else {
      return LiveBatch(records: records, nextPos: nil)
    }

    var relPos = 0
    var cursor = startPos

    while records.count < maxCount, cursor + SlottedFile.recordHeaderSize <= fileSize {
      if relPos + headerSize > chunkData.count { break }

      guard let capacity = Binary.readUInt32(chunkData, at: relPos),
        let payloadLength = Binary.readUInt32(chunkData, at: relPos + 4),
        capacity > 0,
        capacity <= SlottedFile.maxRecordSize,
        payloadLength <= capacity,
        cursor + SlottedFile.recordHeaderSize + UInt64(capacity) <= fileSize
      else { return LiveBatch(records: records, nextPos: nil) }

      let flags = chunkData[chunkData.startIndex + relPos + 8]
      if flags & RecordFlags.tombstone == 0 {
        let storedCRC = Binary.readUInt32(chunkData, at: relPos + 12) ?? 0
        let payloadStart = relPos + headerSize
        let payloadEnd = payloadStart + Int(payloadLength)
        if payloadEnd <= chunkData.count {
          let slice =
            chunkData[chunkData.startIndex + payloadStart..<chunkData.startIndex + payloadEnd]
          records.append(
            LiveRecord(
              offset: cursor, payload: Data(slice),
              compression: CompressionMethod(recordFlags: flags), crc: storedCRC))
        } else {
          // Payload straddles the chunk boundary — fall back to a direct read.
          let payload = try handle.read(
            count: Int(payloadLength), at: cursor + SlottedFile.recordHeaderSize)
          guard payload.count == Int(payloadLength) else {
            throw NyaruError.corruptedRecord(offset: cursor, reason: "short payload")
          }
          records.append(
            LiveRecord(
              offset: cursor, payload: payload,
              compression: CompressionMethod(recordFlags: flags), crc: storedCRC))
        }
      }
      relPos += headerSize + Int(capacity)
      cursor += SlottedFile.recordHeaderSize + UInt64(capacity)
    }

    let atEOF = cursor + SlottedFile.recordHeaderSize > fileSize
    return LiveBatch(records: records, nextPos: atEOF ? nil : cursor)
  }
}
