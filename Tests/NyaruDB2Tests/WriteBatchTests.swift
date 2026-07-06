//
//  WriteBatchTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-06.
//

import XCTest

@testable import NyaruDB2

final class WriteBatchTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!
  private var users: NyaruCollection<User>!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var age: Int
    var city: String
  }

  private func user(_ id: Int, age: Int = 30, city: String = "BR") -> User {
    User(id: id, name: "user\(id)", age: age, city: city)
  }

  override func setUp() async throws {
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-writebatch-\(UUID().uuidString)", isDirectory: true)
    db = try NyaruDB(path: baseURL)
    users = try await db.collection(
      "users", of: User.self,
      options: CollectionOptions(idField: "id", indexedFields: ["age"]))
  }

  override func tearDown() async throws {
    try await db?.close()
    try? FileManager.default.removeItem(at: baseURL)
  }

  func testMixedOperationsApply() async throws {
    try await users.insert(contentsOf: [user(1, age: 10), user(2, age: 20), user(3, age: 30)])

    try await users.writeBatch { batch in
      batch.insert(user(4, age: 40))
      batch.update(User(id: 1, name: "renamed", age: 11, city: "BR"))
      batch.upsert(user(5, age: 50))  // new
      batch.upsert(User(id: 2, name: "user2", age: 21, city: "BR"))  // replace
      batch.delete(id: 3)
    }

    let count = try await users.count()
    XCTAssertEqual(count, 4)
    let u1 = try await users.get(id: 1)
    XCTAssertEqual(u1?.name, "renamed")
    XCTAssertEqual(u1?.age, 11)
    let u3 = try await users.get(id: 3)
    XCTAssertNil(u3)
    let u5 = try await users.get(id: 5)
    XCTAssertEqual(u5, user(5, age: 50))

    // Secondary index must reflect old keys removed and new keys added.
    let age10 = try await users.find().where("age", isEqualTo: 10).execute()
    XCTAssertTrue(age10.isEmpty)
    let age11 = try await users.find().where("age", isEqualTo: 11).execute()
    XCTAssertEqual(age11.map(\.id), [1])
    let age30 = try await users.find().where("age", isEqualTo: 30).execute()
    XCTAssertTrue(age30.isEmpty)
    let age40 = try await users.find().where("age", isEqualTo: 40).execute()
    XCTAssertEqual(age40.map(\.id), [4])
  }

  func testDuplicateInsertLeavesNothingApplied() async throws {
    try await users.insert(contentsOf: [user(1, age: 10), user(3, age: 30)])

    do {
      try await users.writeBatch { batch in
        batch.insert(user(2, age: 20))
        batch.delete(id: 3)
        batch.insert(user(1, age: 99))  // duplicate of an existing id
      }
      XCTFail("expected duplicateID")
    } catch NyaruError.duplicateID {
      // expected
    }

    let count = try await users.count()
    XCTAssertEqual(count, 2)
    let u1 = try await users.get(id: 1)
    XCTAssertEqual(u1?.age, 10)
    let u3 = try await users.get(id: 3)
    XCTAssertEqual(u3?.age, 30, "delete queued before the failing insert must not apply")
    let u2 = try await users.get(id: 2)
    XCTAssertNil(u2)
    let age20 = try await users.find().where("age", isEqualTo: 20).count()
    XCTAssertEqual(age20, 0)
  }

  func testUpdateMissingLeavesNothingApplied() async throws {
    do {
      try await users.writeBatch { batch in
        batch.insert(user(1))
        batch.update(user(42))  // does not exist
      }
      XCTFail("expected documentNotFound")
    } catch NyaruError.documentNotFound {
      // expected
    }
    let count = try await users.count()
    XCTAssertEqual(count, 0)
  }

  func testConflictingOperationsOnSameIDRejected() async throws {
    try await users.insert(user(1))
    do {
      try await users.writeBatch { batch in
        batch.update(User(id: 1, name: "a", age: 1, city: "BR"))
        batch.delete(id: 1)
      }
      XCTFail("expected unsupportedOperation")
    } catch NyaruError.unsupportedOperation {
      // expected
    }
    let u1 = try await users.get(id: 1)
    XCTAssertEqual(u1, user(1))
  }

  func testThrowingBodyWritesNothing() async throws {
    struct Boom: Error {}
    do {
      try await users.writeBatch { batch in
        batch.insert(user(1))
        throw Boom()
      }
      XCTFail("expected Boom")
    } catch is Boom {
      // expected
    }
    let count = try await users.count()
    XCTAssertEqual(count, 0)
  }

  func testDeleteUnknownIDIsSkipped() async throws {
    try await users.insert(user(1))
    try await users.writeBatch { batch in
      batch.delete(id: 999)
      batch.insert(user(2))
    }
    let count = try await users.count()
    XCTAssertEqual(count, 2)
  }

  func testPureInsertBatchTakesFastPathWithSameSemantics() async throws {
    try await users.writeBatch { batch in
      batch.insert(contentsOf: (1...100).map { self.user($0, age: $0) })
    }
    let count = try await users.count()
    XCTAssertEqual(count, 100)

    do {
      try await users.writeBatch { batch in
        batch.insert(user(101))
        batch.insert(user(50))  // duplicate
      }
      XCTFail("expected duplicateID")
    } catch NyaruError.duplicateID {
      // expected
    }
    let after = try await users.count()
    XCTAssertEqual(after, 100)
  }

  func testBatchWithPartitionMoveSurvivesReopen() async throws {
    let parted = try await db.collection(
      "orders", of: User.self,
      options: CollectionOptions(idField: "id", partitionKey: "city", indexedFields: ["age"]))
    try await parted.insert(contentsOf: [user(1, age: 10, city: "BR"), user(2, age: 20, city: "PT")])

    try await parted.writeBatch { batch in
      // Update that moves the document to another shard.
      batch.update(User(id: 1, name: "user1", age: 11, city: "PT"))
      batch.insert(self.user(3, age: 30, city: "BR"))
      batch.delete(id: 2)
    }
    try await db.close()

    db = try NyaruDB(path: baseURL)
    let reopened = try await db.collection(
      "orders", of: User.self,
      options: CollectionOptions(idField: "id", partitionKey: "city", indexedFields: ["age"]))
    let count = try await reopened.count()
    XCTAssertEqual(count, 2)
    let u1 = try await reopened.get(id: 1)
    XCTAssertEqual(u1?.city, "PT")
    XCTAssertEqual(u1?.age, 11)
    let byCity = try await reopened.find().where("city", isEqualTo: "PT").execute()
    XCTAssertEqual(byCity.map(\.id).sorted(), [1])
  }
}
