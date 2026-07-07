//
//  MetricsTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-07.
//

import XCTest

@testable import NyaruDB2

final class MetricsTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!

  private struct Doc: Codable, Sendable {
    var id: Int
    var age: Int
    var city: String
  }

  override func setUp() async throws {
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-metrics-\(UUID().uuidString)", isDirectory: true)
    db = try NyaruDB(path: baseURL)
  }

  override func tearDown() async throws {
    try await db?.close()
    try? FileManager.default.removeItem(at: baseURL)
  }

  func testCountersReflectAccessPaths() async throws {
    let docs = try await db.collection(
      "docs", of: Doc.self,
      options: CollectionOptions(idField: "id", partitionKey: "city", indexedFields: ["age"]))
    try await docs.insert(
      contentsOf: (1...200).map { Doc(id: $0, age: $0 % 50, city: $0 % 2 == 0 ? "BR" : "PT") })

    // Covered count (index only), an indexed fetch, a partition scan, and a
    // full scan.
    _ = try await docs.find().where("age", isEqualTo: 10).count()
    _ = try await docs.find().where("age", isGreaterThan: 40).execute()
    // Only the partition key — an indexed-field predicate would win the
    // planner's priority and turn this into an index lookup.
    _ = try await docs.find().where("city", isEqualTo: "BR").execute()
    _ = try await docs.find().where("id", isNotEqualTo: 0).execute()

    for id in 1...100 where id % 2 == 0 {
      _ = try await docs.delete(id: id)
    }
    try await docs.compact()

    let metrics = try await docs.metrics()
    XCTAssertGreaterThanOrEqual(metrics.indexLookups, 2)
    XCTAssertGreaterThanOrEqual(metrics.coveredQueries, 1)
    XCTAssertGreaterThanOrEqual(metrics.fullScans, 1)
    XCTAssertGreaterThanOrEqual(metrics.partitionScans, 1)
    XCTAssertGreaterThan(metrics.bytesWritten, 0)
    XCTAssertGreaterThan(metrics.bytesRead, 0)
    XCTAssertEqual(metrics.compactionCount, 1)
    XCTAssertNotNil(metrics.lastCompactionDuration)
    XCTAssertEqual(metrics.shardsRecoveredFromDirty, 0)
  }

  func testDirtyReopenCountsRecoveredShards() async throws {
    do {
      let docs = try await db.collection(
        "docs", of: Doc.self, options: CollectionOptions(idField: "id"))
      try await docs.insert(contentsOf: (1...20).map { Doc(id: $0, age: $0, city: "BR") })
      // No clean close: drop the handle with the dirty flag set.
      db = nil
    }
    db = try NyaruDB(path: baseURL)
    let docs = try await db.collection(
      "docs", of: Doc.self, options: CollectionOptions(idField: "id"))
    let count = try await docs.count()
    XCTAssertEqual(count, 20)
    let metrics = try await docs.metrics()
    XCTAssertEqual(metrics.shardsRecoveredFromDirty, 1)
  }
}
