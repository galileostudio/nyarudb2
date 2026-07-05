//
//  QueryEngineTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-03.
//

import XCTest

@testable import NyaruDB2

final class QueryEngineTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!
  private var users: NyaruCollection<User>!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var age: Int
    var country: String
  }

  private let userOptions = CollectionOptions(
    idField: "id",
    partitionKey: "country",
    indexedFields: ["age", "name"]
  )

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-query-tests-\(UUID().uuidString)", isDirectory: true)
    db = try NyaruDB(path: baseURL, options: .init(format: .json))
    users = try await db.collection("users", of: User.self, options: userOptions)

    let testData = [
      User(id: 1, name: "Alice", age: 25, country: "BR"),
      User(id: 2, name: "Bob", age: 30, country: "US"),
      User(id: 3, name: "Charlie", age: 65, country: "BR"),
      User(id: 4, name: "David", age: 70, country: "PT"),
      User(id: 5, name: "Eve", age: 25, country: "BR"),
    ]
    try await users.insert(contentsOf: testData)
  }

  override func tearDown() async throws {
    try await db.close()
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  func testComplexBooleanLogic() async throws {
    let results = try await users.find()
      .where(
        .or([
          .equal("age", 25),
          .equal("age", 70),
        ])
      )
      .where(.not(.equal("country", "BR")))
      .sort(by: "id")
      .execute()

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.name, "David")
  }

  func testNotInAndDistinct() async throws {
    let notInResults = try await users.find()
      .where("id", isNotIn: [1, 3, 5])
      .sort(by: "id")
      .execute()
    XCTAssertEqual(notInResults.map(\.id), [2, 4])

    let distinctAges = try await users.find().distinctValues(on: "age")
    XCTAssertEqual(distinctAges.count, 4)
  }

  func testLikeAndGlob() async throws {
    let likeResults = try await users.find()
      .where("name", like: "a%")
      .sort(by: "id")
      .execute()
    XCTAssertEqual(likeResults.map(\.id), [1])

    let globResults = try await users.find()
      .where("name", glob: "[BC]*")
      .sort(by: "id")
      .execute()
    XCTAssertEqual(globResults.map(\.id), [2, 3])
  }

  func testOffsetWithoutSortThrows() async throws {
    do {
      _ = try await users.find().limit(2).offset(2).execute()
      XCTFail("Deveria ter lançado erro de paginação sem sort")
    } catch {
      // Esperado
    }
  }
  func testUpdateChangingPartitionKey() async throws {
    // Uses ID 99 to avoid conflicts with setUp data
    try await users.insert(User(id: 99, name: "Zeca", age: 25, country: "BR"))

    // Updates Zeca changing him to Portugal (shard PT)
    try await users.update(User(id: 99, name: "Zeca", age: 25, country: "PT"))

    // 1. The primary index should still find him
    let fetched = try await users.get(id: 99)
    XCTAssertEqual(fetched?.country, "PT")

    // 2. Partition query should not find Zeca in BR (only IDs 1, 3 and 5 from setUp should remain)
    let inBR = try await users.find().where("country", isEqualTo: "BR").execute()
    XCTAssertEqual(inBR.count, 3, "Should only have the 3 setUp records in BR")
    XCTAssertFalse(inBR.contains { $0.id == 99 })

    // 3. Partition query should find 2 in PT (Zeca + David from setUp)
    let inPT = try await users.find().where("country", isEqualTo: "PT").execute()
    XCTAssertEqual(inPT.count, 2)
    XCTAssertTrue(inPT.contains { $0.id == 99 })

    // 4. Total document count should be 6 (5 from setUp + 1 Zeca)
    let count = try await users.count()
    XCTAssertEqual(count, 6, "The old document was not tombstoned correctly")
  }

  func testPartialUpdatePatch() async throws {
    let changes: [String: FieldValue] = ["age": 26, "country": "PT"]
    try await users.patch(id: 1, changes: changes)

    // 1. Verifies the document was updated
    let fetched = try await users.get(id: 1)
    XCTAssertEqual(fetched?.age, 26)
    XCTAssertEqual(fetched?.country, "PT")

    // 2. Verifies the "age" index was updated (25 removed, 26 added)
    let age26 = try await users.find().where("age", isEqualTo: 26).execute()
    XCTAssertEqual(age26.count, 1)

    let age25 = try await users.find().where("age", isEqualTo: 25).execute()
    XCTAssertEqual(age25.count, 1)  // Eve still has 25
    XCTAssertFalse(age25.contains { $0.id == 1 })  // Alice no longer has 25

    // 3. Verifies the partition changed from BR to PT
    let inPT = try await users.find().where("country", isEqualTo: "PT").execute()
    XCTAssertTrue(inPT.contains { $0.id == 1 })
  }
}
