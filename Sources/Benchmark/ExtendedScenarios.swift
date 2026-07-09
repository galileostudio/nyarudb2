import Foundation
import NyaruDB2
import SwiftMsgpack

// MARK: - Memory peak sampling

/// Samples the process's physical footprint on a background thread and
/// records the maximum seen between `start()` and `stop()`.
final class MemoryPeakSampler: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: UInt64 = 0
  private var running = false

  static func currentFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
  }

  func start() {
    lock.lock()
    peak = Self.currentFootprint()
    running = true
    lock.unlock()
    let thread = Thread { [weak self] in
      while true {
        guard let self else { return }
        self.lock.lock()
        if !self.running {
          self.lock.unlock()
          return
        }
        self.peak = max(self.peak, Self.currentFootprint())
        self.lock.unlock()
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  /// Stops sampling and returns the peak footprint in bytes.
  func stop() -> UInt64 {
    lock.lock()
    running = false
    let result = max(peak, Self.currentFootprint())
    lock.unlock()
    return result
  }
}

// MARK: - Small helpers

private func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
  guard !sortedValues.isEmpty else { return 0 }
  let index = min(sortedValues.count - 1, Int(Double(sortedValues.count) * p))
  return sortedValues[index]
}

private func mb(_ bytes: UInt64) -> String {
  String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

/// Microsecond wall-clock measurement of one async operation.
private func measureMicros(_ body: () async throws -> Void) async rethrows -> Double {
  let t0 = DispatchTime.now().uptimeNanoseconds
  try await body()
  return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000
}

// MARK: - Extended scenarios (H4)

/// Standalone benchmark scenarios beyond the standard suite, selected with
/// `--scenario <name>`. Each prints its own report; they establish the
/// baselines that gate the roadmap's memory/latency/index-scale tracks.
enum ExtendedScenarios {
  private static func tempDir(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "NyaruExtended-\(name)-\(UUID().uuidString)")
  }

  private static func document(_ id: Int, category: String = "Test", contentSize: Int = 64)
    -> TestDocument
  {
    TestDocument(
      id: id, name: "Document \(id)", category: category,
      content: String(repeating: "\(id % 97)x", count: contentSize / 2))
  }

  private static func openDB(_ dir: URL) throws -> NyaruDB {
    try NyaruDB(
      path: dir.path,
      options: DatabaseOptions(compression: .none, fileProtection: .none, format: .msgpack))
  }

  private static func bulkFill(
    _ collection: NyaruCollection<TestDocument>, range: Range<Int>,
    category: (Int) -> String = { _ in "Test" }, contentSize: Int = 64,
    id: (Int) -> Int = { $0 }
  ) async throws {
    for chunk in stride(from: range.lowerBound, to: range.upperBound, by: 25_000) {
      let end = min(chunk + 25_000, range.upperBound)
      let docs = (chunk..<end).map {
        document(id($0), category: category($0), contentSize: contentSize)
      }
      try await collection.insert(contentsOf: docs)
    }
  }

  static func run(_ name: String, documentCount: Int, explicitCount: Bool) async {
    do {
      switch name {
      case "curve":
        try await unitInsertCurve(maxDocs: explicitCount ? documentCount : 1_000_000)
      case "concurrency":
        try await concurrency(docs: explicitCount ? documentCount : 50_000)
      case "bigdocs":
        try await bigDocsAndManyShards()
      case "memory":
        try await memoryPeaks(docs: explicitCount ? documentCount : 64_000)
      case "residual":
        try await residualPredicates(docs: explicitCount ? documentCount : 200_000)
      case "unitdelete":
        try await unitDeleteCurve(maxDocs: explicitCount ? documentCount : 1_000_000)
      case "decompose":
        try await costDecomposition(docs: explicitCount ? documentCount : 100_000)
      case "querycost":
        try await queryCost(docs: explicitCount ? documentCount : 100_000)
      default:
        print(
          "Unknown scenario '\(name)'. Available: "
            + "curve, concurrency, bigdocs, memory, residual, unitdelete, decompose, querycost")
        Foundation.exit(1)
      }
    } catch {
      print("\(ANSI.FG.red)Scenario '\(name)' failed: \(error)\(ANSI.reset)")
      Foundation.exit(1)
    }
  }

  // MARK: H4.1 — unit-insert latency vs collection size (gates E1)

  /// Measures unitary insert/get latency at increasing collection sizes.
  /// The id index has one unique key per document, and every unitary insert
  /// pays an O(n) sorted-array insertion — this curve decides whether the
  /// index needs an O(log n) structure (roadmap E1).
  static func unitInsertCurve(maxDocs: Int) async throws {
    print("\(ANSI.bold)📈 Unit-insert latency vs collection size\(ANSI.reset)")
    print("\(ANSI.FG.gray)compression none, msgpack, single shard, 1k unit ops per size\(ANSI.reset)\n")
    let sizes = [10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000].filter { $0 <= maxDocs }
    print("      size │ build (s) │ 1k inserts (ms) │ insert µs p50/p99 │ 1k gets (ms)")
    print("───────────┼───────────┼─────────────────┼───────────────────┼─────────────")

    for size in sizes {
      let dir = tempDir("curve")
      defer { try? FileManager.default.removeItem(at: dir) }
      let db = try openDB(dir)
      let collection = try await db.collection(
        "test", of: TestDocument.self, options: CollectionOptions(idField: "id"))

      // Build with EVEN ids so the unit inserts (random odd ids) land at
      // uniformly random positions of the sorted key array. Ascending ids
      // would always append — the O(n) memmove cost would never show.
      let buildStart = CFAbsoluteTimeGetCurrent()
      try await bulkFill(collection, range: 1..<(size + 1), id: { $0 * 2 })
      let buildTime = CFAbsoluteTimeGetCurrent() - buildStart

      var oddIDs: Set<Int> = []
      var seed: UInt64 = 0x1234_5678
      while oddIDs.count < 1_000 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        oddIDs.insert(Int(seed % UInt64(size * 2)) | 1)
      }

      var insertLatencies: [Double] = []
      insertLatencies.reserveCapacity(1_000)
      let insertStart = CFAbsoluteTimeGetCurrent()
      for id in oddIDs {
        let micros = try await measureMicros { try await collection.insert(document(id)) }
        insertLatencies.append(micros)
      }
      let insertTotal = (CFAbsoluteTimeGetCurrent() - insertStart) * 1000
      insertLatencies.sort()

      let getStart = CFAbsoluteTimeGetCurrent()
      var stride = size / 1_000
      if stride == 0 { stride = 1 }
      for id in Swift.stride(from: 1, through: size, by: stride) {
        _ = try await collection.get(id: id * 2)
      }
      let getTotal = (CFAbsoluteTimeGetCurrent() - getStart) * 1000

      print(
        String(
          format: "%10d │ %9.2f │ %15.1f │ %8.1f / %6.1f │ %11.1f",
          size, buildTime, insertTotal,
          percentile(insertLatencies, 0.5), percentile(insertLatencies, 0.99), getTotal))
      try await db.close()
    }
    print("")
  }

  // MARK: — unit-delete latency vs collection size

  /// Measures one-by-one `delete(id:)` latency at increasing collection
  /// sizes, in two patterns: FIFO (oldest ids first — every removal lands at
  /// position 0 of the sorted id-index key array, the worst case for the
  /// O(n) `keys.remove(at:)` shift) and uniformly random ids. Only the id
  /// index exists, isolating the key-array cost from posting-list work.
  static func unitDeleteCurve(maxDocs: Int) async throws {
    print("\(ANSI.bold)📈 Unit-delete latency vs collection size\(ANSI.reset)")
    print("\(ANSI.FG.gray)compression none, msgpack, id index only, 1k unit deletes per size/pattern\(ANSI.reset)\n")
    let sizes = [10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000].filter { $0 <= maxDocs }
    print("      size │ pattern │ 1k deletes (ms) │ delete µs p50/p99")
    print("───────────┼─────────┼─────────────────┼──────────────────")

    for size in sizes {
      for pattern in ["fifo", "random"] {
        let dir = tempDir("unitdelete")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try openDB(dir)
        let collection = try await db.collection(
          "test", of: TestDocument.self, options: CollectionOptions(idField: "id"))
        try await bulkFill(collection, range: 1..<(size + 1))

        var victims: [Int]
        if pattern == "fifo" {
          victims = Array(1...1_000)
        } else {
          var seed: UInt64 = 0xFACE_FEED
          var set = Set<Int>()
          while set.count < 1_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            set.insert(Int(seed % UInt64(size)) + 1)
          }
          victims = Array(set)
        }

        var latencies: [Double] = []
        latencies.reserveCapacity(victims.count)
        let start = CFAbsoluteTimeGetCurrent()
        for id in victims {
          latencies.append(try await measureMicros { _ = try await collection.delete(id: id) })
        }
        let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
        latencies.sort()

        print(
          String(
            format: "%10d │ %@ │ %15.1f │ %8.1f / %6.1f",
            size, pattern.padding(toLength: 7, withPad: " ", startingAt: 0),
            total, percentile(latencies, 0.5), percentile(latencies, 0.99)))
        try await db.close()
      }
    }
    print("")
  }

  // MARK: — P0.3: cost decomposition for Query / Insert / BatchDelete

  /// A document shaped like the external multi-database harness's User:
  /// flat struct with strings, ints, a Date, and a small string array.
  struct HarnessUser: Codable, Sendable {
    let id: Int
    let name: String
    let email: String
    let age: Int
    let city: String
    let createdAt: Date
    let tags: [String]
  }

  private static func harnessUser(_ id: Int) -> HarnessUser {
    HarnessUser(
      id: id,
      name: "User Name \(id % 997)",
      email: "user\(id)@example.com",
      age: 18 + (id % 60),
      city: "city-\(id % 10)",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
      tags: id % 3 == 0 ? [] : ["tag\(id % 7)", "tag\(id % 13)"]
    )
  }

  /// Chunk-free parallel map for the coder microbenchmarks — mirrors the
  /// engine's decodeBatch shape (fresh coder instance per element).
  private static func parallelMap<T, R>(
    _ items: [T], _ transform: @escaping (T) throws -> R
  ) throws -> [R] {
    let count = items.count
    var results = [R?](repeating: nil, count: count)
    let lock = NSLock()
    nonisolated(unsafe) var firstError: Error?
    results.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let out = buffer
      items.withUnsafeBufferPointer { source in
        nonisolated(unsafe) let input = source
        DispatchQueue.concurrentPerform(iterations: count) { i in
          do {
            out[i] = try transform(input[i])
          } catch {
            lock.lock()
            if firstError == nil { firstError = error }
            lock.unlock()
          }
        }
      }
    }
    if let error = firstError { throw error }
    return results.map { $0! }
  }

  /// Attributes the wall time of the three losing harness operations to
  /// engine components using only public API: standalone coder costs
  /// (via SwiftMsgpack directly, exactly what Serializer does), covered
  /// count (planner+probe+actor overhead, zero I/O), covered query
  /// (everything), and a with/without-secondary-indexes delete ablation.
  static func costDecomposition(docs: Int) async throws {
    let queryLimit = 1_000
    print("\(ANSI.bold)📈 P0.3 cost decomposition — \(docs) docs, msgpack\(ANSI.reset)")
    print("\(ANSI.FG.gray)harness User shape (Date + [String]), partitionKey city (10), indexes [age, city]\(ANSI.reset)\n")

    func ms(_ s: Double) -> String { String(format: "%8.2f ms", s * 1000) }
    func perDoc(_ s: Double, _ n: Int) -> String {
      String(format: "%6.2f µs/doc", s * 1_000_000 / Double(n))
    }

    // ---- A. Coder micro (no engine) --------------------------------------
    print("\(ANSI.bold)A. Coders standalone (10k docs)\(ANSI.reset)")
    let coderDocs = (0..<10_000).map { harnessUser($0) }

    let sharedEncoder = MsgPackEncoder()
    var t0 = CFAbsoluteTimeGetCurrent()
    let encodedSerial = try coderDocs.map { try sharedEncoder.encode($0) }
    let tEncodeSerial = CFAbsoluteTimeGetCurrent() - t0
    print("  encode serial          \(ms(tEncodeSerial))  \(perDoc(tEncodeSerial, coderDocs.count))")

    t0 = CFAbsoluteTimeGetCurrent()
    _ = try parallelMap(coderDocs) { try MsgPackEncoder().encode($0) }
    let tEncodePar = CFAbsoluteTimeGetCurrent() - t0
    print("  encode parallel        \(ms(tEncodePar))  \(perDoc(tEncodePar, coderDocs.count))")

    t0 = CFAbsoluteTimeGetCurrent()
    _ = try parallelMap(encodedSerial) {
      try MsgPackDecoder(options: .lazyScan).decode(HarnessUser.self, from: $0)
    }
    let tDecodePar = CFAbsoluteTimeGetCurrent() - t0
    print("  decode parallel        \(ms(tDecodePar))  \(perDoc(tDecodePar, coderDocs.count))")

    t0 = CFAbsoluteTimeGetCurrent()
    for data in encodedSerial.prefix(2_000) {
      _ = try MsgPackDecoder(options: .lazyScan).decode(HarnessUser.self, from: data)
    }
    let tDecodeSerial = CFAbsoluteTimeGetCurrent() - t0
    print("  decode serial (2k)     \(ms(tDecodeSerial))  \(perDoc(tDecodeSerial, 2_000))")

    // Date-cost probe: identical struct with and without a Date field.
    struct NoDate: Codable, Sendable { let id: Int; let age: Int; let name: String }
    struct WithDate: Codable, Sendable {
      let id: Int
      let age: Int
      let name: String
      let createdAt: Date
    }
    let noDate = (0..<10_000).map { NoDate(id: $0, age: $0 % 60, name: "User \($0 % 997)") }
    let withDate = (0..<10_000).map {
      WithDate(
        id: $0, age: $0 % 60, name: "User \($0 % 997)",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
    }
    t0 = CFAbsoluteTimeGetCurrent()
    let encNoDate = try noDate.map { try sharedEncoder.encode($0) }
    let tEncNoDate = CFAbsoluteTimeGetCurrent() - t0
    t0 = CFAbsoluteTimeGetCurrent()
    let encWithDate = try withDate.map { try sharedEncoder.encode($0) }
    let tEncWithDate = CFAbsoluteTimeGetCurrent() - t0
    t0 = CFAbsoluteTimeGetCurrent()
    for data in encNoDate {
      _ = try MsgPackDecoder(options: .lazyScan).decode(NoDate.self, from: data)
    }
    let tDecNoDate = CFAbsoluteTimeGetCurrent() - t0
    t0 = CFAbsoluteTimeGetCurrent()
    for data in encWithDate {
      _ = try MsgPackDecoder(options: .lazyScan).decode(WithDate.self, from: data)
    }
    let tDecWithDate = CFAbsoluteTimeGetCurrent() - t0
    print(
      "  Date field marginal    encode +\(perDoc(tEncWithDate - tEncNoDate, 10_000))"
        + "  decode +\(perDoc(tDecWithDate - tDecNoDate, 10_000))")

    // ---- B. Query decomposition (covered, engine) -------------------------
    print("\n\(ANSI.bold)B. Covered query (city == X, limit \(queryLimit))\(ANSI.reset)")
    for compression in [CompressionMethod.none, .gzip] {
      let dir = tempDir("decompose-\(compression.rawValue)")
      defer { try? FileManager.default.removeItem(at: dir) }
      let db = try NyaruDB(
        path: dir.path,
        options: DatabaseOptions(compression: compression, format: .msgpack))
      let collection = try await db.collection(
        "users", of: HarnessUser.self,
        options: CollectionOptions(
          idField: "id", partitionKey: "city", indexedFields: ["age", "city"]))

      let insertStart = CFAbsoluteTimeGetCurrent()
      for chunk in stride(from: 0, to: docs, by: 25_000) {
        let end = min(chunk + 25_000, docs)
        try await collection.insert(contentsOf: (chunk..<end).map { harnessUser($0) })
      }
      let tInsert = CFAbsoluteTimeGetCurrent() - insertStart

      // Warmup, then averages.
      _ = try await collection.find().where("city", isEqualTo: "city-3")
        .limit(queryLimit).execute()

      var tCount = 0.0
      var tQuery = 0.0
      let runs = 50
      for _ in 0..<runs {
        t0 = CFAbsoluteTimeGetCurrent()
        _ = try await collection.find().where("city", isEqualTo: "city-3")
          .limit(queryLimit).count()
        tCount += CFAbsoluteTimeGetCurrent() - t0

        t0 = CFAbsoluteTimeGetCurrent()
        _ = try await collection.find().where("city", isEqualTo: "city-3")
          .limit(queryLimit).execute()
        tQuery += CFAbsoluteTimeGetCurrent() - t0
      }
      tCount /= Double(runs)
      tQuery /= Double(runs)

      // Standalone decode of the same 1k payload shape.
      let sample = (0..<queryLimit).map { harnessUser($0 * 10 + 3) }
      let samplePayloads = try sample.map { try MsgPackEncoder().encode($0) }
      t0 = CFAbsoluteTimeGetCurrent()
      for _ in 0..<runs {
        _ = try parallelMap(samplePayloads) {
          try MsgPackDecoder(options: .lazyScan).decode(HarnessUser.self, from: $0)
        }
      }
      let tDecode1k = (CFAbsoluteTimeGetCurrent() - t0) / Double(runs)

      let residual = tQuery - tCount - tDecode1k
      print("  [\(compression.rawValue)] insert \(docs): \(ms(tInsert)) (\(perDoc(tInsert, docs)))")
      print("  [\(compression.rawValue)] query total        \(ms(tQuery))")
      print("  [\(compression.rawValue)]   plan+probe+actor \(ms(tCount))   (covered count)")
      print("  [\(compression.rawValue)]   decode (1k)      \(ms(tDecode1k))   (standalone)")
      print("  [\(compression.rawValue)]   io+crc+restore   \(ms(residual))   (residual)")
      try await db.close()
    }

    // ---- C. Batch delete ablation -----------------------------------------
    print("\n\(ANSI.bold)C. Batch delete (\(docs - docs / 10) docs in one call)\(ANSI.reset)")
    for (label, fields) in [("with secondary idx", ["age", "city"]), ("id index only", [])] {
      let dir = tempDir("decompose-del")
      defer { try? FileManager.default.removeItem(at: dir) }
      let db = try NyaruDB(
        path: dir.path, options: DatabaseOptions(compression: .none, format: .msgpack))
      let collection = try await db.collection(
        "users", of: HarnessUser.self,
        options: CollectionOptions(
          idField: "id", partitionKey: "city", indexedFields: fields))
      for chunk in stride(from: 0, to: docs, by: 25_000) {
        let end = min(chunk + 25_000, docs)
        try await collection.insert(contentsOf: (chunk..<end).map { harnessUser($0) })
      }

      let victims = Array(0..<(docs - docs / 10))
      t0 = CFAbsoluteTimeGetCurrent()
      let removed = try await collection.delete(ids: victims)
      let tDelete = CFAbsoluteTimeGetCurrent() - t0
      print(
        "  \(label.padding(toLength: 20, withPad: " ", startingAt: 0)) "
          + "\(ms(tDelete))  \(perDoc(tDelete, removed))  (\(removed) removed)")
      try await db.close()
    }
    print("")
  }

  // MARK: Query cost breakdown — which query shape is the headline?

  /// Times the three query shapes of the cross-DB benchmark separately so we
  /// can see which one drives the aggregate "Query" number. TestDocument
  /// shape, non-partitioned, indexes [category, name, id] — matching the main
  /// suite. The covered shapes (id-range+limit, name-eq) skip `matchedParsed`;
  /// only the unaligned `sort` shape hits the parse-then-decode path.
  static func queryCost(docs: Int) async throws {
    print("\(ANSI.bold)📈 Query cost breakdown — \(docs) docs, msgpack\(ANSI.reset)")
    print("\(ANSI.FG.gray)TestDocument shape, non-partitioned, indexes [category, name, id]\(ANSI.reset)\n")

    func ms(_ s: Double) -> String { String(format: "%7.3f ms/exec", s * 1000) }

    let dir = tempDir("querycost")
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try NyaruDB(path: dir.path, options: DatabaseOptions(compression: .none, format: .msgpack))
    let collection = try await db.collection(
      "test", of: TestDocument.self,
      options: CollectionOptions(idField: "id", indexedFields: ["category", "name", "id"]))

    // Match the main suite's payload: content = "NyaruDB"×50, ×3 ≈ 1050 B.
    let filler = String(repeating: String(repeating: "NyaruDB", count: 50), count: 3)
    for chunk in stride(from: 1, to: docs + 1, by: 25_000) {
      let end = min(chunk + 25_000, docs + 1)
      try await collection.insert(
        contentsOf: (chunk..<end).map {
          TestDocument(id: $0, name: "Document \($0)", category: "Test", content: filler)
        })
    }

    // Warmup each shape.
    _ = try await collection.find().where("id", isGreaterThan: 100).limit(100).execute()
    _ = try await collection.find().where("name", isEqualTo: "Document 42").execute()
    _ = try await collection.find().where("id", isBetween: 1000, and: 2000).sort(by: "name").execute()

    let runs = 200
    func time(_ label: String, rows: String, _ body: () async throws -> Int) async rethrows {
      let t0 = CFAbsoluteTimeGetCurrent()
      var n = 0
      for _ in 0..<runs { n = try await body() }
      let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(runs)
      print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0))\(ms(dt))   \(rows) rows: \(n)")
    }

    print("\(ANSI.bold)Per-shape execute() cost (avg of \(runs))\(ANSI.reset)")
    try await time("covered: id>100 limit 100", rows: "→") {
      try await collection.find().where("id", isGreaterThan: 100).limit(100).execute().count
    }
    try await time("covered: name == \"Document 42\"", rows: "→") {
      try await collection.find().where("name", isEqualTo: "Document 42").execute().count
    }
    try await time("sort: id in 1000..2000 by name", rows: "→") {
      try await collection.find().where("id", isBetween: 1000, and: 2000).sort(by: "name").execute().count
    }
    // Same range, NO sort → covered path, decode-only floor. The gap to the
    // sorted row above is what the sort path's redundant full-parse costs.
    try await time("range: id in 1000..2000 (no sort)", rows: "→") {
      try await collection.find().where("id", isBetween: 1000, and: 2000).execute().count
    }
    // Sort pushdown shapes (sort by an indexed field != the predicate field,
    // WITH a limit): the name index yields the page already ordered, so only
    // ~limit docs are read instead of every match + an in-memory sort.
    try await time("sort+limit: id in 1000..2000 by name L20", rows: "→") {
      try await collection.find().where("id", isBetween: 1000, and: 2000)
        .sort(by: "name").limit(20).execute().count
    }
    try await time("sort+limit: id>100 by name L20 (dense)", rows: "→") {
      try await collection.find().where("id", isGreaterThan: 100)
        .sort(by: "name").limit(20).execute().count
    }
    // Deferred (faulting-style): resolve + order the 1001-row sort but do NOT
    // decode — the counterpart to CoreData returning unrealised faults. The
    // gap to the eager sort above is the decode share that faulting avoids.
    try await time("sort deferred: id in 1000..2000 by name", rows: "→") {
      try await collection.find().where("id", isBetween: 1000, and: 2000)
        .sort(by: "name").fetchDeferred().count
    }
    print("")

    // ---- Decode decomposition: where Query C's cost actually goes ----
    // Representative payloads for the sort query's result set (1001 docs, ~1KB
    // content each), measured against the coder directly.
    let sampleDocs = (1000...2000).map {
      TestDocument(id: $0, name: "Document \($0)", category: "Test", content: filler)
    }
    let payloads = try sampleDocs.map { try MsgPackEncoder().encode($0) }
    let avgBytes = payloads.reduce(0) { $0 + $1.count } / payloads.count

    // A projection struct that omits `content`: with lazyScan the decoder never
    // materialises the large field it isn't asked for.
    struct QueryProjection: Codable { let id: Int; let name: String; let category: String }

    func msT(_ s: Double) -> String { String(format: "%7.3f ms", s * 1000) }
    func decodeTime(_ label: String, _ body: () throws -> Void) rethrows {
      var best = Double.greatestFiniteMagnitude
      for _ in 0..<15 {
        let t0 = CFAbsoluteTimeGetCurrent()
        try body()
        best = min(best, CFAbsoluteTimeGetCurrent() - t0)
      }
      print("  \(label.padding(toLength: 40, withPad: " ", startingAt: 0))\(msT(best))")
    }

    print("\(ANSI.bold)Decode decomposition (\(payloads.count) docs, ~\(avgBytes) B each, best-of-15)\(ANSI.reset)")
    try decodeTime("full T, parallel, new decoder/doc") {
      _ = try parallelMap(payloads) {
        try MsgPackDecoder(options: .lazyScan).decode(TestDocument.self, from: $0)
      }
    }
    try decodeTime("projection (id,name,category), parallel") {
      _ = try parallelMap(payloads) {
        try MsgPackDecoder(options: .lazyScan).decode(QueryProjection.self, from: $0)
      }
    }
    try decodeTime("full T, serial, new decoder/doc") {
      for p in payloads { _ = try MsgPackDecoder(options: .lazyScan).decode(TestDocument.self, from: p) }
    }
    try decodeTime("full T, serial, reused decoder") {
      let dec = MsgPackDecoder(options: .lazyScan)
      for p in payloads { _ = try dec.decode(TestDocument.self, from: p) }
    }
    print("")
    print("\(ANSI.FG.gray)projection vs full = content-decode share (projection lever).\(ANSI.reset)")
    print("\(ANSI.FG.gray)serial new vs reused = decoder-alloc share (reuse lever).\(ANSI.reset)")
    try await db.close()
  }

  // MARK: H4.2 — read latency under concurrent writes and compaction (gates C1)

  /// Measures point-read latency in three phases: idle, during concurrent
  /// bulk writes, and during `compact()`. The compaction gate blocks reads
  /// for the whole multi-shard compaction — this baseline gates the
  /// incremental per-shard compaction work (roadmap C1).
  static func concurrency(docs: Int) async throws {
    let categories = ["A", "B", "C", "D", "E", "F", "G", "H"]
    print("\(ANSI.bold)📈 Read latency under concurrency\(ANSI.reset)")
    print("\(ANSI.FG.gray)\(docs) docs, \(categories.count) partition shards, get(id:) latencies in µs\(ANSI.reset)\n")

    let dir = tempDir("concurrency")
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try openDB(dir)
    let collection = try await db.collection(
      "test", of: TestDocument.self,
      options: CollectionOptions(idField: "id", partitionKey: "category"))
    try await bulkFill(collection, range: 1..<(docs + 1)) { categories[$0 % categories.count] }

    func measureGets(_ count: Int) async throws -> [Double] {
      var latencies: [Double] = []
      latencies.reserveCapacity(count)
      var seed: UInt64 = 0x9E37_79B9
      for _ in 0..<count {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let id = Int(seed % UInt64(docs)) + 1
        latencies.append(try await measureMicros { _ = try await collection.get(id: id) })
      }
      return latencies.sorted()
    }

    print("            phase │      gets │  p50 µs │   p99 µs │  max µs")
    print("──────────────────┼───────────┼─────────┼──────────┼─────────")
    func report(_ phase: String, _ latencies: [Double]) {
      let padded = String(repeating: " ", count: max(0, 17 - phase.count)) + phase
      print(
        padded
          + String(
            format: " │ %9d │ %7.1f │ %8.1f │ %7.0f",
            latencies.count,
            percentile(latencies, 0.5), percentile(latencies, 0.99), latencies.last ?? 0))
    }

    report("idle", try await measureGets(2_000))

    let writer = Task {
      for chunk in 0..<20 {
        let base = docs + chunk * 1_000 + 1
        let batch = (base..<(base + 1_000)).map {
          document($0, category: categories[$0 % categories.count])
        }
        try await collection.insert(contentsOf: batch)
      }
    }
    report("during writes", try await measureGets(2_000))
    try await writer.value

    // Create fragmentation so compact() has real work on every shard.
    let victims = Swift.stride(from: 1, through: docs, by: 2).map { $0 }
    for chunk in victims.chunked(into: 5_000) {
      _ = try await collection.delete(ids: chunk)
    }

    let compactDone = Flag()
    let compactStart = CFAbsoluteTimeGetCurrent()
    let compactor = Task {
      defer { compactDone.set() }
      try await collection.compact()
    }
    var duringCompact: [Double] = []
    var seed: UInt64 = 0xDEAD_BEEF
    while !compactDone.isSet {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let id = Int(seed % UInt64(docs / 2)) * 2 + 2  // survivors are even ids
      duringCompact.append(
        try await measureMicros { _ = try await collection.get(id: id) })
    }
    try await compactor.value
    let compactTime = (CFAbsoluteTimeGetCurrent() - compactStart) * 1000
    report("during compact", duringCompact.sorted())
    print(String(format: "\n  compact() total: %.1f ms", compactTime))

    if let metrics = try? await collection.metrics() {
      print(
        "  📈 metrics: indexLookups=\(metrics.indexLookups) read=\(mb(metrics.bytesRead)) "
          + "written=\(mb(metrics.bytesWritten)) compactions=\(metrics.compactionCount)")
    }
    try await db.close()
    print("")
  }

  // MARK: H4.3 — large documents and many shards

  static func bigDocsAndManyShards() async throws {
    print("\(ANSI.bold)📈 Large documents (~1.2 MB each)\(ANSI.reset)")
    do {
      let dir = tempDir("bigdocs")
      defer { try? FileManager.default.removeItem(at: dir) }
      let db = try openDB(dir)
      let collection = try await db.collection(
        "test", of: TestDocument.self, options: CollectionOptions(idField: "id"))

      let insertStart = CFAbsoluteTimeGetCurrent()
      for chunk in stride(from: 1, to: 151, by: 10) {
        let docs = (chunk..<min(chunk + 10, 151)).map {
          document($0, contentSize: 1_200_000)
        }
        try await collection.insert(contentsOf: docs)
      }
      let insertTime = CFAbsoluteTimeGetCurrent() - insertStart

      let getMicros = try await measureMicros { _ = try await collection.get(id: 75) }
      let queryStart = CFAbsoluteTimeGetCurrent()
      let hits = try await collection.find().where("id", isBetween: 50, and: 60).execute()
      let queryTime = (CFAbsoluteTimeGetCurrent() - queryStart) * 1000

      _ = try await collection.delete(ids: Array(1...50))
      let compactStart = CFAbsoluteTimeGetCurrent()
      try await collection.compact()
      let compactTime = (CFAbsoluteTimeGetCurrent() - compactStart) * 1000

      let stats = try await collection.stats()
      print(
        String(
          format:
            "  insert 150 docs: %.2f s │ get: %.1f µs │ range query (%d hits): %.1f ms │ compact after 50 deletes: %.1f ms │ size: %@",
          insertTime, getMicros, hits.count, queryTime, compactTime, mb(stats.sizeInBytes)))
      try await db.close()
    }

    print("\n\(ANSI.bold)📈 Many shards (150 partition values, 30k docs)\(ANSI.reset)")
    do {
      let dir = tempDir("manyshards")
      defer { try? FileManager.default.removeItem(at: dir) }
      let db = try openDB(dir)
      let collection = try await db.collection(
        "test", of: TestDocument.self,
        options: CollectionOptions(idField: "id", partitionKey: "category"))

      let insertStart = CFAbsoluteTimeGetCurrent()
      try await bulkFill(collection, range: 1..<30_001) { "cat-\($0 % 150)" }
      let insertTime = CFAbsoluteTimeGetCurrent() - insertStart

      let partitionStart = CFAbsoluteTimeGetCurrent()
      let partitionHits = try await collection.find()
        .where("category", isEqualTo: "cat-42").execute()
      let partitionTime = (CFAbsoluteTimeGetCurrent() - partitionStart) * 1000

      let sampler = MemoryPeakSampler()
      let baseline = MemoryPeakSampler.currentFootprint()
      sampler.start()
      let scanStart = CFAbsoluteTimeGetCurrent()
      let all = try await collection.all()
      let scanTime = (CFAbsoluteTimeGetCurrent() - scanStart) * 1000
      let scanPeak = sampler.stop()

      let compactStart = CFAbsoluteTimeGetCurrent()
      try await collection.compact()
      let compactTime = (CFAbsoluteTimeGetCurrent() - compactStart) * 1000

      let stats = try await collection.stats()
      print(
        String(
          format:
            "  insert 30k: %.2f s │ partition query (%d hits): %.1f ms │ full scan (%d docs): %.1f ms (peak +%@) │ compact %d shards: %.1f ms",
          insertTime, partitionHits.count, partitionTime, all.count, scanTime,
          mb(scanPeak > baseline ? scanPeak - baseline : 0), stats.shardCount, compactTime))
      try await db.close()
    }
    print("")
  }

  // MARK: — residual-predicate queries (gates Q2/Q4)

  /// Queries whose predicates cannot be pushed to an index: every candidate
  /// is parsed and evaluated in memory. Exercises the parse+evaluate loop
  /// and the sort+limit path over large candidate sets, at two payload
  /// sizes — small documents are the worst case for skip-scan extraction
  /// (nothing to skip), large ones its motivation.
  static func residualPredicates(docs: Int) async throws {
    for (label, contentSize, count) in [("small (~64 B)", 64, docs), ("large (~1 KiB)", 1_024, docs / 4)] {
      print("\(ANSI.bold)📈 Residual-predicate queries, \(count) docs, content \(label)\(ANSI.reset)")
      print("\(ANSI.FG.gray)compression none, msgpack, id index only — predicates evaluated in memory\(ANSI.reset)\n")

      let dir = tempDir("residual")
      defer { try? FileManager.default.removeItem(at: dir) }
      let db = try openDB(dir)
      let collection = try await db.collection(
        "test", of: TestDocument.self, options: CollectionOptions(idField: "id"))
      try await bulkFill(collection, range: 1..<(count + 1), contentSize: contentSize)

      func time(_ label: String, _ body: () async throws -> Int) async rethrows {
        let start = CFAbsoluteTimeGetCurrent()
        let hits = try await body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(
          "  " + label.padding(toLength: 52, withPad: " ", startingAt: 0)
            + String(format: "%8.1f ms  (%d hits)", ms, hits))
      }

      try await time("full scan + endsWith filter") {
        try await collection.find().where("name", endsWith: "7").execute().count
      }
      try await time("same filter + sort(id) + limit(10)") {
        try await collection.find().where("name", endsWith: "7")
          .sort(by: "id").limit(10).execute().count
      }
      try await time("same filter + sort(id) desc + offset(20) + limit(10)") {
        try await collection.find().where("name", endsWith: "7")
          .sort(by: "id", ascending: false).offset(20).limit(10).execute().count
      }
      try await time("count() with residual filter") {
        try await collection.find().where("name", contains: "99").count()
      }
      try await db.close()
      print("")
    }
  }

  // MARK: H4.4 — memory peaks on whole-shard scans (gates M1/M2)

  /// Builds one large single-shard collection and measures the process
  /// footprint peak during `all()` and during an index rebuild — the two
  /// paths that materialise whole shards (roadmap M1/M2 gate).
  static func memoryPeaks(docs: Int) async throws {
    let contentSize = 8_192
    print("\(ANSI.bold)📈 Memory peaks on whole-shard scans\(ANSI.reset)")
    print("\(ANSI.FG.gray)\(docs) docs × ~\(contentSize) B, compression none, single shard\(ANSI.reset)\n")

    let dir = tempDir("memory")
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
      let db = try openDB(dir)
      let collection = try await db.collection(
        "test", of: TestDocument.self, options: CollectionOptions(idField: "id"))
      try await bulkFill(collection, range: 1..<(docs + 1), contentSize: contentSize)
      let stats = try await collection.stats()
      print("  shard size: \(mb(stats.sizeInBytes))")
      try await db.close()
    }

    // all(): decode every document.
    do {
      let db = try openDB(dir)
      let collection = try await db.collection(
        "test", of: TestDocument.self, options: CollectionOptions(idField: "id"))
      let baseline = MemoryPeakSampler.currentFootprint()
      let sampler = MemoryPeakSampler()
      sampler.start()
      let start = CFAbsoluteTimeGetCurrent()
      let all = try await collection.all()
      let time = CFAbsoluteTimeGetCurrent() - start
      let peak = sampler.stop()
      print(
        String(
          format: "  all() — %d docs in %.2f s │ baseline %@ │ peak %@ (Δ +%@)",
          all.count, time, mb(baseline), mb(peak), mb(peak > baseline ? peak - baseline : 0)))
      try await db.close()
    }

    // Index rebuild: reopen with a new indexed field, forcing a full scan.
    do {
      let db = try openDB(dir)
      let baseline = MemoryPeakSampler.currentFootprint()
      let sampler = MemoryPeakSampler()
      sampler.start()
      let start = CFAbsoluteTimeGetCurrent()
      _ = try await db.collection(
        "test", of: TestDocument.self,
        options: CollectionOptions(idField: "id", indexedFields: ["name"]))
      let time = CFAbsoluteTimeGetCurrent() - start
      let peak = sampler.stop()
      print(
        String(
          format: "  index rebuild (new field) — %.2f s │ baseline %@ │ peak %@ (Δ +%@)",
          time, mb(baseline), mb(peak), mb(peak > baseline ? peak - baseline : 0)))
      try await db.close()
    }
    print("")
  }
}
