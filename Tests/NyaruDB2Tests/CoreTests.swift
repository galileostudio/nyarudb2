import XCTest

@testable import NyaruDB2

final class BinaryTests: XCTestCase {
  func testRoundTrip() {
    var data = Data()
    Binary.append(UInt16(0xBEEF), to: &data)
    Binary.append(UInt32(0xDEAD_BEEF), to: &data)
    Binary.append(UInt64(0x0123_4567_89AB_CDEF), to: &data)
    XCTAssertEqual(Binary.readUInt16(data, at: 0), 0xBEEF)
    XCTAssertEqual(Binary.readUInt32(data, at: 2), 0xDEAD_BEEF)
    XCTAssertEqual(Binary.readUInt64(data, at: 6), 0x0123_4567_89AB_CDEF)
  }

  func testOutOfBounds() {
    let data = Data([1, 2])
    XCTAssertNil(Binary.readUInt32(data, at: 0))
    XCTAssertNil(Binary.readUInt16(data, at: 1))
    XCTAssertNil(Binary.readUInt16(data, at: -1))
  }

  func testReadFromSlicedData() {
    // Data slices keep the parent's indices; readers must respect startIndex.
    var data = Data([0xFF, 0xFF])
    Binary.append(UInt32(42), to: &data)
    let slice = data[2...]
    XCTAssertEqual(Binary.readUInt32(Data(slice), at: 0), 42)
  }
}

final class FieldValueTests: XCTestCase {
  func testTotalOrdering() {
    XCTAssertTrue(FieldValue.null < .bool(false))
    XCTAssertTrue(FieldValue.bool(true) < .number(0))
    XCTAssertTrue(FieldValue.number(999) < .string(""))
    XCTAssertTrue(FieldValue.number(1) < .number(2))
    XCTAssertTrue(FieldValue.string("a") < .string("b"))
    XCTAssertTrue(FieldValue.bool(false) < .bool(true))
  }

  func testIntAndDoubleUnify() {
    XCTAssertEqual(1.fieldValue, 1.0.fieldValue)
  }

  func testInt64ExactnessBeyondDoublePrecision() throws {
    // Adjacent Int64s above 2^53 collapse if routed through Double.
    let a: Int64 = (1 << 60) + 1
    let b: Int64 = (1 << 60) + 2
    XCTAssertNotEqual(a.fieldValue, b.fieldValue)
    XCTAssertTrue(a.fieldValue < b.fieldValue)

    // JSON extraction preserves them exactly too.
    let json = #"{"id": 1152921504606846977}"#.data(using: .utf8)!  // 2^60 + 1
    let dict = try FieldExtractor.parse(json, using: .json)
    XCTAssertEqual(FieldExtractor.value(in: dict, path: "id"), .int(a))

    // Exact mixed comparison: 2^60 as Double sits below 2^60 + 1,
    // even though Double cannot represent 2^60 + 1 itself.
    XCTAssertTrue(FieldValue.double(1152921504606846976.0) < .int(a))
    XCTAssertTrue(FieldValue.int(a) < .double(2e18))
  }

  func testCanonicalizationAndHashConsistency() {
    // Factory canonicalizes integral doubles to .int.
    XCTAssertEqual(FieldValue.number(5.0), .int(5))
    XCTAssertEqual(FieldValue.number(-0.0), .int(0))
    XCTAssertEqual(FieldValue.number(5.5), .double(5.5))

    // Hand-built non-canonical values still behave: == and hash agree.
    let canonical = FieldValue.int(5)
    let sneaky = FieldValue.double(5.0)
    XCTAssertEqual(canonical, sneaky)
    var set: Set<FieldValue> = [canonical]
    XCTAssertTrue(set.contains(sneaky))
    set.insert(sneaky)
    XCTAssertEqual(set.count, 1)

    // Type ranks unaffected: bool never unifies with numbers.
    XCTAssertNotEqual(FieldValue.bool(true), .int(1))
  }

  func testIntDescriptionHasNoDecimalPoint() {
    // Partition shard filenames come from `description`; "42.0" would
    // split integer and double partition values into distinct shards.
    XCTAssertEqual(FieldValue.int(42).description, "42")
    XCTAssertEqual(FieldValue.number(42.0).description, "42")
  }

  func testFromJSONObjectDistinguishesBoolFromNumber() throws {
    let json = #"{"flag": true, "count": 1}"#.data(using: .utf8)!
    let dict = try FieldExtractor.parse(json, using: .json)
    XCTAssertEqual(FieldExtractor.value(in: dict, path: "flag"), .bool(true))
    XCTAssertEqual(FieldExtractor.value(in: dict, path: "count"), .number(1))
  }

  func testNestedPathExtraction() throws {
    let json = #"{"user": {"address": {"city": "Recife"}}, "tags": [1,2]}"#.data(using: .utf8)!
    let dict = try FieldExtractor.parse(json, using: .json)
    XCTAssertEqual(
      FieldExtractor.value(in: dict, path: "user.address.city"),
      .string("Recife")
    )
    XCTAssertNil(FieldExtractor.value(in: dict, path: "user.address.zip"))
    // Non-scalar leaves are not indexable values.
    XCTAssertNil(FieldExtractor.value(in: dict, path: "tags"))
  }

  func testExplicitNull() throws {
    let json = #"{"middleName": null}"#.data(using: .utf8)!
    let dict = try FieldExtractor.parse(json, using: .json)
    XCTAssertEqual(FieldExtractor.value(in: dict, path: "middleName"), .null)
    XCTAssertNil(FieldExtractor.value(in: dict, path: "missing"))
  }
}

final class OrderedIndexTests: XCTestCase {
  private func ptr(_ n: UInt64, shard: String = "s") -> RecordPointer {
    RecordPointer(shardID: shard, offset: n)
  }

  func testInsertSearchRemove() {
    let index = OrderedIndex()
    index.insert(key: .number(2), pointer: ptr(20))
    index.insert(key: .number(1), pointer: ptr(10))
    index.insert(key: .number(3), pointer: ptr(30))
    index.insert(key: .number(2), pointer: ptr(21))

    XCTAssertEqual(index.search(.number(2)).count, 2)
    XCTAssertEqual(index.search(.number(1)), [ptr(10)])
    XCTAssertEqual(index.entryCount, 4)
    XCTAssertEqual(index.uniqueKeyCount, 3)

    index.remove(key: .number(2), pointer: ptr(20))
    XCTAssertEqual(index.search(.number(2)), [ptr(21)])
    index.remove(key: .number(2), pointer: ptr(21))
    XCTAssertFalse(index.contains(.number(2)))
    XCTAssertEqual(index.uniqueKeyCount, 2)
  }

  func testRangeBounds() {
    let index = OrderedIndex()
    for i in 1...9 {
      index.insert(key: .number(Double(i)), pointer: ptr(UInt64(i)))
    }
    let inclusive = index.range(
      lower: .number(3), lowerInclusive: true,
      upper: .number(5), upperInclusive: true
    )
    XCTAssertEqual(Set(inclusive.map(\.offset)), [3, 4, 5])

    let exclusive = index.range(
      lower: .number(3), lowerInclusive: false,
      upper: .number(5), upperInclusive: false
    )
    XCTAssertEqual(Set(exclusive.map(\.offset)), [4])

    let unboundedBelow = index.range(
      lower: nil, lowerInclusive: true,
      upper: .number(2), upperInclusive: true
    )
    XCTAssertEqual(Set(unboundedBelow.map(\.offset)), [1, 2])
  }

  func testCrossShardPointersDoNotCollide() {
    // The exact scenario that corrupted the old engine: same offset in
    // two different shards.
    let index = OrderedIndex()
    index.insert(key: .string("x"), pointer: ptr(64, shard: "a"))
    index.insert(key: .string("x"), pointer: ptr(64, shard: "b"))
    XCTAssertEqual(index.search(.string("x")).count, 2)
    index.remove(key: .string("x"), pointer: ptr(64, shard: "a"))
    XCTAssertEqual(index.search(.string("x")), [ptr(64, shard: "b")])
  }

  func testSnapshotRoundTrip() throws {
    let index = OrderedIndex()
    index.insert(key: .string("k"), pointer: ptr(1))
    index.insert(key: .number(7), pointer: ptr(2))
    let encoded = try JSONEncoder().encode(index)
    let decoded = try JSONDecoder().decode(OrderedIndex.self, from: encoded)
    XCTAssertEqual(decoded.search(.string("k")), [ptr(1)])
    XCTAssertEqual(decoded.search(.number(7)), [ptr(2)])
  }
}

final class CompressionTests: XCTestCase {
  func testGzipRoundTrip() throws {
    let payload = Data(String(repeating: "nyaru", count: 1000).utf8)
    let compressed = try Compressor.compress(payload, method: .gzip)
    XCTAssertLessThan(compressed.count, payload.count)
    let restored = try Compressor.decompress(compressed, method: .gzip)
    XCTAssertEqual(restored, payload)
  }

  func testTruncatedGzipFails() throws {
    let payload = Data(String(repeating: "nyaru", count: 1000).utf8)
    let compressed = try Compressor.compress(payload, method: .gzip)
    let truncated = compressed.prefix(compressed.count / 2)
    XCTAssertThrowsError(try Compressor.decompress(Data(truncated), method: .gzip))
  }

  func testCRC32() {
    XCTAssertEqual(Compressor.crc32Checksum(Data()), 0)
    let a = Compressor.crc32Checksum(Data("hello".utf8))
    let b = Compressor.crc32Checksum(Data("hellp".utf8))
    XCTAssertNotEqual(a, b)
  }
}

final class SlottedFileTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-slotted-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func fileURL(_ name: String = "test.nyaru") -> URL {
    directory.appendingPathComponent(name)
  }

  func testAppendReadTombstone() throws {
    let file = try SlottedFile(url: fileURL())
    let a = try file.append(payload: Data("aaa".utf8), compression: .none)
    let b = try file.append(payload: Data("bbbb".utf8), compression: .none)
    XCTAssertEqual(file.liveCount, 2)

    XCTAssertEqual(try file.read(at: a)?.payload, Data("aaa".utf8))
    XCTAssertEqual(try file.read(at: b)?.payload, Data("bbbb".utf8))

    try file.tombstone(at: a)
    XCTAssertNil(try file.read(at: a))
    XCTAssertEqual(file.liveCount, 1)
    // Navigation across the tombstone still works.
    let liveRecords = try collectLive(file)
    XCTAssertEqual(liveRecords.map(\.offset), [b])
    try file.close()
  }

  func testOverwriteInPlaceAndRefusalWhenTooBig() throws {
    let file = try SlottedFile(url: fileURL())
    let offset = try file.append(payload: Data("short".utf8), compression: .none)
    // Fits within the 32-byte slot granularity.
    XCTAssertTrue(
      try file.overwrite(at: offset, payload: Data("a bit longer payload".utf8), compression: .none)
    )
    XCTAssertEqual(try file.read(at: offset)?.payload, Data("a bit longer payload".utf8))
    // Exceeds the immutable capacity: must refuse, never resize.
    let big = Data(repeating: 0x41, count: 500)
    XCTAssertFalse(try file.overwrite(at: offset, payload: big, compression: .none))
    XCTAssertEqual(try file.read(at: offset)?.payload, Data("a bit longer payload".utf8))
    try file.close()
  }

  func testTombstoneSlotReuse() throws {
    let file = try SlottedFile(url: fileURL())
    let a = try file.append(payload: Data(repeating: 1, count: 100), compression: .none)
    _ = try file.append(payload: Data(repeating: 2, count: 100), compression: .none)
    let sizeBefore = file.sizeInBytes()
    try file.tombstone(at: a)
    let c = try file.append(payload: Data(repeating: 3, count: 90), compression: .none)
    XCTAssertEqual(c, a, "should reuse the freed slot")
    XCTAssertEqual(file.sizeInBytes(), sizeBefore, "file must not grow")
    try file.close()
  }

  func testCleanReopenKeepsData() throws {
    let url = fileURL()
    do {
      let file = try SlottedFile(url: url)
      _ = try file.append(payload: Data("persist me".utf8), compression: .none)
      try file.close()
    }
    let reopened = try SlottedFile(url: url)
    XCTAssertFalse(reopened.recoveredFromDirty)
    XCTAssertEqual(reopened.liveCount, 1)
    let liveRecords = try collectLive(reopened)
    XCTAssertEqual(liveRecords.first?.payload, Data("persist me".utf8))
    try reopened.close()
  }

  func testDirtyReopenRecovers() throws {
    let url = fileURL()
    // Write without closing: the dirty flag stays set on disk.
    let file = try SlottedFile(url: url)
    _ = try file.append(payload: Data("survivor".utf8), compression: .none)
    // Intentionally no close()/sync().

    let reopened = try SlottedFile(url: url)
    XCTAssertTrue(reopened.recoveredFromDirty)
    XCTAssertEqual(reopened.liveCount, 1)
    let liveRecords = try collectLive(reopened)
    XCTAssertEqual(liveRecords.first?.payload, Data("survivor".utf8))
    try reopened.close()
  }

  func testTornTrailingWriteIsTruncated() throws {
    let url = fileURL()
    do {
      let file = try SlottedFile(url: url)
      _ = try file.append(payload: Data("good record".utf8), compression: .none)
      // Leave dirty on purpose (no close).
    }
    // Simulate a torn append: garbage half-header at EOF.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0xDE, 0xAD, 0xBE]))
    try handle.close()

    let reopened = try SlottedFile(url: url)
    XCTAssertTrue(reopened.recoveredFromDirty)
    XCTAssertEqual(reopened.liveCount, 1)
    let records = try collectLive(reopened)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.payload, Data("good record".utf8))
    // New appends after truncation must work.
    _ = try reopened.append(payload: Data("after recovery".utf8), compression: .none)
    XCTAssertEqual(reopened.liveCount, 2)
    try reopened.close()
  }

  func testCorruptPayloadIsTombstonedOnRecovery() throws {
    let url = fileURL()
    var offset: UInt64 = 0
    do {
      let file = try SlottedFile(url: url)
      offset = try file.append(payload: Data("intact-record-payload".utf8), compression: .none)
      _ = try file.append(payload: Data("second".utf8), compression: .none)
      // Leave dirty (no close).
    }
    // Flip a payload byte so the CRC no longer matches.
    let handle = try FileHandle(forUpdating: url)
    try handle.seek(toOffset: offset + 16)
    try handle.write(contentsOf: Data([0x00]))
    try handle.close()

    let reopened = try SlottedFile(url: url)
    XCTAssertEqual(reopened.liveCount, 1, "corrupt record must be dropped")
    let liveRecords = try collectLive(reopened)
    XCTAssertEqual(liveRecords.first?.payload, Data("second".utf8))
    try reopened.close()
  }

  // MARK: - Helpers

  // Replaces the old scanLive() by collecting results from forEachLive
  private func collectLive(_ file: SlottedFile) throws -> [SlottedFile.LiveRecord] {
    var results: [SlottedFile.LiveRecord] = []
    try file.forEachLive { results.append($0) }
    return results
  }

  func testFragmentationRatioCalculation() throws {
    let file = try SlottedFile(url: fileURL())

    // Inserts 3 records of 100 bytes (rounded up to 128-byte slots)
    let a = try file.append(payload: Data(repeating: 1, count: 100), compression: .none)
    let b = try file.append(payload: Data(repeating: 2, count: 100), compression: .none)
    _ = try file.append(payload: Data(repeating: 3, count: 100), compression: .none)

    // No garbage, ratio should be 0
    XCTAssertEqual(file.fragmentationRatio, 0.0)

    // Deletes 2 records
    try file.tombstone(at: a)
    try file.tombstone(at: b)

    // 2 dead slots of 128 bytes each = 256 bytes of garbage
    // Total usable space = 3 * (16 + 128) = 432 bytes
    // Ratio = 256 / 432 ≈ 0.5925
    let expectedRatio = 256.0 / 432.0
    XCTAssertEqual(file.fragmentationRatio, expectedRatio, accuracy: 0.001)

    try file.close()
  }
}
