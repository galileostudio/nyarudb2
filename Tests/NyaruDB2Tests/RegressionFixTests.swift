import Crypto
import XCTest

@testable import NyaruDB2

/// Regression tests for the fixes applied in this round.
final class RegressionFixTests: XCTestCase {
  var baseURL: URL!

  override func setUp() async throws {
    baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-regression-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: baseURL)
  }

  struct User: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var age: Int
    var city: String
  }

  func user(_ id: Int, age: Int = 30, city: String = "BR") -> User {
    User(id: id, name: "user\(id)", age: age, city: city)
  }

  // MARK: - Fix 1: encrypted manifest survives index evolution

  func testEncryptedManifestSurvivesIndexEvolution() async throws {
    let key = NyaruCrypto.generateRandomKey()
    let opts = DatabaseOptions(encryptionKey: key)
    do {
      let db = try NyaruDB(path: baseURL, options: opts)
      let users = try await db.collection(
        "users", of: User.self,
        options: CollectionOptions(idField: "id", indexedFields: ["age"]))
      try await users.insert(user(1))
      try await db.close()
    }
    do {
      let db = try NyaruDB(path: baseURL, options: opts)
      let users = try await db.collection(
        "users", of: User.self,
        options: CollectionOptions(idField: "id", indexedFields: ["age", "name"]))
      try await users.insert(user(2))
      try await db.close()
    }
    let db = try NyaruDB(path: baseURL, options: opts)
    let users = try await db.collection(
      "users", of: User.self,
      options: CollectionOptions(idField: "id", indexedFields: ["age", "name"]))

    let u1 = try await users.get(id: 1)
    XCTAssertEqual(u1, user(1))
    let u2 = try await users.get(id: 2)
    XCTAssertEqual(u2, user(2))

    let listed = try await db.listCollections()
    XCTAssertEqual(listed, ["users"])
    try await db.close()
  }

  // MARK: - Fix 3: patch validates BEFORE anything is written

  func testPatchRejectionDoesNotPersistPoison() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self, options: CollectionOptions(idField: "id"))
    try await users.insert(user(1, age: 30))

    do {
      try await users.patch(id: 1, changes: ["age": .string("banana")])
      XCTFail("patch should have been rejected")
    } catch {}

    let fetched = try await users.get(id: 1)
    XCTAssertEqual(fetched, user(1, age: 30))

    try await users.patch(id: 1, changes: ["age": 44])
    let fetched2 = try await users.get(id: 1)
    XCTAssertEqual(fetched2?.age, 44)
    try await db.close()

    let db2 = try NyaruDB(path: baseURL)
    let users2 = try await db2.collection(
      "users", of: User.self, options: CollectionOptions(idField: "id"))
    let fetched3 = try await users2.get(id: 1)
    XCTAssertEqual(fetched3?.age, 44)
    try await db2.close()
  }

  func testPatchRejectsDotPathAndIDChange() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self, options: CollectionOptions(idField: "id"))
    try await users.insert(user(1))
    do {
      try await users.patch(id: 1, changes: ["address.city": .string("Recife")])
      XCTFail("dot-path key must be rejected")
    } catch {}
    do {
      try await users.patch(id: 1, changes: ["id": 2])
      XCTFail("id change must be rejected")
    } catch {}
    let fetched = try await users.get(id: 1)
    XCTAssertEqual(fetched, user(1))
    try await db.close()
  }

  // MARK: - Fix 2: reads never return the wrong document during compact

  func testGetNeverReturnsWrongDocumentDuringCompact() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self, options: CollectionOptions(idField: "id"))
    try await users.insert(contentsOf: (1...300).map { user($0, age: $0) })
    for id in stride(from: 1, through: 300, by: 2) {
      _ = try await users.delete(id: id)
    }
    let survivors = Array(stride(from: 2, through: 300, by: 2))

    let readers = Task { () -> Bool in
      var identityHeld = true
      for _ in 0..<50 {
        for id in survivors.shuffled().prefix(20) {
          if let doc = try? await users.get(id: id), doc.id != id {
            identityHeld = false
          }
        }
      }
      return identityHeld
    }
    try await users.compact()
    let identityHeld = await readers.value
    XCTAssertTrue(identityHeld, "get(id:) returned a document with a different id")

    for id in survivors {
      let doc = try await users.get(id: id)
      XCTAssertEqual(doc?.id, id)
    }
    let count = try await users.count()
    XCTAssertEqual(count, survivors.count)
    try await db.close()
  }

  func testCompactPreservesDataAndIndexesAcrossReopen() async throws {
    do {
      let db = try NyaruDB(path: baseURL)
      let users = try await db.collection(
        "users", of: User.self,
        options: CollectionOptions(idField: "id", partitionKey: "city", indexedFields: ["age"]))
      try await users.insert(
        contentsOf: (1...50).map { user($0, age: $0, city: $0 % 2 == 0 ? "BR" : "PT") })
      for id in 1...25 { _ = try await users.delete(id: id) }
      try await users.compact()
      let found = try await users.find().where("age", isEqualTo: 40).execute()
      XCTAssertEqual(found.map(\.id), [40])
      try await db.close()
    }
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self,
      options: CollectionOptions(idField: "id", partitionKey: "city", indexedFields: ["age"]))
    let count = try await users.count()
    XCTAssertEqual(count, 25)
    let fetched = try await users.get(id: 40)
    XCTAssertEqual(fetched?.age, 40)
    try await db.close()
  }

  // MARK: - Fix: index evolution must not race compaction

  /// Adding an indexed field while `compact()` runs must produce a complete
  /// index. Before the fix, `setIndexedFields` bypassed the compaction gate:
  /// its rebuild could read post-compaction offsets that the subsequent
  /// pointer remap silently dropped as "did not survive compaction".
  func testIndexEvolutionDuringCompactKeepsIndexComplete() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self, options: CollectionOptions(idField: "id"))
    try await users.insert(contentsOf: (1...400).map { user($0, age: $0) })
    for id in stride(from: 1, through: 400, by: 2) {
      _ = try await users.delete(id: id)
    }

    let compactTask = Task { try await users.compact() }
    let evolveTask = Task {
      try await db.collection(
        "users", of: User.self,
        options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    }
    try await compactTask.value
    let evolved = try await evolveTask.value

    // A covered count is answered from the index alone — dropped entries
    // make it fall short of the 200 survivors.
    let indexCount = try await evolved.find()
      .where("age", isGreaterThanOrEqualTo: 0).count()
    XCTAssertEqual(indexCount, 200, "index rebuilt during compact lost entries")
    let scanned = try await evolved.all().count
    XCTAssertEqual(scanned, 200)
    try await db.close()
  }

  // MARK: - Fix: queries must not hold pointers across a compact

  /// Indexed queries running concurrently with delete+compact cycles must
  /// always return exactly the matching documents. Before the fix, the query
  /// engine resolved index pointers in one actor call and fetched them in
  /// another; a compact() scheduled between the two rewrote the shard files
  /// and the fetch read stale offsets.
  func testIndexedQueriesDuringCompactStayConsistent() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self,
      options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    try await users.insert(contentsOf: (1...300).map { user($0, age: $0) })
    let expected = Array(100...200)

    // Each round deletes documents BEFORE the queried range and compacts,
    // shifting the surviving records' offsets while the expected result set
    // stays constant.
    let compactor = Task {
      for batchStart in stride(from: 1, to: 99, by: 20) {
        let victims = (batchStart..<min(batchStart + 20, 99)).filter { $0 % 2 == 1 }
        _ = try await users.delete(ids: victims)
        try await users.compact()
      }
    }

    var consistent = true
    for _ in 0..<40 {
      let docs = try await users.find()
        .where("age", isBetween: 100, and: 200).execute()
      if docs.map(\.id).sorted() != expected { consistent = false }
    }
    try await compactor.value
    XCTAssertTrue(consistent, "query saw stale or missing documents during compact")

    let final = try await users.find()
      .where("age", isBetween: 100, and: 200).execute()
    XCTAssertEqual(final.map(\.id).sorted(), expected)
    try await db.close()
  }

  // MARK: - Fix 4: pull-based stream

  func testStreamDeliversAllWithSmallBatches() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self,
      options: CollectionOptions(idField: "id", partitionKey: "city"))
    let brs = (1...57).map { user($0, city: "BR") }
    let pts = (58...100).map { user($0, city: "PT") }
    try await users.insert(contentsOf: brs + pts)

    var seen = Set<Int>()
    for try await u in users.stream(batchSize: 7) {
      XCTAssertTrue(seen.insert(u.id).inserted, "duplicate \(u.id) in stream")
    }
    XCTAssertEqual(seen.count, 100)

    var taken = 0
    for try await _ in users.stream(batchSize: 3) {
      taken += 1
      if taken == 5 { break }
    }
    XCTAssertEqual(taken, 5)
    try await db.close()
  }

  // MARK: - peekDirty: crash-sim reopen rebuilds indexes from data

  func testCrashReopenSeesPostSyncWrites() async throws {
    do {
      let db = try NyaruDB(path: baseURL)
      let users = try await db.collection(
        "users", of: User.self,
        options: CollectionOptions(idField: "id", indexedFields: ["age"]))
      try await users.insert(user(1))
      try await db.sync()
      try await users.insert(user(2))
    }
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self,
      options: CollectionOptions(idField: "id", indexedFields: ["age"]))
    let fetched = try await users.get(id: 2)
    XCTAssertEqual(fetched, user(2))
    let count = try await users.count()
    XCTAssertEqual(count, 2)
    do {
      try await users.insert(user(2))
      XCTFail("duplicate must be rejected after rebuild")
    } catch {}
    try await db.close()
  }

  // MARK: - Fix 7: PBKDF2 key derivation

  func testPBKDF2IsDeterministicAndSaltSensitive() throws {
    let salt = Data("fixed-salt-16byte".utf8)
    let k1 = try NyaruCrypto.deriveKey(
      fromPassword: "correct horse", salt: salt, using: .pbkdf2sha256(iterations: 1_000))
    let k2 = try NyaruCrypto.deriveKey(
      fromPassword: "correct horse", salt: salt, using: .pbkdf2sha256(iterations: 1_000))
    let k3 = try NyaruCrypto.deriveKey(
      fromPassword: "correct horse", salt: Data("other-salt".utf8),
      using: .pbkdf2sha256(iterations: 1_000))
    let k4 = try NyaruCrypto.deriveKey(
      fromPassword: "wrong horse", salt: salt, using: .pbkdf2sha256(iterations: 1_000))
    let bytes = { (k: SymmetricKey) in k.withUnsafeBytes { Data($0) } }
    XCTAssertEqual(bytes(k1), bytes(k2))
    XCTAssertNotEqual(bytes(k1), bytes(k3))
    XCTAssertNotEqual(bytes(k1), bytes(k4))
  }

  func testPBKDF2KeyOpensEncryptedDatabase() async throws {
    let salt = NyaruCrypto.generateSalt()
    let key = try NyaruCrypto.deriveKey(
      fromPassword: "s3nh4", salt: salt, using: .pbkdf2sha256(iterations: 1_000))
    do {
      let db = try NyaruDB(path: baseURL, options: DatabaseOptions(encryptionKey: key))
      let users = try await db.collection(
        "users", of: User.self, options: CollectionOptions(idField: "id"))
      try await users.insert(user(7))
      try await db.close()
    }
    // Re-derive from the same password/salt: must open and read.
    let sameKey = try NyaruCrypto.deriveKey(
      fromPassword: "s3nh4", salt: salt, using: .pbkdf2sha256(iterations: 1_000))
    do {
      let db = try NyaruDB(path: baseURL, options: DatabaseOptions(encryptionKey: sameKey))
      let users = try await db.collection(
        "users", of: User.self, options: CollectionOptions(idField: "id"))
      let fetched = try await users.get(id: 7)
      XCTAssertEqual(fetched, user(7))
      try await db.close()
    }
    // Wrong password must fail loudly at open (manifest is the key check).
    let wrong = try NyaruCrypto.deriveKey(
      fromPassword: "errada", salt: salt, using: .pbkdf2sha256(iterations: 1_000))
    do {
      let db = try NyaruDB(path: baseURL, options: DatabaseOptions(encryptionKey: wrong))
      _ = try await db.collection(
        "users", of: User.self, options: CollectionOptions(idField: "id"))
      XCTFail("wrong key must fail at open")
    } catch {}
  }

  // MARK: - Fix: Mirror metadata extraction must match the encoded payload

  enum Tier: String, Codable, Sendable {
    case free, pro
  }

  struct Account: Codable, Sendable, Equatable {
    var id: Int
    var tier: Tier
    var createdAt: Date
    var note: String?
  }

  /// Documents whose indexed fields Mirror cannot convert (enums, Dates) must
  /// still be indexed from the encoded payload. Before the fix, the Mirror
  /// fast path silently dropped these index entries, so queries missed
  /// documents that a disk rebuild would have found.
  func testUnsupportedMirrorTypesAreStillIndexed() async throws {
    let db = try NyaruDB(path: baseURL)
    let accounts = try await db.collection(
      "accounts", of: Account.self,
      options: CollectionOptions(idField: "id", indexedFields: ["tier"]))

    let created = Date(timeIntervalSinceReferenceDate: 700_000_000)
    try await accounts.insert(Account(id: 1, tier: .pro, createdAt: created, note: nil))
    try await accounts.insert(contentsOf: [
      Account(id: 2, tier: .free, createdAt: created, note: "x"),
      Account(id: 3, tier: .pro, createdAt: created, note: nil),
    ])

    // The "tier" index must serve this equality query.
    let pros = try await accounts.find()
      .where("tier", isEqualTo: "pro")
      .execute()
    XCTAssertEqual(Set(pros.map(\.id)), [1, 3])

    // The entries must match what a rebuild-from-disk produces.
    let statsBefore = try await accounts.stats()
    try await accounts.compact()
    let prosAfter = try await accounts.find()
      .where("tier", isEqualTo: "pro")
      .execute()
    XCTAssertEqual(Set(prosAfter.map(\.id)), [1, 3])
    let statsAfter = try await accounts.stats()
    XCTAssertEqual(statsBefore.indexes["tier"], statsAfter.indexes["tier"])

    try await db.close()
  }

  // MARK: - Fix: descending sort on the indexed field must page from the top

  /// Pagination pushdown used to slice the ascending index order even for
  /// descending sorts, returning the *lowest* keys sorted descending instead
  /// of the highest.
  func testDescendingSortPaginatesFromTheTop() async throws {
    let db = try NyaruDB(path: baseURL)
    let users = try await db.collection(
      "users", of: User.self, options: CollectionOptions(idField: "id"))
    try await users.insert(contentsOf: (1...10).map { user($0) })

    let top = try await users.find()
      .where("id", isGreaterThan: 0)
      .sort(by: "id", ascending: false)
      .limit(3)
      .execute()
    XCTAssertEqual(top.map(\.id), [10, 9, 8])

    let secondPage = try await users.find()
      .where("id", isGreaterThan: 0)
      .sort(by: "id", ascending: false)
      .offset(3)
      .limit(3)
      .execute()
    XCTAssertEqual(secondPage.map(\.id), [7, 6, 5])

    try await db.close()
  }
}
