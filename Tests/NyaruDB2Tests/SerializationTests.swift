//
//  SerializationTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-03.
//

import XCTest

@testable import NyaruDB2

final class SerializationTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!
  private var users: NyaruCollection<User>!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var age: Int
    var isActive: Bool
  }

  private let userOptions = CollectionOptions(
    idField: "id",
    indexedFields: ["age", "isActive"]
  )

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-serial-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try await db.close()
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  private func setupDB(format: SerializationFormat) async throws {
    db = try await NyaruDB(path: baseURL, options: .init(format: format))
    users = try await db.collection("users", of: User.self, options: userOptions)
  }

  func testMsgPackBoolAndIntNotCorrupted() async throws {
    try await setupDB(format: .msgpack)

    let testData = [
      User(id: 1, name: "Alice", age: 1, isActive: true),
      User(id: 2, name: "Bob", age: 0, isActive: false),
    ]
    try await users.insert(contentsOf: testData)

    // If AnyDecodable fails, isActive (true) becomes Int(1) and disappears from the index.
    let activeUsers = try await users.find().where("isActive", isEqualTo: true).execute()
    XCTAssertEqual(activeUsers.count, 1)
    XCTAssertEqual(activeUsers.first?.name, "Alice")

    // Ensures that age 0 or 1 didn't accidentally become a boolean
    let age1 = try await users.find().where("age", isEqualTo: 1).execute()
    XCTAssertEqual(age1.count, 1)

    let age0 = try await users.find().where("age", isEqualTo: 0).execute()
    XCTAssertEqual(age0.count, 1)
  }
}
