# Benchmark Baselines

Extended-scenario baselines recorded before the v0.3.0 memory/latency/index
tracks (M1, C1, E1). Reproduce with
`swift run -c release NyaruDB2Benchmark --scenario <name>` on Apple Silicon,
release build. The standard suite (`-q -d 10000`) lives in the README.

## curve — unit-insert latency vs collection size (gates E1)

Compression none, msgpack, single shard. Unit inserts land at uniformly
random positions of the sorted id-index key array (worst case: every insert
pays the O(n) array shift); gets are point lookups.

| size | build (s) | 1k inserts (ms) | insert µs p50/p99 | 1k gets (ms) |
|---|---|---|---|---|
| 10 000 | 0.03 | 12.6 | 12.2 / 20.5 | 2.6 |
| 50 000 | 0.13 | 22.7 | 22.4 / 44.7 | 2.8 |
| 100 000 | 0.25 | 36.6 | 35.1 / 82.2 | 3.3 |
| 250 000 | 0.64 | 78.4 | 73.9 / 207.9 | 2.8 |
| 500 000 | 1.29 | 145.8 | 138.3 / 465.4 | 3.1 |
| 1 000 000 | 2.78 | 285.7 | 262.5 / 951.6 | 3.1 |

Reading: unit-insert cost grows linearly with collection size (the sorted
array's memmove), reaching ~0.26 ms p50 / ~1 ms p99 at 1M docs. Point reads
stay flat (binary search). Bulk inserts are unaffected (`bulkLoad` merges).
Sequential/ascending ids always append and stay at the 10k-size cost.

## concurrency — read latency under writes and compaction (gates C1)

50k docs, 8 partition shards, `get(id:)` latencies.

| phase | gets | p50 µs | p99 µs | max µs |
|---|---|---|---|---|
| idle | 2000 | 2.5 | 5.6 | 100 |
| during writes | 2000 | 4.2 | 70.6 | 866 |
| during compact | 4 | 23.5 | 57 495 | 57 495 |

compact() total: 57.6 ms. Reading: the compaction gate blocks reads for the
entire multi-shard compaction — only 4 gets completed and the worst one
waited the full 57 ms. This is the head-of-line blocking C1 addresses.

## bigdocs — large payloads and many shards

- 150 docs × ~1.2 MB, compression none: insert 0.94 s, get 716 µs,
  range query (11 hits) 7.3 ms, compact after 50 deletes 139 ms,
  size 174 MB.
- 30k docs across 150 partition shards: insert 0.16 s, partition query
  (200 hits) 0.7 ms, full scan 20.6 ms (peak +2.7 MB), compact 118 ms.

## residual — residual-predicate queries (gates Q2/Q4)

200k docs, compression none, msgpack, id index only — predicates evaluated
in memory over every candidate. Baseline recorded before the parallel
parse+evaluate and top-K work:

| query | baseline (ms) | after Q2/Q4 (ms) |
|---|---|---|
| full scan + endsWith filter (20k hits) | 289.3 | ~185 |
| same filter + sort(id) + limit(10) | 286.1 | ~172 |
| same + sort desc + offset(20) + limit(10) | 275.6 | ~175 |
| count() with residual filter | 322.8 | ~150 |

### Rejected: skip-scan evaluation for residual predicates (roadmap Q3)

Measured and reverted. Replacing the per-candidate full parse with
`extractTopLevelFields` + evaluation over `[String: FieldValue]` was
consistently SLOWER, even after removing all per-document overhead
(pre-computed UTF-8 key plan, memcmp key matching, no Set/String
allocations per doc), and even in the motivating case of large unwanted
payload fields:

| query | full parse (ms) | skip-scan flat (ms) |
|---|---|---|
| small docs: filter / sort+limit / count | 182 / 169 / 150 | 189 / 226 / 165 |
| 1 KiB docs: filter / sort+limit / count | 65 / 57 / 50 | 68 / 72 / 56 |

Root cause: the native MsgPack `extractDictionary` is already fast enough
that skipping values saves less than the extraction's own result-building
costs in the query loop. Skip-scan remains the right tool where it
already lives — single-pass metadata extraction on the write path
(`extractMetadata`), where the alternative is parsing per indexed field.
Do not reintroduce without a benchmark showing otherwise.

## memory — footprint peaks on whole-shard scans (gates M1/M2)

64k docs × ~8 KiB, compression none, single 764 MB shard.

| operation | time | footprint Δ |
|---|---|---|
| `all()` | 0.44 s | **+2405 MB** (~3.1× the file) |
| index rebuild (new field) | 0.26 s | +780 MB (~1× the file) |

Reading: `forEachLive` reads the whole data region and (on the copying
path) duplicates every payload, and `all()` additionally materialises the
decoded documents — M1's chunked scan targets the first two components.
