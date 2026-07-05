# Changelog

All notable changes to NyaruDB2 are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com); versions follow
[Semantic Versioning](https://semver.org) (pre-1.0: breaking changes may land
in minor versions).

## [0.2.0] — 2026-07-05

### Added
- `NyaruCollection.insertBatch(_:)` — buffered bulk insert: accumulate
  documents synchronously from multiple sources inside a closure and flush
  them as a single batch (one index merge pass instead of one per call).
- `NyaruCollection.delete(ids:)` — batched delete by id: one storage hop per
  shard and one index sweep per field.
- `NyaruCollection.needsCompaction()` — reports whether any shard's tombstone
  ratio exceeds `DatabaseOptions.maxFragmentation` (which is effective again).
- `NyaruCollection.name` public property (restored).
- Query planner fast paths: fully index-covered queries skip all redundant
  parsing and predicate re-evaluation; covered `count()` is answered from the
  index with zero disk I/O; covered range scans stop collecting pointers at
  `offset + limit`.
- Clean-state sidecar (`<shard>.nyaru.state`): clean opens adopt the persisted
  scan state and skip reading the data region entirely — O(1) startup
  regardless of file size, with automatic fallback to a full recovery scan
  whenever the dirty flag is set or the sidecar does not match.
- Binary index snapshot format (`NYI1`) with interned shard IDs — roughly an
  order of magnitude faster to persist and load than the previous
  Codable+MsgPack snapshots. Legacy snapshots still load transparently.
- MsgPack skip-scan field extraction: index keys are read by skipping over
  unwanted values via length prefixes, so large payload fields are never
  decoded just to index, update, or delete a document.

### Changed (breaking)
- `withTransaction(_:)` was renamed to `insertBatch(_:)` (and
  `NyaruTransaction` to `NyaruInsertBatch`): it is a write buffer, not a
  transaction, and the name now says so. The buffer type is no longer
  `Sendable`, making cross-task misuse a compile-time error.
- `NyaruDB.init(path:options:)` is no longer `async` (it never suspended).
- `NyaruCollection.count()` and `stats()` now `throw`
  (`NyaruError.databaseClosed`), consistent with every other operation.

### Performance
- All storage I/O moved from `FileHandle` to positioned POSIX `pread`/`pwrite`
  (one syscall per access); point reads speculatively fetch header + payload
  in a single call.
- Parallel CPU pipeline for batch operations: compression, encryption,
  encoding, decoding, checksums, index merges, and snapshot persistence all
  fan out across cores.
- Compaction rewrites shards with a single batched write, remaps index
  pointers via per-shard offset maps (no document re-read/re-parse), reuses
  stored CRCs, and adopts the known state of the compacted file without
  rescanning it. On the bundled 10k-document benchmark, compaction went from
  110 ms to under 18 ms — faster than SQLite's VACUUM.
- Query-driven deletes reuse the keys already extracted during predicate
  matching and tombstone records without reading payloads back (~2× faster).
- Single-pass `bulkRemove` replaced quadratic per-entry index removal.

### Fixed
- **Index consistency for Mirror-extracted metadata.** Documents with fields
  Mirror cannot convert (enums, `Date`, `UUID`) or with renamed `CodingKeys`
  could be silently missing from indexes depending on which code path indexed
  them. The fast path now falls back to payload parsing per document when
  needed, and the first extraction per handle is cross-checked against the
  encoded payload.
- **Descending-sort pagination on an indexed field** returned the wrong page
  (it sliced the ascending index order). Descending sorts now bypass the
  pushdown and sort in memory.
- **Compaction/reader race.** Concurrent point reads during a compaction could
  observe stale offsets against the rewritten file and evict healthy index
  entries. A compaction gate now drains in-flight pointer operations before
  files are swapped and suspends new ones until indexes are remapped.

## [0.1.0-alpha1]

Initial public alpha: slotted-file storage engine with CRC-32 integrity and
dirty-flag crash recovery, actor-based concurrency, ordered in-memory indexes
with persisted snapshots, fluent typed queries with a cost-based planner,
partitioning, optional gzip/LZFSE/LZ4 compression, AES-256-GCM encryption,
pull-based streaming, and explicit compaction.

[0.2.0]: https://github.com/galileostudio/nyarudb2/compare/v0.1.0-alpha1...v0.2.0
[0.1.0-alpha1]: https://github.com/galileostudio/nyarudb2/releases/tag/v0.1.0-alpha1
