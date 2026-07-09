# swift-msgpack fork — Work Order (NyaruDB2 performance track)

Audience: the agent/engineer working on the swift-msgpack fork
(`galileostudio` fork, currently pinned by NyaruDB2 at **v1.3.0** — the
release containing the robustness pass: corrupt flag, depth guard 512,
overflow/UTF-8/bounds/truncation checks, nil-into-non-optional throws).

Goal: make the coder pair fast enough to close NyaruDB2's remaining
insert/query gaps. NyaruDB2's profiling attributes the bulk of insert cost
to the encoder's intermediate value tree, and a large share of query cost
to per-document Codable decode. Everything below serves those two paths.

This document is self-contained. Where it says "gate", nothing ships
without that measurement.

---

## 0. Context: how NyaruDB2 consumes this library

The exact API surface NyaruDB2 depends on — none of it may break:

| Symbol | Usage |
|---|---|
| `MsgPackEncoder().encode(_: Encodable) -> Data` | every document write; called in parallel from multiple threads, **one fresh encoder instance per thread** |
| `MsgPackDecoder().decode(_:from: Data)` | point reads; legacy index-snapshot fallback |
| `MsgPackDecoder(options: .lazyScan).decode(_:from:)` | batched query decode (`decodeBatch`), fresh instance per thread |
| Decoding from `Data` **slices** (non-zero `startIndex`) | scan windows hand out slices; v1.3.0 fixed this — must stay correct |

Behavioral contracts NyaruDB2 relies on:

- **Map key order = Codable call order** (declaration order for synthesized
  `Codable`). NyaruDB2's `MsgPackExtractor` skip-scans top-level fields and
  early-breaks once all wanted keys are seen; reordering keys silently
  degrades that to full scans. Do not sort or rehash map keys.
- **Round-trip compatibility both ways**: bytes produced by v1.3.0 must
  decode with the new decoder, and bytes produced by the new encoder must
  decode with v1.3.0's decoder. NyaruDB2 databases on disk contain years of
  old-encoder payloads; there is no migration step. Byte-identical output is
  NOT required (each record is CRC'd at write time), but format-level
  compatibility is.
- **The v1.3.0 robustness guarantees are a floor, not a trade-off.** The new
  fast paths must keep: bounds checks (hoist them per-container/per-run
  instead of per-byte where possible — do not delete them), UTF-8
  validation, overflow checks, depth guard, throw-on-nil-into-non-optional.
  A benchmark win that reintroduces silent corruption will be rejected.
- Thread model: encoder/decoder instances are **not** shared across threads;
  NyaruDB2 always creates fresh instances inside parallel regions. You may
  therefore keep per-instance mutable scratch state (reusable buffers) —
  that is encouraged.

## 1. P2.1 — Streaming encoder (highest value)

**Problem (confirmed in source):** `MsgPackEncoder` builds a full
intermediate `MsgPackEncodedValue` tree (`.array([...])` / `.map([...])`)
for the entire document and then serialises the tree. Every field allocates
enum cases, arrays, and dictionaries that exist only to be walked once.
NyaruDB2 measures insert at ~17 µs/doc with encode as the prime suspect.

**Required design:**

- Encode **directly into a single growable contiguous byte buffer**
  (`[UInt8]` with `reserveCapacity`, or an `UnsafeMutableRawBufferPointer`
  arena) as the `Encodable` value walks the encoder. No intermediate value
  tree, no per-field `Data` allocations.
- Keyed/unkeyed container sizes are not known upfront in Codable. Use the
  standard back-patching technique: reserve the *widest* header (map32 /
  array32) — or better, write a placeholder, remember the offset, and patch
  the header after the container closes. Fixed-width headers keep patching
  O(1); do NOT buffer children separately to compute exact fixint headers
  (that reintroduces the tree). Oversized headers (map32 for a 5-key map)
  are valid MsgPack and decode everywhere — payload grows by a few bytes,
  which NyaruDB2 accepts. If you want compact headers, memmove-shrink at
  container close time is acceptable when the size class turns out smaller,
  but measure that it doesn't eat the win.
- Per-instance reusable scratch buffer: `encode` resets and reuses the
  buffer across calls on the same instance (NyaruDB2 reuses instances only
  within one thread's loop iteration today, but may adopt per-thread reuse
  if this lands).
- `String` fast path: write UTF-8 via `string.utf8` directly into the
  buffer; avoid `Data(string.utf8)` intermediates.
- `Date`: see §3 — whatever representation is chosen must stay
  round-trip-compatible with v1.3.0.

**Gate:** encoder microbenchmark (§4 harness) — ≥1.3× faster than v1.3.0's
encoder on the reference shape, zero allocations per field in Instruments'
Allocations template beyond the output buffer growth, and the §5
compatibility suite green.

## 2. P2.2 — Decoder: flat-struct fast path over a byte cursor

**Current state:** `.lazyScan` already exists (materialises containers on
demand over `withUnsafeBytes`). The remaining cost for NyaruDB2's shapes
(flat structs: ints, strings, a `Date`, optionally a small `[String]`) is
intermediate container/dictionary work and per-field dispatch.

**Required design:**

- A cursor-based decode path where a synthesized `Codable` struct's keyed
  container reads directly from the byte cursor: locate keys by comparing
  raw UTF-8 bytes (no `String` allocation for keys — NyaruDB2's
  `MsgPackExtractor` already proves this pattern), decode values straight
  into Swift types.
- Key lookup strategy: msgpack maps written by this encoder are in
  declaration order, and Codable synthesis *requests* keys in declaration
  order — the common case is a **sequential match** (cursor already at the
  requested key). Optimise for that: try the next entry first, fall back to
  a bounded scan of the remaining entries, only then to a lazily built
  offset table for pathological orders.
- Strings: single allocation per string value (`String(decoding:as:)` over
  the validated byte range). Numbers: direct loads (bounds-checked per
  value, not per byte).
- Expose the entry point so callers with many payloads amortise setup:
  `decoder.decode(T.self, from: data)` stays the API; internal scratch
  (key-offset table) is per-instance reusable.
- Must accept `Data` slices without copying (regression-tested in v1.3.0).

**Gate:** decode microbenchmark — target from the NyaruDB2 side is ≥1.5×
vs v1.3.0 on the reference shape; robustness suite (malformed inputs from
the v1.3.0 test suite) fully green on the new path.

## 3. Date/timestamp cost — measure FIRST, it may reorder priorities

NyaruDB2's benchmark documents carry a `Date`. Before optimising anything,
measure what one `Date` encode/decode costs in v1.3.0 relative to an `Int`
field (10×? 50×?). If `Date` goes through the msgpack timestamp extension
with per-call `Data` packing/validation, it may dominate the per-document
cost for small structs — in which case a `Date` fast path (fixext8/fixext4
direct write/read, `loadUnaligned`, no intermediate `Data`) is the cheapest
big win in the whole document and should land before P2.1/P2.2.

Constraint: the wire representation of `Date` must not change (old data
must decode). Only the code path may change.

## 4. Benchmark harness (in the fork repo, committed)

Add a small executable target (or XCTest `measure` suite) to the fork:

- **Reference shape** (mirrors NyaruDB2's harness document):

  ```swift
  struct User: Codable {
    let id: Int
    let name: String        // ~12 chars
    let email: String       // ~20 chars
    let age: Int
    let city: String        // ~8 chars, 10 distinct values
    let createdAt: Date
    let tags: [String]      // 0–3 short strings
  }
  ```

- Operations: encode 10k Users; decode 10k Users (fresh decoder per batch,
  same instance within the batch); plus a `Date`-only and `String`-heavy
  variant to expose per-type costs.
- Comparators reported in the same table: v1.3.0 encoder/decoder (pin the
  old version as a dev dependency or vendor the old files under a
  benchmark-only module), and `Foundation` `JSONEncoder`/`JSONDecoder` as
  the external yardstick.
- **Ship gate (from NyaruDB2's roadmap): ≥1.5× decode OR ≥1.3× encode vs
  v1.3.0 on the reference shape — otherwise the change does not merge.**
  Publish the table in the fork's README.

## 5. Compatibility & robustness suite (hard gate)

1. **Cross-version round-trip:** golden files. Commit a set of encoded
   fixtures produced by v1.3.0 (cover: nested containers, all int widths,
   negative ints, doubles, empty/long strings incl. multi-byte UTF-8, nil
   optionals, `Date` far past/future, empty arrays/maps, 16-bit and 32-bit
   container sizes). New decoder must decode all fixtures; new encoder's
   output for the same values must decode under the **old** decoder
   (vendored for the test).
2. **Robustness regression:** the entire v1.3.0 malformed-input suite runs
   against the new fast paths (truncations at every boundary, bad UTF-8,
   overflow values, deep nesting, huge claimed lengths, empty input).
3. **Slice decoding:** every decode test additionally runs on a
   mid-buffer `Data` slice.
4. **Key-order property test:** encode with synthesized Codable, assert map
   keys appear in declaration order (protects NyaruDB2's skip-scan).

## 6. Deliverables & sequencing

| # | Item | Gate |
|---|------|------|
| 1 | §4 harness + v1.3.0 baseline numbers committed | table in README |
| 2 | §3 Date cost measurement (+ fast path if it dominates) | numbers; wire format unchanged |
| 3 | §5 golden fixtures + compatibility suite | green |
| 4 | P2.1 streaming encoder | ≥1.3× encode, zero per-field allocs, §5 green |
| 5 | P2.2 cursor decoder fast path | ≥1.5× decode, §5 green incl. malformed suite |
| 6 | Tag a release; NyaruDB2 bumps the pin and re-runs its full suite + benchmarks | NyaruDB2 `swift test` green, BENCHMARKS.md updated |

Sequencing note: 1→3 are prerequisites; 4 and 5 are independent of each
other and can land in either order (NyaruDB2's profiling will say which
matters more — encoder feeds Insert, decoder feeds Query).

## 7. Non-goals (do not do these)

- No wire-format extensions or custom types — this is a MessagePack
  implementation, not a new format.
- No public API redesign; `MsgPackEncoder`/`MsgPackDecoder` signatures and
  the `.lazyScan` option stay.
- No removal or weakening of the v1.3.0 robustness guards to win benchmarks.
- No shared-mutable-state "global cache" for thread safety reasons —
  per-instance scratch only.
- No sorting/canonicalisation of map keys.
