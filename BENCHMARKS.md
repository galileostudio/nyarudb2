# Benchmark Baselines

## decompose — P0.3 cost attribution (2026-07-08)

`--scenario decompose`, 100k docs, harness `User` shape (Date + [String]),
partitionKey city (10 values), indexes [age, city], msgpack, release build,
engine commit of this entry. Coder numbers measured against the swift-msgpack
fork v1.3.0 directly.

**A. Coders standalone (10k docs):**

| op | per doc |
|---|---|
| encode serial (tree encoder) | 4.96 µs |
| encode parallel | 1.44 µs |
| decode parallel (lazyScan) | 2.47 µs |
| decode serial | 3.26 µs |
| `Date` field marginal | +0.88 µs encode / +0.44 µs decode |

**B. Covered query (`city == X`, limit 1000, avg 50 runs):**

| component | none | gzip |
|---|---|---|
| query total | 3.29 ms | 3.23 ms |
| plan+probe+actor (covered count) | ~0.00 ms | ~0.00 ms |
| decode 1k (standalone) | 2.56 ms (78%) | 2.56 ms |
| io+crc+restore (residual) | 0.73 ms (22%) | 0.67 ms |

**Insert 100k (one batched flow):** 5.22 µs/doc (none), 10.68 µs/doc (gzip —
compression itself doubles it).

**C. Batch delete, 90k of 100k in one call:**

Baseline (per-record tombstone path — one tombstone write per deleted record,
space reclaimed only by a later compaction):

| configuration | total | per doc |
|---|---|---|
| with secondary indexes [age, city] | 389 ms | 4.33 µs |
| id index only | 372 ms | 4.13 µs |

After the large-fraction **survivor rewrite** (a delete touching ≥50% of the
live docs rewrites each shard keeping only survivors, then remaps all indexes
in one `compactRemap` pass — deleted pointers are absent from the survivor map
and dropped for free, so no keys and no per-record tombstone write):

| configuration | total | per doc |
|---|---|---|
| with secondary indexes [age, city] | 57 ms | 0.63 µs |
| id index only | 54 ms | 0.60 µs |

**~6.8× faster** (389 → 57 ms): the cost is now copying the ~10k survivors,
not writing 90k tombstones, and the space is reclaimed immediately (no
deferred compaction). Includes the trailing `sync()` barrier that persists the
remapped snapshot (the rewrite adopts clean shards, so a crash must not reopen
them against a stale snapshot). Below the 50% crossover the tombstone path
still wins (fewer records touched) and stays the default. Serves both
`delete(ids:)` and the query `find().delete()` path — the rewrite needs no
index keys.

### Conclusions vs the external harness v2 (its numbers in parentheses)

- Covered query: **3.3 ms** engine-side (harness: 23.2 ms) — already under
  the 6.8 ms target. ~20 ms of the harness number is not engine time.
- Insert: **5.2 µs/doc** uncompressed (harness: 17.1) — already under the
  13.4 µs target; even gzip (10.7) is under it.
- BatchDelete: **0.63 µs/doc** after the survivor rewrite (was 4.3; harness
  measured 13.6 on the old path) — now below CoreData's honest 1.4 µs/doc for
  the large-fraction case. See section C.

Every "losing" op is 3–7× faster when measured at the engine than through
the harness. Before any engine phase lands, the harness needs a v3 audit —
prime suspects: NyaruDB2 built in **debug** inside the harness (SwiftPM's
default), per-op adapter overhead, or measurement including setup. The
v1→v2 lesson repeats at smaller scale.

Engine facts that survive and reorder the plan:
- Decode is 78% of the covered query → the fork's cursor decoder (P2.2) is
  the top engine lever; coalesced preads (P1.1) can win at most ~0.7 ms.
- The tree encoder costs ~5 µs/doc serial → P2.1 justified.
- One `Date` field costs +0.88/+0.44 µs — the fork's §3 probe is justified.
- P3.2/P3.3 ceilings are small (~0.2 µs/doc); `clear()` (P3.1) remains the
  real lever for deleteAll-class operations.

Extended-scenario baselines recorded before the v0.3.0 memory/latency/index
tracks (M1, C1, E1). Reproduce with
`swift run -c release NyaruDB2Benchmark --scenario <name>` on Apple Silicon,
release build. The standard suite (`-q -d 10000`) lives in the README.

## querycost — where the "Query" number goes (2026-07-09)

`--scenario querycost`, 100k docs, TestDocument shape, non-partitioned,
indexes [category, name, id] (matching the main suite). Per-shape
`execute()` cost, avg of 200:

| shape | ms/exec | rows |
|---|---|---|
| covered: id>100 limit 100 | 0.17 | 100 |
| covered: name == "Document 42" | 0.003 | 1 |
| sort: id in 1000..2000 by name | 1.90 | 1001 |
| range: id in 1000..2000 (no sort) | 1.43 | 1001 |

The main suite's aggregate "Query" number is `5 × (0.17 + 0.003 + sort)`, so
the unaligned **sort query dominates it (~95%)** — not the covered lookups.

Two facts about the cross-DB comparison, both making the headline "Query 3.5×
slower" largely a benchmark-construction artifact rather than an engine gap:

- The SQLite side (`measureQuery`) runs only `SELECT * … id>100 LIMIT 100` and
  steps rows with `while sqlite3_step {}` — it never reads a column, so it
  decodes nothing. NyaruDB2 fully decodes every returned row.
- NyaruDB2's suite runs three queries including the 1.9 ms sort; SQLite runs
  one cheap query. Different workloads. The fair shared shape (covered
  id-range) is 0.17 ms — competitive.

### Sort-key-only fast path

A sort over an index-covered predicate used to full-parse every candidate to a
dict (for the sort key, plus a redundant re-evaluation of a predicate the
index already guaranteed) and then decode each again to the result type — two
deserializations per row. `execute()` now extracts only the sort key when the
predicate is fully index-answered (`sortedByKeyOnly`), skipping the full parse
(notably the boxing of large payload fields it never sorts on) and the
redundant eval. The sort query dropped **3.08 → 1.90 ms/exec (~1.6×)**, now
near the decode-only floor (1.43 ms); the aggregate Query number falls ~1.5×.
Covered lookups are unchanged (already optimal). Residual-predicate sorts keep
the full-parse path (the dict is needed to evaluate them).

### Decode decomposition — the sort query is NOT decode-bound (2026-07-09)

With the main suite's real payload (`content` ≈ 1.1 KB/doc), the decode of the
1001-row result set was measured against the coder directly (best-of-15):

| decode variant (1001 docs, ~1.1 KB each) | time |
|---|---|
| full `T`, parallel, new decoder/doc (== `decodeBatch`) | 0.43 ms |
| projection (id, name, category — omits `content`), parallel | 0.43 ms |
| full `T`, serial, new decoder/doc | 0.77 ms |
| full `T`, serial, reused decoder | 0.74 ms |

Two proposed levers are **refuted by measurement**:

- **Projection / skip-`content`: ~0 gain.** Decoding without the 1.1 KB
  `content` is identical to decoding with it (0.43 vs 0.43 ms) — msgpack string
  materialisation is a bounds-checked copy, effectively free. The decode cost is
  per-document structure walking, not the large field. Projection would not move
  the query.
- **Decoder reuse: ~3%.** New-decoder-per-doc vs one reused decoder is 0.77 vs
  0.74 ms (~26 ns/doc of allocation). Noise, not the "guaranteed win" it looks
  like.

The reframing that matters: at the query level `sort` = 2.16 ms and `range`
(no sort) = 1.62 ms with this payload, while the parallel decode of the same
1001 rows is only **0.43 ms**. So the sort query splits roughly:

- **read path (fetch: pread + CRC-32 + pointer handling) ≈ 55%** (~1.19 ms),
- **sort-key extraction + ordering ≈ 25%** (~0.54 ms; a second scan of each
  payload, redundant with the decode),
- **decode ≈ 20%** (~0.43 ms, already parallel and optimal).

Decode is **not** the bottleneck. The read path dominates (CRC-32 of ~1.1 MB is
a real slice of it), and the sort-key extraction is a redundant second pass. The
only algorithmic lever with a clear gain is **sort pushdown** via the `name`
index (produce name-ordered pointers from the index, dropping the extraction
pass — ~20% of the query). The read path is largely inherent to materialising
1001 documents, which is exactly what CoreData avoids via faulting — so the
remaining gap is structural (return-everything vs fault), not a decode fix.

### Coalesced preads on the pointer-list read path (2026-07-09)

`readBatch(offsets:)` used to issue one `pread` per record (plus a ~4 KiB
speculative allocation each). An index range scan resolves to a run of
physically contiguous offsets, so `SlottedFile.readRecords(atSortedOffsets:)`
now groups offsets within `maxCoalescedReadSpan` (8 MiB) into a single window
read and slices each record out of it; only records straddling the window tail
fall back to a per-record read. Same validation and CRC check as `read(at:)`.

Per-shape `execute()` (100k docs, msgpack, indexes [category, name, id],
avg of 200) before → after:

| shape | before | after |
|---|---|---|
| covered: id>100 limit 100 | 0.17 ms | 0.145 ms |
| sort: id in 1000..2000 by name | 1.90 ms | 1.69 ms (~11%) |
| range: id in 1000..2000 (no sort) | 1.43 ms | 1.20 ms (~15%) |

The no-sort range query isolates the read path (fetch + decode, no sort-key
pass): ~15% faster from cutting ~1000 syscalls to a handful. The sort query
inherits the same read-path saving. The remaining sort-query lever is the
sort-key extraction pass (~25%), addressable by sort pushdown via the `name`
index.

### Sort pushdown via the sort-field index (2026-07-09)

When a query sorts by an indexed field *different* from the index-covered
predicate field **and a limit is present**, the sort-field index now yields the
page already ordered: the predicate resolves to a pointer set, the sort index
is walked in key order keeping only members, and the walk stops after
`offset + limit` survivors. No sort-key extraction pass, no in-memory sort, and
only ~`limit` documents are read instead of every match.

`querycost` (100k docs, msgpack, indexes [category, name, id], avg of 200):

| shape | in-memory sort | pushdown |
|---|---|---|
| sort `id in 1000..2000 by name` (no limit) | 1.66 ms | 1.66 ms (unchanged) |
| sort `id in 1000..2000 by name limit 20` | ~1.66 ms | **0.10 ms (~16×)** |
| sort `id>100 by name limit 20` (dense) | ~150 ms* | 6.4 ms |

*The dense fallback reads every match (~99.9k docs); pushdown reads 20 but pays
an O(matches) membership-set build, hence 6.4 ms — still a large win.

**Cost gate.** Pushdown only triggers when a `limit` is present and the match
set is more than twice the requested page (`matches > 2·(offset+limit)`).
Without a limit it would walk the whole sort index while still reading every
match — a regression (measured 1.66 → 4.7 ms on the no-limit Query C), so that
case keeps the in-memory sort-key-only path. Ties (equal sort keys) follow an
unspecified order in both paths (the API promises none).

### Deferred (faulting-style) results — `fetchDeferred()` (2026-07-09)

`execute()` decodes every matching document into `T`. The no-limit sort Query C
returns 1001 fully-decoded structs, whereas CoreData returns unrealised faults
and only materialises the rows the caller touches — the structural reason it
wins the discard-the-result benchmark. `fetchDeferred()` mirrors that: it
resolves predicates, ordering, and pagination eagerly (so `count` and order are
known) but wraps each payload in a `DeferredDocument` that decodes only when
`decoded()` is called.

Two refuted micro-optimisations along the way (measurement over intuition):

- **Fusing sort-key extraction into the decode pass** (one parallel pass
  producing `(key, T)`) *regressed* the no-limit sort 1.66 → 1.94 ms: reordering
  decoded `T` values (which retain heap `String` fields) costs more than
  reordering the raw `Data` (cheap CoW references) and decoding afterward.
- **Hardware/faster CRC-32**: measured — CRC-32 of the 1001-row result set
  (~1.05 MB) is only 0.14 ms (macOS zlib is already accelerated). Not a lever.

`querycost` (100k docs, msgpack), sort `id in 1000..2000 by name`:

| path | time | note |
|---|---|---|
| `execute()` (eager decode of 1001) | 1.69 ms | |
| `fetchDeferred()` (order only, no decode) | **1.02 ms** | decode is ~40% of the query |

Deferred drops the decode (~0.67 ms) the caller never asked for. Projecting the
aggregate suite Query with deferred for the discarded sort query:
`(0.14 + 0.004 + 1.02) × 5 ≈ 5.8 ms` + overhead ≈ **~6.5–7 ms**, versus the
eager ~10.1 ms — the faulting gap to CoreData's ~6 ms closes to ≥85% when the
comparison is like-for-like (both returning unrealised results).

### Harness audit — engine vs reported cross-DB numbers (2026-07-09)

The cross-DB report flagged two red metrics (Query 30%, BatchDelete 49% of
CoreData). Measured engine-side on this machine (release, 50k docs, msgpack,
no compression), both are far better than reported — the gap is measurement,
not engine:

**Query (5×, aggregate).** `measureQueryPerformance` now uses `fetchDeferred()`
(the like-for-like counterpart to CoreData returning unrealised faults — a
discarded fetch decodes nothing on either side):

| | value | vs CoreData (~6.0 ms) |
|---|---|---|
| reported (external harness) | 19.8 ms | 30% |
| engine, `execute()` (eager) | 10.1 ms | 59% |
| engine, `fetchDeferred()` | **5.99 ms** | **~100%** |

The external harness inflates ~3.3× over the engine (matching the covered-query
finding: 3.3 ms engine vs 23.2 ms harness). With deferred fetches the engine
essentially ties CoreData. gzip is 7.69 ms (78%) — compression pays
decompression in the read path even when decode is deferred.

**BatchDelete.** The engine deletes 90 000 of 100 000 in one call at
**0.63 µs/doc** (`--scenario decompose`, survivor-rewrite path), beating
CoreData's honest 1.4 µs/doc by ~2×. The reported 0.2555 s (49%) is ~4× the
engine cost, which points at the harness not using the bulk `delete(ids:)` /
`find().delete()` API (a per-id delete loop pays one actor hop + one tombstone
write per doc and never triggers the large-fraction survivor rewrite).

**Checklist for a fair harness (v3).**
- Build NyaruDB2 in **release** (SwiftPM defaults to debug — the single biggest
  inflator).
- Exclude collection open / index build / data generation from the timed region.
- Query: use `fetchDeferred()` when the result is discarded or paged, matching
  CoreData faulting; use `execute()` only when the comparison realises objects.
- BatchDelete: call `delete(ids:)` (or `find().delete()`), not a per-id loop.
- Amortise per-op adapter overhead (the harness wraps each op in its own async
  context / logging).

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

### Decision E1: O(log n) index structure — NOT NOW

The curve confirms the O(n) unit insert but also bounds its impact:

- At 100k docs (a large mobile collection) a random-position unit insert
  costs 35 µs p50 — irrelevant for any interactive workload.
- At 1M docs it costs 262 µs p50 / ~1 ms p99, which still sustains
  ~3 800 unit inserts/s. Reads never degrade.
- Every batch write path (`insert(contentsOf:)`, `writeBatch`) uses the
  O(n + m) merge and is unaffected at any size — 1M docs bulk-load in
  2.8 s. Ascending ids (the most common id scheme) always append.

A B-tree/skip-list buys something only for sustained high-frequency
unitary writes on 500k+ document collections — a server workload, not
this database's target. Revisit if that target changes; the swap stays
contained behind `OrderedIndex`'s interface (final class, and the NYI1
snapshot format serialises ordered entries, agnostic to the in-memory
structure).

## unitdelete — unit-delete latency vs collection size

One-by-one `delete(id:)`, compression none, msgpack, id index only.
FIFO deletes the oldest ids (position 0 of the sorted key array — the worst
case for the O(n) key shift, and the typical mobile eviction pattern);
random deletes uniformly random ids.

Baseline (before lazy empty key slots):

| size | fifo µs p50/p99 | random µs p50/p99 |
|---|---|---|
| 10 000 | 8.5 / 12.9 | 6.7 / 11.5 |
| 50 000 | 33.4 / 45.3 | 17.5 / 42.7 |
| 100 000 | 58.8 / 85.2 | 32.2 / 67.7 |
| 250 000 | 142.9 / 272.0 | 69.2 / 158.9 |
| 500 000 | 279.3 / 662.6 | 142.4 / 312.2 |
| 1 000 000 | 561.0 / 1322.8 | 283.7 / 723.3 |

Reading: linear in collection size, dominated by `keys.remove(at:)` in the
primary index — every deleted id empties its key and shifts the whole key
array (FIFO ≈ 2× random: full-array shift vs half on average). Batch
deletes (`delete(ids:)`, `find().delete()`) are immune (single-sweep
`bulkRemove`).

After dead key slots (emptied keys stay as semantically absent slots,
swept in one pass once they exceed 25% of the keys):

| size | fifo µs p50/p99 | random µs p50/p99 |
|---|---|---|
| 10 000 | 3.3 / 6.2 | 3.5 / 4.8 |
| 1 000 000 | 4.7 / 7.4 | 5.7 / 8.8 |

Flat across sizes — unit-delete cost no longer depends on collection size
(120× faster at 1M docs, FIFO). The pure index removal is ~0.09 µs; the
rest is the tombstone write and payload read.

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

After C1 (incremental per-shard compaction):

| phase | gets | p50 µs | p99 µs | max µs |
|---|---|---|---|---|
| during compact | 10 781 | 2.5 | 4.0 | 66 002 |

compact() total: 94.6 ms. Reads flow between shard cycles; the max is one
get that queued behind a single shard's rewrite — the designed worst case.
The wall-clock increase (57 → 95 ms) is the accepted price: cross-shard
parallelism traded for read availability.

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
