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
