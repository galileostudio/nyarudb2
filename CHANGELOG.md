# Changelog

All notable changes to NyaruDB2 are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com); versions follow
[Semantic Versioning](https://semver.org) (pre-1.0: breaking changes may land
in minor versions).

## [0.3.1] — 2026-07-10

### Performance
- **Coalesced pointer reads.** The pointer-list read path — covered queries
  and any fetch that resolves a set of index pointers — now reads each shard's
  records in coalesced, offset-sorted passes over a sliding window instead of
  one `pread` per record, cutting syscalls and per-record `Data` allocations
  when a query returns many rows from a shard.
- **Sort pushdown via the sort-field index.** A query that sorts on an indexed
  field unaligned with a fully index-answered predicate, **with a limit**, now
  walks the sort field's index in order and filters by the predicate's pointer
  set — the page comes out already ordered, the walk stops after `offset +
  limit` survivors, and there is no in-memory sort or sort-key extraction pass.
  It falls back to the existing in-memory sort path when pushdown does not apply
  (unindexed sort field, aligned sort, no limit, or sparse survivors), so
  results are identical.

## [0.3.0] — 2026-07-09

### Added
- **Structured logging** via [swift-log](https://github.com/apple/swift-log) —
  the engine emits structured events at `info`, `debug`, and `warning` levels
  for database lifecycle, collection open/close, index rebuilds (crash
  recovery), compaction (start/finish with duration and before/after stats),
  shard recovery from dirty state, and storage-level crash recovery.
  Application controls the log level via `NyaruLogger.logLevel` (default
  `.info`) and can inject a custom `LogHandler` (OSLog, file, telemetry)
  through `LoggingSystem.bootstrap`. All log messages are in English.
- `NyaruCollection.writeBatch(_:)` — mixed atomic batches: accumulate
  insert/update/upsert/delete operations and apply them all-or-nothing
  against errors. Every operation is validated before anything is written
  (duplicate ids, missing update targets, conflicting in-batch operations,
  or a throwing body abort with zero side effects) and a failed write is
  rolled back. Atomicity covers errors, not process crashes — NyaruDB has
  no write-ahead log by design.
- **Durability knob.** `NyaruCollection.sync()` is public: it persists
  index snapshots, flushes shard data, and clears the dirty flags, so a
  later crash costs no recovery work. `DatabaseOptions.autoSync` schedules
  it automatically (`.off` default, `.afterWrites(n)`, `.interval(seconds)`
  — no timers: an idle database never wakes up). The expensive snapshot
  encoding runs off the collection's actor over copy-on-write captures, so
  reads and writes keep flowing during a sync.
- `NyaruCollection.metrics()` — internal counters snapshot: query access
  paths (index lookups, covered queries, full/partition scans), cumulative
  shard I/O bytes, compaction count and duration, and shards recovered
  from dirty at open.
- `distinctValues(on:)` is answered straight from the index — zero disk
  I/O — when the field is indexed and the query has no predicates or a
  single covered predicate on that same field (values then arrive in
  ascending index order; the API makes no ordering promise).
- Extended benchmark scenarios (`--scenario curve|concurrency|bigdocs|
  memory|residual|unitdelete|decompose|querycost`) with recorded baselines
  in `BENCHMARKS.md`, including the cost-decomposition measurements that
  gate (and in several cases reject) future engine work.

### Deprecated
- `insertBatch(_:)` is now a deprecated alias of `writeBatch(_:)`, and
  `NyaruInsertBatch` of `NyaruWriteBatch` — one batch API instead of two.
  Insert-only batches take the identical bulk-insert fast path, so this is
  purely a rename; existing call sites compile unchanged with a rename
  fix-it. The aliases will be removed in 0.4.0.

### Performance
- **Sort-key-only fast path for index-covered queries**: a query that sorts on
  a field unaligned with a fully index-answered predicate (e.g. `where("age",
  …).sort(by: "name")`) no longer parses every candidate document twice. It
  used to build a full `[String: Any]` per row for the sort key — boxing every
  field, including large payloads it never sorts on — and re-evaluate a
  predicate the index already guaranteed, then decode each row again to the
  result type. `execute()` now extracts only the sort key when there is no
  residual predicate, cutting the sort to one deserialization per surviving
  row. On the benchmark's `id in 1000..2000 sort by name` (1001 rows) this
  dropped the query from 3.08 ms to 1.90 ms (~1.6×), near the decode-only
  floor. Covered lookups and residual-predicate sorts are unchanged.
- **Large-fraction batch delete (survivor rewrite)**: a `delete(ids:)` or
  `find().delete()` removing at least half of a collection's live documents
  now rewrites each shard keeping only the survivors and remaps every index
  in a single pass, instead of writing one tombstone per deleted record. On a
  90k-of-100k delete this cut the engine cost from 389 ms to 57 ms (~6.8×,
  4.33 → 0.63 µs/doc) and reclaims the space immediately with no deferred
  compaction. The rewrite adopts clean shards, so it persists the remapped
  index snapshot before returning — a crash cannot reopen a clean shard
  against a stale snapshot. Below the crossover the tombstone path stays the
  default.
- **Incremental compaction**: the gate closes around one shard's rewrite
  and remap at a time instead of the whole compaction. On an 8-shard
  benchmark, reads during `compact()` went from 4 completed (p99 = the
  full 57 ms compact) to 10 781 completed at p99 4 µs; the worst stall is
  one shard's rewrite.
- **Chunked scans**: full-file walks (scans, index rebuilds, crash
  recovery) use a 4 MiB sliding window instead of reading the whole data
  region — on a 764 MB shard, `all()`'s peak footprint dropped from
  +2.4 GB to +1.1 GB and an index rebuild from +780 MB to +139 MB.
- Streaming compaction: live records flow into the compacted file in
  bounded zero-copy chunks, cutting peak compaction memory from roughly 3×
  the shard size to the shard size plus one 4 MiB chunk.
- Residual-predicate queries parse and evaluate candidates across all
  cores, and `sort + limit` selects through a bounded top-K heap instead
  of sorting every match — 30–50% faster on 200k-candidate scans.
- Pointer fetches spanning multiple shards read them concurrently — query
  latency tracks the slowest shard instead of the sum of all shards.
- Whole-shard operations (`all()` scans, index builds) run through a
  bounded 3-shard window, so memory no longer grows with the shard count.
- One `plan()` per query (the resolved probe travels in the plan);
  indexed queries save one actor hop.
- Index rebuilds group entries per shard task, removing the serial
  regrouping pass over every entry; `rebuildAllIndexes` and index evolution
  share one implementation.
- Bulk index removals sweep posting lists with Set membership checks
  (O(p) instead of O(p × v)); batched deletes of 1k documents dropped from
  ~7.6 ms to ~5.3 ms on the bundled benchmark.
- MsgPack field extraction matches map keys by comparing raw bytes against
  a pre-computed plan — no per-document Set or key String allocations on
  the write-path metadata extraction.

### Fixed
- **Corrupt clean-state sidecar could overwrite live records.** The
  sidecar's structural checks caught truncation but not bit rot: a corrupt
  free-slot list could hand a live record's slot to best-fit reuse. The
  sidecar format (v2) now carries a CRC-32 of its body, and append
  additionally verifies the on-disk slot header (tombstone flag + capacity)
  before ever writing over a slot.
- **`writeBatch` tombstone-phase failure left ghosts.** An I/O error after
  the appends landed left them on disk outside the indexes, resurfacing as
  duplicates on the next rebuild. The failure path now resolves each
  operation: already-superseded updates are committed (rolling them back
  would lose the document), everything else is rolled back by tombstoning
  its append.
- **Writes racing `sync()` could produce clean shards with stale index
  snapshots** — trusted on the next open and silently missing entries. The
  sync now stamps a write generation, re-captures snapshots if writes
  landed during the off-actor persist, and fences the final fsyncs with
  the gate.
- **Torn appends shorter than a record header were never truncated** by
  recovery, and since appends land at the end of the file, every record
  written after the leftover stub was invisible to scans. The chunked
  walker reports the stub's offset and repair truncates it.
- **Index evolution racing compaction.** `setIndexedFields` bypassed the
  compaction gate: a rebuild concurrent with `compact()` could index
  post-compaction offsets that the subsequent pointer remap silently
  dropped, leaving the fresh index incomplete. It now participates in the
  gate like every other pointer-based operation.
- **Queries holding pointers across a compaction.** The query engine
  resolved index pointers and fetched their documents in separate actor
  calls; a `compact()` scheduled between the two rewrote the shard files
  and the fetch dereferenced stale offsets. Pointer resolution and reads
  now happen inside a single compaction-gated call (`IndexProbe`), so no
  pointer ever crosses an `await` outside the gate.

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

[0.3.0]: https://github.com/galileostudio/nyarudb2/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/galileostudio/nyarudb2/compare/v0.1.0-alpha1...v0.2.0
[0.1.0-alpha1]: https://github.com/galileostudio/nyarudb2/releases/tag/v0.1.0-alpha1
