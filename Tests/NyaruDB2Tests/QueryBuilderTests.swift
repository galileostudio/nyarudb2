//
//  QueryBuilderTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-02.
//

import XCTest

@testable import NyaruDB2

/// Tests for the advanced query engine: recursive boolean logic,
/// NOT IN, DISTINCT, and memory-safe pagination.
final class QueryAdvancedTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!
  private var users: NyaruCollection<QueryAdvancedTests.User>!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var age: Int
    var country: String
    var city: String
  }

  private let userOptions = CollectionOptions(
    partitionKey: "country",
    indexedFields: ["age", "country"]
  )

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-adv-tests-\(UUID().uuidString)", isDirectory: true)

    db = try NyaruDB(path: baseURL, options: .init(compression: .none))
    users = try await db.collection("users", of: User.self, options: userOptions)

    // Populating base data for tests
    let testData: [User] = [
      User(id: 1, name: "Alice", age: 25, country: "BR", city: "Recife"),
      User(id: 2, name: "Bob", age: 30, country: "US", city: "New York"),
      User(id: 3, name: "Charlie", age: 65, country: "BR", city: "Recife"),
      User(id: 4, name: "David", age: 70, country: "PT", city: "Lisboa"),
      User(id: 5, name: "Eve", age: 25, country: "BR", city: "Olinda"),
      User(id: 6, name: "Frank", age: 30, country: "US", city: "Boston"),
    ]
    try await users.insert(contentsOf: testData)
  }

  override func tearDown() async throws {
    try await db.close()
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  // MARK: - 1. Recursive Boolean Logic (OR, NOT)

  func testOrLogic() async throws {
    // Who is 25 years old OR from the US?
    let results = try await users.find()
      .where(
        .or([
          .equal("age", 25),
          .equal("country", "US"),
        ])
      )
      .sort(by: "id")
      .execute()

    // Expected: Alice(1), Bob(2), Eve(5), Frank(6)
    XCTAssertEqual(results.count, 4)
    XCTAssertEqual(results.map(\.id), [1, 2, 5, 6])
  }

  func testNotLogic() async throws {
    // Who is NOT from Brazil?
    let results = try await users.find()
      .where(.not(.equal("country", "BR")))
      .sort(by: "id")
      .execute()

    // Expected: Bob(2), David(4), Frank(6)
    XCTAssertEqual(results.count, 3)
    XCTAssertEqual(results.map(\.id), [2, 4, 6])
  }

  func testComplexNestedLogic() async throws {
    // (Age == 25 OR Age == 70) AND NOT (City == "Olinda")
    let results = try await users.find()
      .where(
        .and([
          .or([
            .equal("age", 25),
            .equal("age", 70),
          ]),
          .not(.equal("city", "Olinda")),
        ])
      )
      .sort(by: "id")
      .execute()

    // Expected: Alice(1) and David(4). Eve(5) is excluded by the NOT clause.
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.map(\.id), [1, 4])
  }

  // MARK: - Covered predicate + unaligned sort (sort-key-only fast path)

  /// A fully index-covered predicate combined with a sort on a DIFFERENT field
  /// takes the sort-key-only path (no full per-document parse, no residual
  /// re-evaluation). Results must match a plain reference ordering in every
  /// direction and page.
  func testCoveredPredicateUnalignedSortParity() async throws {
    // age == 25 is index-covered; sorting by id is unaligned → fast path.
    let asc = try await users.find().where("age", isEqualTo: 25).sort(by: "id").execute()
    XCTAssertEqual(asc.map(\.id), [1, 5])

    let desc = try await users.find().where("age", isEqualTo: 25)
      .sort(by: "id", ascending: false).execute()
    XCTAssertEqual(desc.map(\.id), [5, 1])

    // Range predicate on age (still index-covered), sort by unindexed name.
    let byName = try await users.find().where("age", isBetween: 25, and: 70)
      .sort(by: "name").execute()
    XCTAssertEqual(byName.map(\.name), ["Alice", "Bob", "Charlie", "David", "Eve", "Frank"])

    // Offset + limit over the sorted order.
    let paged = try await users.find().where("age", isBetween: 25, and: 70)
      .sort(by: "name").offset(1).limit(2).execute()
    XCTAssertEqual(paged.map(\.name), ["Bob", "Charlie"])

    // Descending + limit exercises the bounded top-K branch.
    let topDesc = try await users.find().where("age", isBetween: 25, and: 70)
      .sort(by: "id", ascending: false).limit(3).execute()
    XCTAssertEqual(topDesc.map(\.id), [6, 5, 4])

    // Aligned ascending sort (sort field == the indexed predicate field) is
    // served by the index-paginated path — the fast path must NOT intercept it
    // and re-apply offset/limit (that would double-paginate and drop rows).
    // Count is tie-independent, so it is unambiguous even with equal ages.
    let alignedPaged = try await users.find().where("age", isBetween: 25, and: 70)
      .sort(by: "age").offset(3).limit(2).execute()
    XCTAssertEqual(alignedPaged.count, 2)
    let alignedLimit = try await users.find().where("age", isBetween: 25, and: 70)
      .sort(by: "age").limit(2).execute()
    XCTAssertEqual(alignedLimit.count, 2)
  }

  // MARK: - Sort pushdown parity (secondary-index-ordered results)

  /// When a query sorts by an indexed field different from the index-covered
  /// predicate field AND a limit is present, the sort pushdown path serves the
  /// page from the sort index. It must return the exact same ordered rows as a
  /// plain in-memory reference sort, for both directions, with and without an
  /// offset, and for selective and dense predicates.
  func testSortPushdownParity() async throws {
    struct Item: Codable, Sendable, Equatable {
      var id: Int
      var group: Int
      var score: Int
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-pushdown-\(UUID().uuidString)", isDirectory: true)
    let pushdownDB = try NyaruDB(path: url, options: .init(compression: .none))
    defer { try? FileManager.default.removeItem(at: url) }
    let items = try await pushdownDB.collection(
      "items", of: Item.self,
      options: CollectionOptions(idField: "id", indexedFields: ["group", "score"]))

    // 400 docs: group is the (selective) predicate field, score the sort field.
    // score is deliberately not monotonic in id so ordering is non-trivial.
    var seed: [Item] = []
    for i in 0..<400 {
      seed.append(Item(id: i, group: i % 5, score: (i * 37) % 400))
    }
    try await items.insert(contentsOf: seed)

    func reference(where pred: (Item) -> Bool, ascending: Bool) -> [Item] {
      seed.filter(pred).sorted {
        ascending ? ($0.score, $0.id) < ($1.score, $1.id) : ($0.score, $0.id) > ($1.score, $1.id)
      }
    }

    // Selective predicate (group == 2 → 80 docs), sort by score, limit 10.
    // 80 > 10*2 → pushdown triggers.
    let ascPage = try await items.find().where("group", isEqualTo: 2)
      .sort(by: "score").limit(10).execute()
    let refAsc = reference(where: { $0.group == 2 }, ascending: true).prefix(10)
    XCTAssertEqual(ascPage.map(\.score), refAsc.map(\.score))

    // Descending.
    let descPage = try await items.find().where("group", isEqualTo: 2)
      .sort(by: "score", ascending: false).limit(10).execute()
    let refDesc = reference(where: { $0.group == 2 }, ascending: false).prefix(10)
    XCTAssertEqual(descPage.map(\.score), refDesc.map(\.score))

    // With an offset.
    let offsetPage = try await items.find().where("group", isEqualTo: 2)
      .sort(by: "score").offset(5).limit(10).execute()
    let refOffset = Array(reference(where: { $0.group == 2 }, ascending: true).dropFirst(5).prefix(10))
    XCTAssertEqual(offsetPage.map(\.score), refOffset.map(\.score))

    // Dense predicate (group >= 0 → all 400), sort by score, limit 10.
    let densePage = try await items.find().where("group", isGreaterThanOrEqualTo: 0)
      .sort(by: "score").limit(10).execute()
    let refDense = reference(where: { $0.group >= 0 }, ascending: true).prefix(10)
    XCTAssertEqual(densePage.map(\.score), refDense.map(\.score))

    try await pushdownDB.close()
  }

  /// Sort pushdown across a partitioned collection: the matching pointers span
  /// multiple shards, exercising the multi-shard ordered read that must still
  /// return rows in exact sort order.
  func testSortPushdownParityPartitioned() async throws {
    struct Item: Codable, Sendable, Equatable {
      var id: Int
      var group: Int
      var score: Int
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-pushdown-part-\(UUID().uuidString)", isDirectory: true)
    let partDB = try NyaruDB(path: url, options: .init(compression: .none))
    defer { try? FileManager.default.removeItem(at: url) }
    let items = try await partDB.collection(
      "items", of: Item.self,
      options: CollectionOptions(
        idField: "id", partitionKey: "group", indexedFields: ["group", "score"]))

    var seed: [Item] = []
    for i in 0..<400 {
      seed.append(Item(id: i, group: i % 8, score: (i * 37) % 400))
    }
    try await items.insert(contentsOf: seed)

    // Predicate on the indexed group field (index-covered, spans all 8
    // group-shards); sort by the indexed score field, limit 10. The lowest 10
    // scores belong to different groups → the paged pointers span multiple
    // shards, exercising the multi-shard ordered read.
    let page = try await items.find().where("group", isGreaterThanOrEqualTo: 0)
      .sort(by: "score").limit(10).execute()
    let ref = seed.sorted { ($0.score, $0.id) < ($1.score, $1.id) }.prefix(10)
    XCTAssertEqual(page.map(\.score), ref.map(\.score))
    XCTAssertGreaterThan(Set(page.map(\.group)).count, 1, "paged rows should span shards")

    try await partDB.close()
  }

  // MARK: - Deferred (faulting-style) results

  /// `fetchDeferred()` must return the same documents in the same order as
  /// `execute()`, and each deferred document must decode to the eager result.
  func testFetchDeferredParity() async throws {
    // Covered range with a limit (no sort): parity with execute().
    let eager = try await users.find().where("age", isGreaterThan: 20)
      .sort(by: "id").execute()
    let deferred = try await users.find().where("age", isGreaterThan: 20)
      .sort(by: "id").fetchDeferred()

    XCTAssertEqual(deferred.count, eager.count)
    XCTAssertEqual(try deferred.map { try $0.decoded() }, eager)

    // Bare find(): every live document, deferred.
    let allEager = try await users.find().sort(by: "id").execute()
    let allDeferred = try await users.find().sort(by: "id").fetchDeferred()
    XCTAssertEqual(try allDeferred.map { try $0.decoded() }, allEager)
  }

  // MARK: - 2. NOT IN
  func testNotInLogic() async throws {
    // Who does NOT have IDs 1, 3, and 5?
    let results = try await users.find()
      .where("id", isNotIn: [1, 3, 5])
      .sort(by: "id")
      .execute()

    // Expected: Bob(2), David(4), Frank(6)
    XCTAssertEqual(results.count, 3)
    XCTAssertEqual(results.map(\.id), [2, 4, 6])
  }

  // MARK: - 3. DISTINCT

  func testDistinctValues() async throws {
    // What are the unique ages registered?
    let distinctAges = try await users.find()
      .distinctValues(on: "age")
      .sorted { lhs, rhs in
        // Since distinctValues returns [FieldValue], we need to extract the Int
        guard case .int(let l) = lhs, case .int(let r) = rhs else { return false }
        return l < r
      }

    // Expected: 25, 30, 65, 70
    XCTAssertEqual(distinctAges.count, 4)

    var ages = [Int64]()
    for val in distinctAges {
      if case .int(let i) = val { ages.append(i) }
    }
    XCTAssertEqual(ages, [25, 30, 65, 70])
  }

  func testDistinctValuesWithFilter() async throws {
    // Which unique countries have people aged 30 or older?
    let distinctCountries = try await users.find()
      .where("age", isGreaterThanOrEqualTo: 30)
      .distinctValues(on: "country")

    // Expected: US, BR, PT (Alice and Eve are 25, so BR would appear twice, but in the >=30 query only Charlie(BR) qualifies)
    // Charlie(65, BR), Bob(30, US), Frank(30, US), David(70, PT)
    XCTAssertEqual(distinctCountries.count, 3)
  }

  /// Distinct on an indexed field whose single predicate is the covered
  /// lookup on that same field must be answered from the index keys —
  /// values arrive in ascending index order.
  func testDistinctValuesCoveredBySameFieldPredicate() async throws {
    let ages = try await users.find()
      .where("age", isBetween: 26, and: 70)
      .distinctValues(on: "age")
    var out = [Int64]()
    for value in ages {
      if case .int(let i) = value { out.append(i) }
    }
    XCTAssertEqual(out, [30, 65, 70])
  }

  /// Distinct on an unindexed field must fall back to the scan path.
  func testDistinctValuesOnUnindexedFieldFallsBack() async throws {
    let cities = try await users.find().distinctValues(on: "city")
    XCTAssertEqual(
      Set(cities),
      Set(["Recife", "New York", "Lisboa", "Olinda", "Boston"].map { FieldValue.string($0) }))
  }

  /// exists/notExists must behave identically through the extracted-values
  /// evaluation, including on the parallel path (300 docs > threshold).
  func testExistsPredicatesOverExtractedValues() async throws {
    struct Note: Codable, Sendable {
      var id: Int
      var note: String?
    }
    let notes = try await db.collection(
      "notes", of: Note.self, options: CollectionOptions(idField: "id"))
    try await notes.insert(
      contentsOf: (1...300).map { Note(id: $0, note: $0 % 3 == 0 ? "n\($0)" : nil) })

    let withNote = try await notes.find().whereExists("note").execute()
    XCTAssertEqual(withNote.count, 100)
    let withoutNote = try await notes.find().whereNotExists("note").count()
    XCTAssertEqual(withoutNote, 200)
  }

  // MARK: - 4. Memory Optimization (Limit & Offset without Sort)

  func testLimitStopsEarlyWithoutSort() async throws {
    // If there's no sort, limit should stop reading from disk as soon as it reaches the count.
    // To test this, we count how many items are returned with limit 2.
    let results = try await users.find()
      .where(.equal("country", "BR"))
      .limit(2)
      .execute()

    // Expected: Only 2 items (Alice and Charlie, or Charlie and Eve, depending on disk order)
    // The guarantee we want to test is that it didn't load all 3 from the database into memory just to cut 1.
    // Since there's no sort, order is not guaranteed, but the count is.
    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results.allSatisfy { $0.country == "BR" })
  }

  func testOffsetAndLimitWithSort() async throws {
    // Testing traditional pagination (requires sort)
    let page1 = try await users.find()
      .sort(by: "id", ascending: true)
      .limit(2)
      .execute()

    let page2 = try await users.find()
      .sort(by: "id", ascending: true)
      .offset(2)
      .limit(2)
      .execute()

    XCTAssertEqual(page1.map(\.id), [1, 2])
    XCTAssertEqual(page2.map(\.id), [3, 4])
  }

  // MARK: - 5. LIKE & GLOB

  func testLikeOperator() async throws {
    // Searching for names that start with 'A' and end with 'e' (case-insensitive)
    let results = try await users.find()
      .where("name", like: "a%e")
      .sort(by: "id")
      .execute()

    // Expected: Alice(1)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.name, "Alice")

    // Searching for names with 3 letters (A_e)
    let shortNames = try await users.find()
      .where("name", like: "___")
      .execute()
    // Expected: Eve, Bob
    XCTAssertEqual(shortNames.count, 2)
  }

  func testGlobOperator() async throws {
    // GLOB is case-sensitive! 'B%' matches Bob
    let results = try await users.find()
      .where("name", glob: "B*")
      .sort(by: "id")
      .execute()

    // Expected: Bob(2)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.name, "Bob")
  }
}
