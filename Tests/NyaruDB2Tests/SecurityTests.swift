//
//  SecurityTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-03.
//

import Crypto
import XCTest

@testable import NyaruDB2

final class SecurityTests: XCTestCase {
  private var baseURL: URL!
  private var db: NyaruDB!
  private var users: NyaruCollection<User>!

  private struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var country: String
  }

  private let userOptions = CollectionOptions(
    idField: "id",
    partitionKey: "country",
    indexedFields: ["name"]
  )

  override func setUp() async throws {
    try await super.setUp()
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-sec-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try await db.close()
    try? FileManager.default.removeItem(at: baseURL)
    try await super.tearDown()
  }

  func testEncryptionAndPartitionHashing() async throws {
    let key = SymmetricKey(size: .bits256)
    db = try NyaruDB(path: baseURL, options: .init(format: .msgpack, encryptionKey: key))
    users = try await db.collection("users", of: User.self, options: userOptions)

    try await users.insert(User(id: 1, name: "Alice", country: "BR"))

    // FORCES PERSISTENCE TO DISK HERE:
    try await db.sync()

    // 1. Verifies that the shard name was hashed (HMAC) and is not "BR.nyaru"
    let shardsDir = baseURL.appendingPathComponent("users/shards")
    let files =
      (try? FileManager.default.contentsOfDirectory(at: shardsDir, includingPropertiesForKeys: nil))
      ?? []
    let fileNames = files.map { $0.lastPathComponent }

    XCTAssertFalse(fileNames.contains("BR.nyaru"), "Partition key (BR) leaked in the file name!")
    XCTAssertTrue(
      fileNames.contains(where: { $0.hasSuffix(".nyaru") && $0.count > 40 }),
      "Should have a hashed file")

    // 2. Verifies that the manifest is encrypted (not readable JSON)
    let manifestURL = baseURL.appendingPathComponent("users/manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    XCTAssertFalse(manifestData.starts(with: Data("{".utf8)), "Manifest is in plain text!")

    // 3. Verifies that the index is encrypted
    let indexURL = baseURL.appendingPathComponent("users/indexes/name.idx")
    let indexData = try Data(contentsOf: indexURL)
    XCTAssertFalse(
      indexData.starts(with: Data([0x93])), "MessagePack index should not be in plaintext!")

    // 4. Ensures queries work with encryption enabled
    let alice = try await users.find().where("name", isEqualTo: "Alice").execute()
    XCTAssertEqual(alice.count, 1)
  }

  func testWrongEncryptionKeyFailsToOpen() async throws {
    let key1 = SymmetricKey(size: .bits256)
    let key2 = SymmetricKey(size: .bits256)

    // 1. Creates the database with key1 and inserts data
    db = try NyaruDB(path: baseURL, options: .init(format: .msgpack, encryptionKey: key1))
    users = try await db.collection("users", of: User.self, options: userOptions)
    try await users.insert(User(id: 1, name: "Alice", country: "BR"))
    try await db.close()  // Closes and saves everything

    // 2. Tries to reopen the same database with key2 (wrong)
    do {
      db = try NyaruDB(path: baseURL, options: .init(format: .msgpack, encryptionKey: key2))
      _ = try await db.collection("users", of: User.self, options: userOptions)

      // Tries to read the data (GCM should fail when opening the manifest or shard)
      _ = try await users.get(id: 1)
      XCTFail("Should have thrown a decryption error when using the wrong key")
    } catch {
      // Success! The database rejected the wrong key without crashing.
      // The error can be decryptionFailed or corrupted file, both are expected.
      print("Expected incorrect key error: \(error)")
    }
  }
}
