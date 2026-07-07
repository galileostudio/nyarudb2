//
//  OrderedIndexDeadSlotTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-07.
//

import XCTest

@testable import NyaruDB2

/// Tests for the dead-key-slot invariant: a key whose posting list empties
/// stays in the arrays as a semantically absent slot until a threshold
/// sweep, so one-by-one removals stop paying an O(n) key-array shift.
final class OrderedIndexDeadSlotTests: XCTestCase {
  private func pointer(_ offset: UInt64) -> RecordPointer {
    RecordPointer(shardID: "default", offset: offset)
  }

  func testEmptiedKeyIsSemanticallyAbsent() {
    let index = OrderedIndex()
    index.insert(key: .int(1), pointer: pointer(10))
    index.insert(key: .int(2), pointer: pointer(20))
    index.insert(key: .int(3), pointer: pointer(30))

    index.remove(key: .int(2), pointer: pointer(20))

    XCTAssertFalse(index.contains(.int(2)))
    XCTAssertTrue(index.search(.int(2)).isEmpty)
    XCTAssertEqual(index.entryCount, 2)
    XCTAssertEqual(index.uniqueKeyCount, 2)
    XCTAssertEqual(index.allKeys, [.int(1), .int(3)])
    XCTAssertEqual(
      index.keysInRange(lower: .int(1), lowerInclusive: true, upper: .int(3), upperInclusive: true),
      [.int(1), .int(3)])
    XCTAssertEqual(
      index.range(lower: .int(1), lowerInclusive: true, upper: .int(3), upperInclusive: true)
        .count,
      2)
  }

  func testDeadSlotRevivesOnInsert() {
    let index = OrderedIndex()
    index.insert(key: .string("a"), pointer: pointer(1))
    index.remove(key: .string("a"), pointer: pointer(1))
    XCTAssertFalse(index.contains(.string("a")))
    XCTAssertEqual(index.uniqueKeyCount, 0)

    index.insert(key: .string("a"), pointer: pointer(2))
    XCTAssertTrue(index.contains(.string("a")))
    XCTAssertEqual(index.uniqueKeyCount, 1)
    XCTAssertEqual(index.search(.string("a")), [pointer(2)])
    XCTAssertEqual(index.entryCount, 1)
  }

  func testThresholdSweepShrinksTheArrays() {
    let index = OrderedIndex()
    for i in 0..<1_000 {
      index.insert(key: .int(Int64(i)), pointer: pointer(UInt64(i)))
    }
    // The 250th removal reaches the sweep threshold (250 dead × 4 >= 1000
    // keys) and compacts the arrays down to the 750 live keys.
    for i in 0..<250 {
      index.remove(key: .int(Int64(i)), pointer: pointer(UInt64(i)))
    }

    XCTAssertEqual(index.uniqueKeyCount, 750)
    XCTAssertEqual(index.entryCount, 750)
    XCTAssertEqual(index.keys.count, 750, "threshold sweep should have compacted the arrays")
    XCTAssertEqual(index.emptyKeyCount, 0)
    XCTAssertFalse(index.contains(.int(100)))
    XCTAssertTrue(index.contains(.int(500)))
  }

  func testSnapshotSkipsDeadSlots() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-deadslot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("index.idx")

    let index = OrderedIndex()
    for i in 0..<100 {
      index.insert(key: .int(Int64(i)), pointer: pointer(UInt64(i)))
    }
    for i in 0..<30 {
      index.remove(key: .int(Int64(i)), pointer: pointer(UInt64(i)))
    }
    XCTAssertEqual(index.emptyKeyCount, 30)

    try index.persist(to: url, encryptionKey: nil)
    let loaded = try OrderedIndex.load(from: url, encryptionKey: nil)

    XCTAssertEqual(loaded.keys.count, 70, "dead slots must not be persisted")
    XCTAssertEqual(loaded.emptyKeyCount, 0)
    XCTAssertEqual(loaded.entryCount, 70)
    XCTAssertFalse(loaded.contains(.int(10)))
    XCTAssertTrue(loaded.contains(.int(50)))
  }

  func testBulkLoadDropsAndRevivesDeadSlots() {
    let index = OrderedIndex()
    for i in 0..<10 {
      index.insert(key: .int(Int64(i)), pointer: pointer(UInt64(i)))
    }
    index.remove(key: .int(3), pointer: pointer(3))
    index.remove(key: .int(7), pointer: pointer(7))

    // Revive key 3 via bulk load; key 7 stays dead and must be swept.
    index.bulkLoad([(key: .int(3), pointer: pointer(103)), (key: .int(42), pointer: pointer(142))])

    XCTAssertTrue(index.contains(.int(3)))
    XCTAssertEqual(index.search(.int(3)), [pointer(103)])
    XCTAssertFalse(index.contains(.int(7)))
    XCTAssertTrue(index.contains(.int(42)))
    XCTAssertEqual(index.keys.count, index.uniqueKeyCount, "bulkLoad rebuild drops dead slots")
    XCTAssertEqual(index.emptyKeyCount, 0)
  }

  /// End-to-end: one-by-one deletes must keep counts, covered queries, and
  /// covered distinct correct, including across a snapshot reopen.
  func testCollectionUnitDeletesStayConsistent() async throws {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-unitdelete-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }

    struct Doc: Codable, Sendable {
      var id: Int
      var age: Int
    }

    var db = try NyaruDB(path: baseURL)
    var docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    try await docs.insert(contentsOf: (1...500).map { Doc(id: $0, age: $0) })

    // FIFO unit deletes — the pattern that empties a key on every call.
    for id in 1...200 {
      let removed = try await docs.delete(id: id)
      XCTAssertTrue(removed)
    }

    let count = try await docs.count()
    XCTAssertEqual(count, 300)
    // Covered count and covered distinct must not see ghost keys.
    let covered = try await docs.find().where("age", isGreaterThanOrEqualTo: 1).count()
    XCTAssertEqual(covered, 300)
    let distinct = try await docs.find().distinctValues(on: "age")
    XCTAssertEqual(distinct.count, 300)
    let gone = try await docs.find().where("age", isEqualTo: 100).count()
    XCTAssertEqual(gone, 0)
    let there = try await docs.get(id: 300)
    XCTAssertEqual(there?.age, 300)

    try await docs.sync()
    try await db.close()

    db = try NyaruDB(path: baseURL)
    docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    let reopenedCount = try await docs.count()
    XCTAssertEqual(reopenedCount, 300)
    let reopenedDistinct = try await docs.find().distinctValues(on: "age")
    XCTAssertEqual(reopenedDistinct.count, 300)
    try await db.close()
  }
}
