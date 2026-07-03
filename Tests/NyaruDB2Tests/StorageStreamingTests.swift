//
//  StorageStreamingTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-03.
//

import XCTest

@testable import NyaruDB2

final class StorageStreamingTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!
  private var users: NyaruCollection<User>!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
  }

  private let userOptions = CollectionOptions(idField: "id")

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-stream-tests-\(UUID().uuidString)", isDirectory: true)
    db = try await NyaruDB(path: baseURL, options: .init(format: .json))
    users = try await db.collection("users", of: User.self, options: userOptions)
  }

  override func tearDown() async throws {
    try await db.close()
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  func testStreamingYieldsAllDocumentsSafely() async throws {
    let testData = (1...1000).map { User(id: $0, name: "User\($0)") }
    try await users.insert(contentsOf: testData)

    var seenIDs = Set<Int>()
    for try await user in users.stream() {
      seenIDs.insert(user.id)
    }

    XCTAssertEqual(seenIDs.count, 1000)
    XCTAssertEqual(seenIDs.min(), 1)
    XCTAssertEqual(seenIDs.max(), 1000)
  }
}
