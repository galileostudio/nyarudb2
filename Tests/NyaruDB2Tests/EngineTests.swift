import XCTest

@testable import NyaruDB2

/// End-to-end tests through the public API (NyaruDB / NyaruCollection /
/// QueryBuilder). Every regression test below is named after a real,
/// catalogued corruption bug in the previous engine.
final class EngineTests: XCTestCase {
  private var baseURL: URL!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var email: String
    var age: Int
    var country: String
    var address: Address
    struct Address: Codable, Sendable, Equatable { var city: String }
  }

  private func user(
    _ id: Int, name: String = "User", email: String? = nil,
    age: Int = 30, country: String = "BR", city: String = "Recife"
  ) -> User {
    User(
      id: id, name: name, email: email ?? "u\(id)@example.com",
      age: age, country: country, address: .init(city: city)
    )
  }

  private let userOptions = CollectionOptions(
    partitionKey: "country",
    indexedFields: ["email", "age", "address.city"]
  )

  override func setUp() {
    super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: baseURL)
    super.tearDown()
  }

  private func openDB(compression: CompressionMethod = .none) async throws -> NyaruDB {
    try NyaruDB(path: baseURL, options: .init(compression: compression))
  }

  // MARK: - CRUD

  func testInsertGetRoundtrip() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    let alice = user(1, name: "Alice")
    try await users.insert(alice)
    let fetched = try await users.get(id: 1)
    XCTAssertEqual(fetched, alice)
    let count = try await users.count()
    XCTAssertEqual(count, 1)
    try await db.close()
  }

  func testDuplicateIDThrows() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1))
    do {
      try await users.insert(user(1, name: "Impostor"))
      XCTFail("expected duplicateID")
    } catch let error as NyaruError {
      guard case .duplicateID = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
    let count = try await users.count()
    XCTAssertEqual(count, 1)
    try await db.close()
  }

  func testUpdateMissingThrowsAndUpsertInserts() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    do {
      try await users.update(user(7))
      XCTFail("expected documentNotFound")
    } catch let error as NyaruError {
      guard case .documentNotFound = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
    try await users.upsert(user(7, name: "Grace"))
    let fetched = try await users.get(id: 7)
    XCTAssertEqual(fetched?.name, "Grace")
    try await db.close()
  }

  func testDeleteByID() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1))
    let removed = try await users.delete(id: 1)
    XCTAssertTrue(removed)
    let again = try await users.delete(id: 1)
    XCTAssertFalse(again)
    let fetched = try await users.get(id: 1)
    XCTAssertNil(fetched)
    let count = try await users.count()
    XCTAssertEqual(count, 0)
    try await db.close()
  }

  func testInsertManyValidatesBeforeWriting() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    do {
      try await users.insert(contentsOf: [user(1), user(2), user(1)])
      XCTFail("expected duplicateID for duplicate inside the batch")
    } catch let error as NyaruError {
      guard case .duplicateID = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
    // Validation happens before any write: nothing was persisted.
    let count = try await users.count()
    XCTAssertEqual(count, 0)
    try await db.close()
  }

  // MARK: - Regression: single size field corrupted navigation (bug #1)

  func testShrinkAndGrowUpdatesDoNotCorruptNeighbors() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1, name: "First"))
    try await users.insert(user(2, name: "Middle"))
    try await users.insert(user(3, name: "Last"))

    // Grow: forces tombstone + relocation within the shard.
    try await users.update(user(2, name: String(repeating: "M", count: 2000)))
    // Shrink: rewrites in place inside the immutable slot capacity.
    try await users.update(user(2, name: "m"))

    let all = try await users.all()
    XCTAssertEqual(all.count, 3)
    let first = try await users.get(id: 1)
    let last = try await users.get(id: 3)
    XCTAssertEqual(first?.name, "First")
    XCTAssertEqual(last?.name, "Last")
    let middle = try await users.get(id: 2)
    XCTAssertEqual(middle?.name, "m")
    try await db.close()
  }

  // MARK: - Regression: unqualified index offsets crossed shards (bug #2)

  func testSameOffsetInDifferentShardsDoesNotCollide() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    // Both documents are the first record of their shard file, so both
    // live at the *same byte offset* in different files. The old engine
    // stored bare offsets and served/deleted the wrong document here.
    try await users.insert(user(1, email: "shared@x.io", country: "BR"))
    try await users.insert(user(2, email: "shared@x.io", country: "PT"))

    let both = try await users.find()
      .where("email", isEqualTo: "shared@x.io")
      .execute()
    XCTAssertEqual(both.count, 2)

    try await users.delete(id: 1)
    let remaining = try await users.find()
      .where("email", isEqualTo: "shared@x.io")
      .execute()
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining.first?.id, 2)
    XCTAssertEqual(remaining.first?.country, "PT")
    try await db.close()
  }

  // MARK: - Regression: partition change corrupted updates (bug #8)

  func testUpdateMovingDocumentAcrossPartitions() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1, country: "BR"))
    try await users.update(user(1, country: "PT"))

    let count = try await users.count()
    XCTAssertEqual(count, 1)
    let inBR = try await users.find().where("country", isEqualTo: "BR").count()
    let inPT = try await users.find().where("country", isEqualTo: "PT").count()
    XCTAssertEqual(inBR, 0)
    XCTAssertEqual(inPT, 1)
    let fetched = try await users.get(id: 1)
    XCTAssertEqual(fetched?.country, "PT")
    let stats = try await users.stats()
    XCTAssertEqual(stats.shardCount, 2)
    try await db.close()
  }

  // MARK: - Regression: indexes were never rehydrated on reopen (bug #3)

  func testCleanReopenRehydratesDataAndIndexes() async throws {
    do {
      let db = try await openDB()
      let users = try await db.collection("users", of: User.self, options: userOptions)
      try await users.insert(contentsOf: (1...20).map { self.user($0, age: 20 + $0) })
      try await db.close()
    }
    let db2 = try await openDB()
    let users2 = try await db2.collection("users", of: User.self, options: userOptions)
    let count = try await users2.count()
    XCTAssertEqual(count, 20)

    let fetched13 = try await users2.get(id: 13)
    XCTAssertEqual(fetched13?.id, 13)

    let plan = await users2.find().where("email", isEqualTo: "u5@example.com").explain()
    XCTAssertEqual(plan.strategy, .indexLookup(field: "email"))
    let hits = try await users2.find().where("email", isEqualTo: "u5@example.com").execute()
    XCTAssertEqual(hits.count, 1)
    try await db2.close()
  }

  func testCrashReopenRebuildsFromData() async throws {
    // No close(), no sync(): the dirty flag stays set, simulating a
    // crash. Reopening must run recovery and rebuild indexes from data.
    let db1 = try await openDB()
    let users1 = try await db1.collection("users", of: User.self, options: userOptions)
    try await users1.insert(contentsOf: (1...10).map { self.user($0) })
    try await users1.delete(id: 4)

    let db2 = try await openDB()
    let users2 = try await db2.collection("users", of: User.self, options: userOptions)
    let count = try await users2.count()
    XCTAssertEqual(count, 9)

    let fetched4 = try await users2.get(id: 4)
    XCTAssertNil(fetched4)

    let fetched9 = try await users2.get(id: 9)
    XCTAssertEqual(fetched9?.id, 9)

    let hits = try await users2.find().where("email", isEqualTo: "u2@example.com").count()
    XCTAssertEqual(hits, 1)
    try await db2.close()
    _ = db1  // keep the "crashed" instance alive until here
  }

  // MARK: - Index evolution

  func testIndexedFieldsCanEvolveBetweenOpens() async throws {
    let db = try await openDB()
    let bare = CollectionOptions(partitionKey: "country", indexedFields: [])
    let users = try await db.collection("users", of: User.self, options: bare)
    try await users.insert(contentsOf: (1...5).map { self.user($0, age: 40 + $0) })

    let before = await users.find().where("age", isEqualTo: 42).explain()
    XCTAssertNotEqual(before.strategy, .indexLookup(field: "age"))

    // Same database instance, new configuration: the index is built by
    // scanning existing data.
    let indexed = CollectionOptions(partitionKey: "country", indexedFields: ["age"])
    let users2 = try await db.collection("users", of: User.self, options: indexed)
    let after = await users2.find().where("age", isEqualTo: 42).explain()
    XCTAssertEqual(after.strategy, .indexLookup(field: "age"))
    let hits = try await users2.find().where("age", isEqualTo: 42).execute()
    XCTAssertEqual(hits.map(\.id), [2])
    try await db.close()

    // And it survives a reopen.
    let db2 = try await openDB()
    let users3 = try await db2.collection("users", of: User.self, options: indexed)
    let plan = await users3.find().where("age", isEqualTo: 42).explain()
    XCTAssertEqual(plan.strategy, .indexLookup(field: "age"))
    try await db2.close()
  }

  func testChangingBaseConfigurationThrows() async throws {
    do {
      let db = try await openDB()
      _ = try await db.collection("users", of: User.self, options: userOptions)
      try await db.close()
    }
    let db2 = try await openDB()
    do {
      _ = try await db2.collection(
        "users", of: User.self,
        options: CollectionOptions(partitionKey: "address.city")
      )
      XCTFail("expected collectionTypeMismatch")
    } catch let error as NyaruError {
      guard case .collectionTypeMismatch = error else {
        return XCTFail("wrong error: \(error)")
      }
    }
    try await db2.close()
  }

  // MARK: - Regression: DynamicDecoder failed on nested documents (bug #10)

  func testNestedFieldIndexAndQuery() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1, city: "Recife"))
    try await users.insert(user(2, city: "Lisboa"))
    try await users.insert(user(3, city: "Recife"))

    let plan = await users.find().where("address.city", isEqualTo: "Recife").explain()
    XCTAssertEqual(plan.strategy, .indexLookup(field: "address.city"))
    let hits = try await users.find()
      .where("address.city", isEqualTo: "Recife")
      .sort(by: "id")
      .execute()
    XCTAssertEqual(hits.map(\.id), [1, 3])
    try await db.close()
  }

  // MARK: - Queries

  func testQueryOperatorsSortLimitOffset() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(
      contentsOf: (1...30).map {
        self.user($0, name: "User\($0)", age: $0, country: $0 % 2 == 0 ? "BR" : "PT")
      })

    let between = try await users.find()
      .where("age", isBetween: 10, and: 12)
      .sort(by: "age")
      .execute()
    XCTAssertEqual(between.map(\.age), [10, 11, 12])

    let inSet = try await users.find()
      .where("age", isIn: [3, 5, 999])
      .count()
    XCTAssertEqual(inSet, 2)

    let page = try await users.find()
      .where("country", isEqualTo: "BR")
      .sort(by: "age", ascending: false)
      .offset(2)
      .limit(3)
      .execute()
    XCTAssertEqual(page.map(\.age), [26, 24, 22])

    let prefix = try await users.find()
      .where("name", startsWith: "User1")
      .count()
    XCTAssertEqual(prefix, 11)  // User1, User10...User19

    // The same predicate must produce identical results whether it runs
    // through an index or as a residual filter over a full scan.
    let viaIndex = try await users.find()
      .where("age", isGreaterThanOrEqualTo: 25)
      .sort(by: "id")
      .execute()
    let viaScan = try await users.find()
      .where("name", contains: "User")  // not indexed: forces a scan
      .where("age", isGreaterThanOrEqualTo: 25)
      .sort(by: "id")
      .execute()
    XCTAssertEqual(viaIndex, viaScan)
    try await db.close()
  }

  func testPartitionScanStrategy() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1, country: "BR"))
    try await users.insert(user(2, country: "PT"))
    let plan = await users.find().where("country", isEqualTo: "BR").explain()
    XCTAssertEqual(plan.strategy, .partitionScan(value: "BR"))
    let hits = try await users.find().where("country", isEqualTo: "BR").execute()
    XCTAssertEqual(hits.map(\.id), [1])
    try await db.close()
  }

  func testQueryDelete() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(contentsOf: (1...10).map { self.user($0, age: $0) })
    let removed = try await users.find()
      .where("age", isLessThanOrEqualTo: 4)
      .delete()
    XCTAssertEqual(removed, 4)
    let count = try await users.count()
    XCTAssertEqual(count, 6)

    let fetched3 = try await users.get(id: 3)
    XCTAssertNil(fetched3)

    // Secondary indexes must not retain pointers to deleted documents.
    let stale = try await users.find().where("age", isEqualTo: 2).count()
    XCTAssertEqual(stale, 0)
    try await db.close()
  }

  func testStreamYieldsEverything() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(contentsOf: (1...25).map { self.user($0) })
    var seen = Set<Int>()
    for try await u in users.stream() {
      seen.insert(u.id)
    }
    XCTAssertEqual(seen, Set(1...25))
    try await db.close()
  }

  // MARK: - Compression

  func testGzipCollectionRoundtripAndReopen() async throws {
    do {
      let db = try await openDB(compression: .gzip)
      let users = try await db.collection("users", of: User.self, options: userOptions)
      try await users.insert(
        contentsOf: (1...15).map {
          self.user($0, name: String(repeating: "compressible ", count: 50))
        })
      try await db.close()
    }
    let db2 = try await openDB(compression: .gzip)
    let users2 = try await db2.collection("users", of: User.self, options: userOptions)
    let count = try await users2.count()
    XCTAssertEqual(count, 15)

    let fetched8 = try await users2.get(id: 8)
    XCTAssertEqual(fetched8?.id, 8)
    try await db2.close()
  }

  // MARK: - Maintenance

  func testCompactReclaimsSpaceAndPreservesData() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(
      contentsOf: (1...50).map {
        self.user($0, name: String(repeating: "x", count: 500))
      })
    // Delete a sub-threshold fraction so the deletes tombstone (rather than
    // triggering the large-fraction survivor rewrite, which would reclaim the
    // space itself and leave compact nothing to do).
    _ = try await users.find().where("id", isLessThanOrEqualTo: 20).delete()
    let before = try await users.stats().sizeInBytes

    try await users.compact()

    let after = try await users.stats().sizeInBytes
    XCTAssertLessThan(after, before)
    let count = try await users.count()
    XCTAssertEqual(count, 30)

    let fetched45 = try await users.get(id: 45)
    XCTAssertEqual(fetched45?.id, 45)

    let hits = try await users.find().where("email", isEqualTo: "u50@example.com").count()
    XCTAssertEqual(hits, 1)
    try await db.close()
  }

  // MARK: - Large-fraction batch delete (survivor rewrite)

  /// Deleting a majority of the collection rewrites survivors instead of
  /// tombstoning each record: space is reclaimed immediately (no compact), and
  /// every index — primary and secondary, across all partition shards — points
  /// only at survivors afterwards.
  func testLargeFractionDeleteRewritesAndReindexes() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    // 100 docs across two partition shards (country), age == id, 5 cities.
    try await users.insert(
      contentsOf: (1...100).map {
        self.user(
          $0, name: String(repeating: "x", count: 200), age: $0,
          country: $0 % 2 == 0 ? "BR" : "US", city: "city\($0 % 5)")
      })
    let sizeBefore = try await users.stats().sizeInBytes

    // 80% deleted → survivor-rewrite path (no explicit compact below).
    let removed = try await users.find().where("id", isLessThanOrEqualTo: 80).delete()
    XCTAssertEqual(removed, 80)

    // Space reclaimed immediately — the tombstone path would leave it unchanged.
    let sizeAfter = try await users.stats().sizeInBytes
    XCTAssertLessThan(sizeAfter, sizeBefore)

    let count = try await users.count()
    XCTAssertEqual(count, 20)

    // Survivors intact; deleted ids gone; no ghosts.
    let survivor = try await users.get(id: 90)
    XCTAssertEqual(survivor?.id, 90)
    let deleted = try await users.get(id: 10)
    XCTAssertNil(deleted)

    // Secondary index on email: survivor resolves, deleted does not.
    let survivorEmail = try await users.find().where("email", isEqualTo: "u90@example.com").count()
    XCTAssertEqual(survivorEmail, 1)
    let deletedEmail = try await users.find().where("email", isEqualTo: "u10@example.com").count()
    XCTAssertEqual(deletedEmail, 0)

    // Secondary index on age (== id): only survivors (81…100) remain.
    let byAge = try await users.find().where("age", isGreaterThan: 80).execute()
    XCTAssertEqual(byAge.count, 20)
    let stale = try await users.find().where("age", isLessThanOrEqualTo: 80).count()
    XCTAssertEqual(stale, 0)

    // Durable across reopen: the rewritten files and rebuilt/remapped indexes
    // agree — no resurrected records.
    try await db.close()
    let db2 = try await openDB()
    let users2 = try await db2.collection("users", of: User.self, options: userOptions)
    let reopenedCount = try await users2.count()
    XCTAssertEqual(reopenedCount, 20)
    let reopenedSurvivor = try await users2.get(id: 95)
    XCTAssertEqual(reopenedSurvivor?.id, 95)
    let reopenedDeleted = try await users2.get(id: 5)
    XCTAssertNil(reopenedDeleted)
    let reopenedByAge = try await users2.find().where("age", isGreaterThan: 80).count()
    XCTAssertEqual(reopenedByAge, 20)
    try await db2.close()
  }

  /// The id-only `delete(ids:)` path takes the same rewrite branch and is
  /// equally correct without the query engine pre-extracting keys.
  func testLargeFractionDeleteByIdsRewrites() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(
      contentsOf: (1...60).map {
        self.user($0, age: $0, country: $0 % 2 == 0 ? "BR" : "US", city: "city\($0 % 3)")
      })
    let removed = try await users.delete(ids: Array(1...45))  // 75% → rewrite
    XCTAssertEqual(removed, 45)
    let count = try await users.count()
    XCTAssertEqual(count, 15)
    let gone = try await users.get(id: 1)
    XCTAssertNil(gone)
    let survivor = try await users.get(id: 46)
    XCTAssertEqual(survivor?.id, 46)
    let byAge = try await users.find().where("age", isGreaterThan: 45).count()
    XCTAssertEqual(byAge, 15)
    try await db.close()
  }

  func testDropCollection() async throws {
    let db = try await openDB()
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(user(1))
    try await db.drop("users")
    let names = try await db.listCollections()
    XCTAssertTrue(names.isEmpty)
    try await db.close()
  }

  // MARK: - Exact 64-bit integer keys (Double would corrupt these)

  struct Event: Codable, Equatable {
    let id: Int64  // snowflake-style: exceeds 2^53
    let kind: String
  }

  func testInt64PrimaryKeysAboveDoublePrecision() async throws {
    let db = try NyaruDB(path: baseURL)
    let events = try await db.collection(
      "events", of: Event.self,
      options: CollectionOptions(idField: "id")
    )

    // Adjacent snowflake IDs: identical if round-tripped through Double.
    let base: Int64 = (1 << 60) + 12345
    let a = Event(id: base, kind: "click")
    let b = Event(id: base + 1, kind: "view")
    try await events.insert(a)
    try await events.insert(b)  // would throw duplicateID under Double keys

    let fetchedA = try await events.get(id: base)
    XCTAssertEqual(fetchedA, a)

    let fetchedB = try await events.get(id: base + 1)
    XCTAssertEqual(fetchedB, b)

    let isDeleted = try await events.delete(id: base)
    XCTAssertTrue(isDeleted)

    let deletedA = try await events.get(id: base)
    XCTAssertNil(deletedA)

    let fetchedB2 = try await events.get(id: base + 1)
    XCTAssertEqual(fetchedB2, b)

    // Survives close/reopen (index persistence keeps exact Int64).
    try await db.close()
    let db2 = try NyaruDB(path: baseURL)
    let events2 = try await db2.collection(
      "events", of: Event.self,
      options: CollectionOptions(idField: "id")
    )
    let fetchedB3 = try await events2.get(id: base + 1)
    XCTAssertEqual(fetchedB3, b)
    try await db2.close()
  }

  func testMixedIntAndDoubleQueryValues() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(contentsOf: (1...9).map { user($0, age: 20 + $0) })

    // Integer-valued Double query key must hit integer-extracted index keys.
    let viaDouble = try await users.find()
      .where("age", isEqualTo: 23.0)
      .execute()
    XCTAssertEqual(viaDouble.map(\.id), [3])

    // Fractional bounds must slot correctly between integer keys.
    let ranged = try await users.find()
      .where("age", isGreaterThan: 24.5)
      .where("age", isLessThan: 27.5)
      .sort(by: "age")
      .execute()
    XCTAssertEqual(ranged.map(\.id), [5, 6, 7])
    try await db.close()
  }
}
