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
    try await db?.close()
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  private func setupDB(format: SerializationFormat) async throws {
    db = try NyaruDB(path: baseURL, options: .init(format: format))
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

  private struct RichDoc: Codable, Sendable {
    var id: Int
    var name: String
    var score: Double
    var active: Bool
    var tags: [String]
    var meta: [String: Int]
    var note: String?
  }

  /// The MsgPack skip-scan extractor must produce exactly the same field
  /// values as a full parse, while skipping containers and absent fields.
  func testMsgPackSkipScanMatchesFullParse() throws {
    let doc = RichDoc(
      id: 42, name: "skip", score: 2.5, active: true,
      tags: ["a", "b"], meta: ["x": 1, "y": 2], note: nil)
    let data = try Serializer.encode(doc, format: .msgpack)

    let fields = ["id", "name", "score", "active", "tags", "meta", "note", "missing"]
    let scanned = Serializer.extractFieldValues(from: data, fields: fields, format: .msgpack)

    let dict = try FieldExtractor.parse(data, using: .msgpack)
    var parsed: [String: FieldValue] = [:]
    for field in fields {
      if let value = FieldExtractor.value(in: dict, path: field) {
        parsed[field] = value
      }
    }

    XCTAssertEqual(scanned, parsed)
    XCTAssertEqual(scanned["id"], .int(42))
    XCTAssertEqual(scanned["name"], .string("skip"))
    XCTAssertEqual(scanned["score"], .double(2.5))
    XCTAssertEqual(scanned["active"], .bool(true))
    // Containers and absent fields are omitted, not mis-decoded.
    XCTAssertNil(scanned["tags"])
    XCTAssertNil(scanned["meta"])
    XCTAssertNil(scanned["note"])
    XCTAssertNil(scanned["missing"])
  }

  /// Dot paths cannot use the skip-scan and must fall back to a full parse.
  func testExtractFieldValuesDotPathFallback() throws {
    struct Nested: Codable {
      struct Inner: Codable { var city: String }
      var id: Int
      var address: Inner
    }
    let data = try Serializer.encode(
      Nested(id: 1, address: .init(city: "Recife")), format: .msgpack)
    let values = Serializer.extractFieldValues(
      from: data, fields: ["id", "address.city"], format: .msgpack)
    XCTAssertEqual(values["id"], .int(1))
    XCTAssertEqual(values["address.city"], .string("Recife"))
  }
}
