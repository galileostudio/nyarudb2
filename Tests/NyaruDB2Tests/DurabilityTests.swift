//
//  DurabilityTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-07.
//

import XCTest

@testable import NyaruDB2

/// Tests for the durability knob: explicit collection.sync(), autoSync
/// policies, and clean reopens without rebuild after an unclean exit.
final class DurabilityTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!

  private struct Doc: Codable, Sendable, Equatable {
    var id: Int
    var age: Int
  }

  override func setUp() async throws {
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-durability-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try await db?.close()
    try? FileManager.default.removeItem(at: baseURL)
  }

  /// The kill -9 equivalent: write, sync, then drop every handle WITHOUT
  /// close(). The reopen must find clean shards and adopt the persisted
  /// index snapshots — zero recovery work.
  func testReopenAfterSyncNeedsNoRecovery() async throws {
    do {
      db = try NyaruDB(path: baseURL)
      let docs = try await db.collection(
        "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
      try await docs.insert(contentsOf: (1...500).map { Doc(id: $0, age: $0 % 10) })
      try await docs.sync()
      db = nil  // simulated crash: no close()
    }

    db = try NyaruDB(path: baseURL)
    let docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    let metrics = try await docs.metrics()
    XCTAssertEqual(metrics.shardsRecoveredFromDirty, 0, "sync() should leave shards clean")
    let count = try await docs.count()
    XCTAssertEqual(count, 500)
    let age3 = try await docs.find().where("age", isEqualTo: 3).count()
    XCTAssertEqual(age3, 50)
  }

  /// Without any sync, the same crash forces recovery — the control for the
  /// test above.
  func testReopenWithoutSyncRecovers() async throws {
    do {
      db = try NyaruDB(path: baseURL)
      let docs = try await db.collection(
        "docs", of: Doc.self, options: CollectionOptions(idField: "id"))
      try await docs.insert(contentsOf: (1...50).map { Doc(id: $0, age: $0) })
      db = nil
    }
    db = try NyaruDB(path: baseURL)
    let docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id"))
    let metrics = try await docs.metrics()
    XCTAssertEqual(metrics.shardsRecoveredFromDirty, 1)
    let count = try await docs.count()
    XCTAssertEqual(count, 50)
  }

  func testAutoSyncAfterWrites() async throws {
    do {
      db = try NyaruDB(path: baseURL, options: .init(autoSync: .afterWrites(10)))
      let docs = try await db.collection(
        "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
      // Exactly 20 writes: auto-syncs fire at 10 and 20, and no write comes
      // after the last one, so the shard must end up clean.
      for id in 1...20 {
        try await docs.insert(Doc(id: id, age: id))
      }
      // The scheduled auto-sync runs as a follow-up task on the actor;
      // give it a moment to complete before "crashing".
      try await Task.sleep(nanoseconds: 200_000_000)
      db = nil  // crash without close
    }

    db = try NyaruDB(path: baseURL)
    let docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    let metrics = try await docs.metrics()
    XCTAssertEqual(
      metrics.shardsRecoveredFromDirty, 0,
      "auto-sync at write 20 should have left the shard clean")
    let count = try await docs.count()
    XCTAssertEqual(count, 20)
    let age7 = try await docs.find().where("age", isEqualTo: 7).count()
    XCTAssertEqual(age7, 1)
  }

  func testAutoSyncIntervalTriggersOnNextWrite() async throws {
    db = try NyaruDB(path: baseURL, options: .init(autoSync: .interval(0.05)))
    let docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id"))
    try await docs.insert(Doc(id: 1, age: 1))
    try await Task.sleep(nanoseconds: 80_000_000)
    try await docs.insert(Doc(id: 2, age: 2))  // due: schedules a sync
    try await Task.sleep(nanoseconds: 100_000_000)

    // The state sidecar only exists after a sync has run.
    let stateFiles = try FileManager.default
      .contentsOfDirectory(atPath: baseURL.appendingPathComponent("docs/shards").path)
      .filter { $0.hasSuffix(".state") }
    XCTAssertFalse(stateFiles.isEmpty, "interval auto-sync never ran")
  }

  /// Writes racing a sync() must never be lost from the persisted index
  /// snapshots when the shards end up clean.
  func testWritesDuringSyncSurviveCleanReopen() async throws {
    do {
      db = try NyaruDB(path: baseURL)
      let docs = try await db.collection(
        "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
      try await docs.insert(contentsOf: (1...300).map { Doc(id: $0, age: $0) })

      let writer = Task {
        for id in 301...400 {
          try await docs.insert(Doc(id: id, age: id))
        }
      }
      for _ in 0..<5 {
        try await docs.sync()
      }
      try await writer.value
      try await docs.sync()
      db = nil  // crash without close
    }

    db = try NyaruDB(path: baseURL)
    let docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    let metrics = try await docs.metrics()
    XCTAssertEqual(metrics.shardsRecoveredFromDirty, 0)
    // A stale snapshot would lose index entries for the raced writes.
    let count = try await docs.count()
    XCTAssertEqual(count, 400)
    for id in [1, 300, 301, 350, 400] {
      let hit = try await docs.find().where("age", isEqualTo: id).count()
      XCTAssertEqual(hit, 1, "index entry for raced write \(id) missing after clean reopen")
    }
  }
}
