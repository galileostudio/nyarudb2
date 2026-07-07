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
    .package(url: "https://github.com/galileostudio/NyaruDB2.git", from: "0.3.0")
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
let db = try NyaruDB(
    path: "/path/to/db",
    options: DatabaseOptions(compression: .gzip, format: .msgpack)
)

// Open a typed collection with secondary indexes
let articles = try await db.collection(
    "articles",
    of: Article.self,
    options: CollectionOptions(
        idField: "id",
        indexedFields: ["author", "publishedAt"]
    )
)

// Insert
try await articles.insert(Article(id: 1, title: "Hello", author: "Ana", publishedAt: .now))

// Bulk insert — validates all documents before writing any
try await articles.insert(contentsOf: moreArticles)

// Write batch — accumulate mixed operations (synchronously, no await),
// validated up front and applied all-or-nothing against errors
try await articles.writeBatch { batch in
    batch.insert(newArticle)
    batch.update(editedArticle)
    batch.upsert(maybeNewArticle)
    batch.delete(id: 42)
}

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

// Delete many by id in a single batched pass
try await articles.delete(ids: [3, 5, 8])

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

`CollectionOptions` configures the primary key field, secondary indexes, and the partition key. Compression, serialization format, and the encryption key are database-wide (`DatabaseOptions`) and are frozen into each collection's manifest when it is first created.

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

// Logical composition — chained wheres are AND; use Predicate for OR/NOT
users.find()
    .where("age", isGreaterThanOrEqualTo: 18)
    .where(.or([
        .equal("country", "BR"),
        .equal("country", "PT"),
    ]))

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

### Atomic write batches

`writeBatch` accumulates mixed operations and applies them as one all-or-nothing unit:

```swift
try await users.writeBatch { batch in
    batch.insert(newUser)
    batch.update(changedUser)
    batch.delete(id: retiredUserID)
}
```

Every operation is validated **before** anything is written: a duplicate id, a missing update target, a thrown body, or two operations on the same id abort the batch with zero side effects, and a failed write is rolled back. This is atomicity against *errors*, not crashes — NyaruDB2 has no write-ahead log by design, so a process crash mid-flush can persist part of the batch (per-record CRC + dirty-flag recovery still guarantees integrity of what was written). At most one operation may target a given document id per batch.

There are exactly three ways to write, each with a distinct purpose and the same all-or-nothing validation:

| | Use when |
|---|---|
| `insert(_:)` / `update(_:)` / `upsert(_:)` / `delete(id:)` | One document at a time |
| `insert(contentsOf:)` | You already hold an array of new documents |
| `writeBatch(_:)` | Accumulating from multiple sources, or mixing inserts with updates/deletes |

An insert-only `writeBatch` takes the same fast path as `insert(contentsOf:)` — pick by ergonomics, not performance.

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

let db = try NyaruDB(path: path, options: DatabaseOptions(encryptionKey: key))
```

Encryption covers every record payload, every index snapshot, and the collection manifest. Shard filenames are HMAC-derived so partition values are not visible in the filesystem. Opening with the wrong key fails immediately at the manifest with `NyaruError.decryptionFailed`.

> Use `generateRandomKey()` + Keychain for new integrations. `deriveKey(fromPassword:salt:)` is for cases where the key must be re-derived from user input; its PBKDF2 cost resists offline brute force, but a hardware-bound key is always stronger.

### Crash Recovery & Fast Opens

Every record carries a CRC-32 checksum. The shard file header has a dirty flag that is set (and fsynced) before the first write and cleared on clean close. On the next open:

1. Any shard whose flag is still set is fully scanned.
2. Records with bad checksums are tombstoned.
3. Torn trailing writes are truncated.
4. All indexes are rebuilt from the recovered data.

The operation is automatic and requires no intervention.

**Clean opens are O(1).** On every clean sync, each shard persists its scan-derived state (live count, free slots) to a small `.state` sidecar. A clean open adopts that state instead of reading the entire data region — the database opens instantly regardless of file size. The sidecar is trusted only when the dirty flag is clear *and* the recorded file size matches; anything suspicious falls back to the full scan.

### Compaction

Deleted documents are tombstoned in-place — space is not immediately reclaimed. Call `compact()` to rewrite shards and rebuild indexes:

```swift
// Compact a specific collection
try await articles.compact()

// Only compact if fragmentation is worth it (threshold: DatabaseOptions.maxFragmentation)
if try await articles.needsCompaction() {
    try await articles.compact()
}
```

Compaction preserves encryption and compression and never re-reads documents: each shard reports its old→new offset map and index pointers are remapped in place, with payload checksums reused so nothing is re-hashed. It runs **incrementally, one shard at a time** — concurrent reads and writes interleave between shard cycles, so the worst-case stall is a single shard's rewrite, not the whole compaction (on an 8-shard benchmark, `get()` p99 during compaction is ~4 µs).

### Durability

Records are durable as they are written; *recovery-free* opens additionally require a `sync()`, which persists index snapshots, flushes shard state, and clears the dirty flags:

```swift
// Explicit — e.g. on scenePhase == .background
try await articles.sync()      // one collection
try await db.sync()            // every open collection

// Or automatic, via DatabaseOptions:
DatabaseOptions(autoSync: .afterWrites(500))     // every 500 written documents
DatabaseOptions(autoSync: .interval(30))         // first write ≥30 s after the last sync
```

There are no background timers — an idle database never wakes up. The expensive part of a sync (encoding and compressing index snapshots) runs off the collection's actor over copy-on-write captures, so reads and writes keep flowing while it happens. Without any sync, a crash simply pays the recovery scan on the next open.

### Metrics

`collection.metrics()` returns cumulative counters — which access paths queries actually took (index lookups, covered queries, full/partition scans), shard I/O bytes, compaction activity, and whether any shard needed crash recovery at open. Use it to verify that the queries you expect to be index-served really are.

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

## Performance

Measured with the bundled benchmark (10,000 documents, batch size 1,000, Apple Silicon, release build). SQLite runs in WAL mode with prepared statements and the same secondary indexes. Times are milliseconds — lower is better.

| | InsertMany | InsertBatch | Delete (1k) | Compact | File size |
|---|---|---|---|---|---|
| NyaruDB2 (gzip + msgpack) | 97 | 91 | 5.3 | **19.0** | **1.1 MB** |
| NyaruDB2 (none + msgpack) | 41 | 39 | 5.3 | 31.6 | 11.4 MB |
| SQLite (WAL) | 36 | 31 | 0.8 | 24.4 | 11.8 MB |

Highlights:
- **Uncompressed inserts run within ~15% of SQLite** — with gzip enabled, the extra time buys a file ~10× smaller.
- **Compaction beats SQLite's VACUUM** thanks to offset-remapped indexes (no document is re-read, re-parsed, or re-hashed).
- Fully index-covered queries answer `count()` with zero disk I/O and skip all redundant parsing.

Reproduce it yourself:

```bash
swift run -c release NyaruDB2Benchmark -q -d 10000          # gzip + msgpack vs SQLite
swift run -c release NyaruDB2Benchmark --compression none --format msgpack -d 10000
```

### How it goes fast

- **Positioned I/O** — all storage goes through `pread`/`pwrite` (one syscall per access); point reads speculatively fetch header + payload in a single call.
- **Parallel CPU pipeline** — compression, encryption, encoding, decoding, checksums, and index merges all fan out across cores for batch operations.
- **Skip-scan extraction** — MsgPack index keys are extracted by skipping over unwanted fields via length prefixes; large content fields are never decoded just to index a document.
- **Binary index snapshots** — hand-rolled snapshot format with interned shard IDs, an order of magnitude faster than Codable to persist and load.
- **Streaming incremental compaction** — live records flow into the compacted file in bounded zero-copy chunks (peak memory near the shard size instead of ~3× it), one shard at a time so reads never queue behind the whole compaction.
- **Chunked scans** — whole-file walks (scans, rebuilds, recovery) use a 4 MiB sliding window: a 764 MB shard rebuild peaks at +139 MB instead of +780 MB.
- **Parallel multi-shard reads** — pointer fetches and full scans read independent shards concurrently, so latency tracks the slowest shard, not the sum.
- **Parallel residual queries** — non-indexed predicates are evaluated across all cores, and `sort + limit` selects through a bounded top-K heap instead of sorting every match.
- **O(1) clean opens** — see [Crash Recovery & Fast Opens](#crash-recovery--fast-opens).

Extended scenarios (unit-insert scaling curve, read latency under compaction, memory peaks, residual predicates) and their recorded baselines live in [BENCHMARKS.md](BENCHMARKS.md).

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

## Documentation

Full API reference is generated with [jazzy](https://github.com/realm/jazzy) and published on GitHub Pages:

```bash
gem install jazzy
jazzy   # reads .jazzy.yaml, outputs to docs/
```

Every public symbol carries doc comments, so the generated reference covers the complete API surface. See [CHANGELOG.md](CHANGELOG.md) for release notes.

---

## License

Apache 2.0 © 2026 [galileostudio](https://github.com/galileostudio). See [LICENSE](LICENSE.md).

---

## Acknowledgements

Inspired by the original [NyaruDB](https://github.com/kelp404/NyaruDB) by kelp404.
