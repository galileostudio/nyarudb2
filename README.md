# <img src="./img/nyaru.svg" alt="NyaruDB2" height="36" style="vertical-align:middle"/> NyaruDB2

**Embedded document database for Swift. No server, no schema, no ceremony.**

[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](https://github.com/apple/swift-package-manager)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/iOS%2015%2B%20%7C%20macOS%2013%2B-black)](https://developer.apple.com)
[![License](https://img.shields.io/badge/Apache%202.0-blue)](LICENSE.md)

Store, query, and stream any `Codable` type — directly on device, with indexed queries, optional AES-256-GCM encryption, crash recovery, and real backpressure streaming. No Core Data stack, no migrations, no SQL.

---

## Why NyaruDB2?

| | NyaruDB2 | SQLite / GRDB | Core Data | Realm |
|---|---|---|---|---|
| API | Codable, async/await | SQL / ORM | NSManagedObject | RealmObject |
| Schema | none | required | required | required |
| Encryption | built-in (AES-256-GCM) | SQLCipher (separate dep) | ❌ | built-in |
| Disk size | **~10× smaller** with gzip | baseline | baseline | baseline |
| Thread model | Swift Actors | varies | main-thread traps | thread-confined |
| Crash recovery | automatic (CRC-32 + dirty flag) | WAL | ❌ | ✅ |

NyaruDB2 is a good fit when:
- Your data is document-shaped and changes schema between app versions
- You need per-record encryption without a third-party dependency
- You want to stream large datasets without materializing them in memory
- You are already writing async/await Swift and want a storage layer that feels the same

---

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/galileostudio/NyaruDB2.git", from: "0.1.0-alpha")
],
targets: [
    .target(name: "YourApp", dependencies: ["NyaruDB2"])
]
```

**Requirements:** Swift 5.9+ · iOS 15+ · macOS 13+

---

## Quick Start

```swift
import NyaruDB2

struct Article: Codable, Sendable {
    let id: Int
    let title: String
    let author: String
    let publishedAt: Date
}

// Open the database (creates the directory if needed)
let db = try await NyaruDB(path: "/path/to/db")

// Open a typed collection with secondary indexes
let articles = try await db.collection(
    "articles",
    of: Article.self,
    options: CollectionOptions(
        idField: "id",
        indexedFields: ["author", "publishedAt"],
        compression: .gzip
    )
)

// Insert
try await articles.insert(Article(id: 1, title: "Hello", author: "Ana", publishedAt: .now))

// Bulk insert — validates all documents before writing any
try await articles.insert(contentsOf: moreArticles)

// Query
let recent = try await articles.find()
    .where("publishedAt", isGreaterThan: Date().addingTimeInterval(-86400 * 7))
    .sort(by: "publishedAt", ascending: false)
    .limit(20)
    .execute()

// Partial update — only the changed fields; result is validated against Article before writing
try await articles.patch(id: 1, changes: ["title": "Updated title"])

// Delete by predicate
let removed = try await articles.find()
    .where("author", isEqualTo: "spam-bot")
    .delete()

// Pull-based stream — memory stays bounded regardless of collection size
for try await article in articles.stream(batchSize: 64) {
    process(article)
}

// Reclaim space left by deletions
try await articles.compact()

try await db.close()
```

---

## Core Concepts

### Collections

A collection is a typed, actor-isolated handle to a set of documents stored under a shared directory. Opening the same collection twice returns a cached handle; there is no risk of concurrent writers corrupting it.

```swift
let users = try await db.collection("users", of: User.self, options: options)
```

`CollectionOptions` lets you configure the primary key field, secondary indexes, partition key, compression algorithm, and encryption key per collection.

### Indexes

The `idField` is always indexed. Declare additional fields at open time:

```swift
CollectionOptions(
    idField: "id",
    indexedFields: ["email", "region", "score"]
)
```

You can add or remove indexed fields between opens — NyaruDB2 builds missing indexes with a single scan and removes dropped ones. The `idField`, `partitionKey`, and `compression` are frozen after the first open.

Indexed operations run in O(log n). Unindexed fields fall back to a full scan with the predicate applied in memory.

### Queries

```swift
// Equality, comparisons, ranges
users.find()
    .where("score", isGreaterThanOrEqualTo: 100)
    .where("score", isLessThan: 500)

// Set membership
users.find().where("tier", isIn: ["gold", "platinum"])

// Text predicates
users.find().where("email", endsWith: "@example.com")
users.find().where("username", like: "ana%")      // SQL-style wildcards
users.find().where("slug", glob: "2026-*-post")   // glob wildcards

// Logical composition
users.find().and(
    .where("age", isGreaterThanOrEqualTo: 18),
    .where("country", isEqualTo: "BR")
)

// Existence
users.find().whereExists("phoneNumber")

// Sort, page
users.find()
    .sort(by: "name")
    .offset(40)
    .limit(20)
    .execute()

// Inspect the plan before running
let plan = await users.find().where("score", isGreaterThan: 50).explain()
```

### Partitioning

When documents share a partition key (e.g. `region`, `category`), route them to dedicated shard files:

```swift
CollectionOptions(idField: "id", partitionKey: "region")
```

Queries that filter on the partition key touch only the matching shard. Full scans read shards concurrently.

### Encryption

```swift
// Recommended: random key stored in the Keychain
let key = NyaruCrypto.generateRandomKey()

// Password-derived key (PBKDF2-HMAC-SHA256, 210k iterations)
let salt = NyaruCrypto.generateSalt()     // persist alongside the database
let key  = try NyaruCrypto.deriveKey(fromPassword: "passphrase", salt: salt)

let db = try await NyaruDB(path: path, options: DatabaseOptions(encryptionKey: key))
```

Encryption covers every record payload, every index snapshot, and the collection manifest. Shard filenames are HMAC-derived so partition values are not visible in the filesystem. Opening with the wrong key fails immediately at the manifest with `NyaruError.decryptionFailed`.

> Use `generateRandomKey()` + Keychain for new integrations. `deriveKey(fromPassword:salt:)` is for cases where the key must be re-derived from user input; its PBKDF2 cost resists offline brute force, but a hardware-bound key is always stronger.

### Crash Recovery

Every record carries a CRC-32 checksum. The shard file header has a dirty flag that is set on the first write and cleared on clean close. On the next open:

1. Any shard whose flag is still set is fully scanned.
2. Records with bad checksums are tombstoned.
3. Torn trailing writes are truncated.
4. All indexes are rebuilt from the recovered data.

The operation is automatic and requires no intervention.

### Compaction

Deleted documents are tombstoned in-place — space is not immediately reclaimed. Call `compact()` to rewrite shards and rebuild indexes:

```swift
// Compact a specific collection
try await articles.compact()

// Only compact if fragmentation is worth it
if await articles.needsCompaction() {
    try await articles.compact()
}
```

Compaction preserves encryption and compression, runs up to 3 shards concurrently, and rebuilds indexes per shard as each one finishes (no stale-pointer window).

---

## Serialization & Compression

| Option | Notes |
|---|---|
| `.gzip` | Portable, ~10× size reduction on typical document payloads |
| `.lzfse` | Apple platforms only; faster decompression, moderate ratio |
| `.lz4` | Apple platforms only; recommended only for large documents |
| `.none` | No compression |
| `format: .msgpack` | Binary serialization; use `.json` for human-readable storage |

Default recommendation: `gzip` + `msgpack` for production; `none` + `json` for debugging.

---

## Error Handling

All operations throw `NyaruError`. Common cases:

```swift
do {
    try await users.insert(user)
} catch NyaruError.duplicateID(let id) {
    // Document with this id already exists
} catch NyaruError.decryptionFailed {
    // Wrong key or corrupted record
} catch NyaruError.collectionTypeMismatch(let name) {
    // idField / partitionKey / compression changed between opens
}
```

---

## License

Apache 2.0 © 2026 [galileostudio](https://github.com/galileostudio). See [LICENSE](LICENSE.md).

---

## Acknowledgements

Inspired by the original [NyaruDB](https://github.com/kelp404/NyaruDB) by kelp404.
