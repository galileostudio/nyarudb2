import Crypto
import Foundation
import NyaruDB2
import SQLite3

#if canImport(Compression)
  import Compression
#endif

// MARK: - ANSI Colors

struct ANSI {
  static let reset = "\u{001B}[0m"
  static let bold = "\u{001B}[1m"
  static let dim = "\u{001B}[2m"

  struct FG {
    static let black = "\u{001B}[30m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let white = "\u{001B}[37m"
    static let gray = "\u{001B}[90m"
    static let dim = "\u{001B}[2m"
  }
}

// MARK: - Progress Bar

struct ProgressBar {
  private let total: Int
  private let width: Int
  private var current: Int = 0
  private let startTime = Date()
  private var lastUpdate = Date()
  private var estimatedRemaining: TimeInterval = 0

  init(total: Int, width: Int = 40) {
    self.total = total
    self.width = width
  }

  mutating func update(current: Int, label: String = "") {
    self.current = min(current, total)
    let progress = Double(self.current) / Double(total)
    let filled = Int(Double(width) * progress)
    let empty = width - filled

    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
    let percent = Int(progress * 100)

    let now = Date()
    let elapsed = now.timeIntervalSince(startTime)

    if now.timeIntervalSince(lastUpdate) > 1.0 && self.current > 0 {
      let rate = Double(self.current) / elapsed
      let remaining = Double(total - self.current) / rate
      estimatedRemaining = remaining
      lastUpdate = now
    }

    let etaString = estimatedRemaining > 0 ? formatTime(estimatedRemaining) : "..."

    print(
      "\r\(ANSI.FG.cyan)\(bar)\(ANSI.reset) \(String(format: "%3d%%", percent)) | \(self.current)/\(total) | ⏱ \(formatTime(elapsed)) | ⏳ \(etaString) \(label)\(String(repeating: " ", count: max(0, 20 - label.count)))",
      terminator: ""
    )
    fflush(stdout)
  }

  func finish(label: String = "✅ Done!") {
    print(
      "\r\(ANSI.FG.green)\(String(repeating: "█", count: width))\(ANSI.reset) 100% | \(total)/\(total) | \(label)\(String(repeating: " ", count: 20))"
    )
    fflush(stdout)
  }

  private func formatTime(_ interval: TimeInterval) -> String {
    let totalSeconds = Int(interval)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%dh %02dm", hours, minutes)
    } else if minutes > 0 {
      return String(format: "%dm %02ds", minutes, seconds)
    } else {
      return String(format: "%ds", seconds)
    }
  }
}

// MARK: - Benchmark Result

public struct BenchmarkResult: Codable {
  public let method: String
  public let format: String
  public let encrypted: Bool
  public let partitioned: Bool
  public let insertManyTime: Double
  public let insertBatchTime: Double
  public let insertTransactionTime: Double
  public let queryTime: Double
  public let updateTime: Double
  public let patchTime: Double
  public let deleteTime: Double
  public let compactTime: Double
  public let fileSize: Int64
  public let shardCount: Int
  public let fragmentationRatio: Double
  public let memoryUsage: Int
}

// MARK: - Test Document

public struct TestDocument: Codable, Equatable, Sendable {
  public let id: Int
  public let name: String
  public let category: String
  public let content: String

  public init(id: Int, name: String, category: String, content: String) {
    self.id = id
    self.name = name
    self.category = category
    self.content = content
  }
}

// MARK: - Array Extension

extension Array {
  func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}

// MARK: - NyaruDB Benchmark Runner

public final class NyaruDBBenchmark {
  private let documentCount: Int
  private let batchSize: Int
  private let encryption: Bool
  private let partitioning: Bool
  private let warmupCount = 100
  private let testString = String(repeating: "NyaruDB", count: 50)
  private let shardValues = ["A", "B", "C", "D", "E"]

  private var tempDir: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "NyaruBenchmark-\(UUID().uuidString)"
    )
  }

  public init(
    documentCount: Int = 50_000, batchSize: Int = 1_000, encryption: Bool = false,
    partitioning: Bool = false
  ) {
    self.documentCount = documentCount
    self.batchSize = batchSize
    self.encryption = encryption
    self.partitioning = partitioning
  }

  public func runFullBenchmark(
    enabledCompression: [String] = CompressionMethod.allCases.map { $0.rawValue },
    enabledFormats: [String] = SerializationFormat.allCases.map { $0.rawValue },
    encryption: Bool = false,
    partitioning: Bool = false
  ) async -> [BenchmarkResult] {
    print("\n\(ANSI.bold)\(ANSI.FG.cyan)🚀 NyaruDB2 Benchmark Suite\(ANSI.reset)\n")

    let methods = enabledCompression.compactMap { CompressionMethod(rawValue: $0) }
    let formats = enabledFormats.compactMap { SerializationFormat(rawValue: $0) }

    let allScenarios = methods.flatMap { m in formats.map { (method: m, format: $0) } }
    var results = [BenchmarkResult]()
    var progress = ProgressBar(total: allScenarios.count)

    for (index, scenario) in allScenarios.enumerated() {
      let label = "\(scenario.method.rawValue)/\(scenario.format.rawValue)"
      progress.update(current: index, label: label)

      let result = await runTestScenario(
        method: scenario.method,
        format: scenario.format,
        encrypted: encryption,
        partitioned: partitioning
      )
      results.append(result)
      await cleanup()
    }

    progress.finish(label: "✅ NyaruDB2 scenarios completed!")
    return results
  }

  private func runTestScenario(
    method: CompressionMethod,
    format: SerializationFormat,
    encrypted: Bool,
    partitioned: Bool
  ) async -> BenchmarkResult {
    let scenarioName =
      "\(method.rawValue)_\(format.rawValue)\(encrypted ? "_enc" : "")\(partitioned ? "_part" : "")"
    let path = tempDir.appendingPathComponent(scenarioName).path

    let encryptionKey: SymmetricKey? = encrypted ? NyaruCrypto.generateRandomKey() : nil

    let db: NyaruDB
    do {
      db = try await NyaruDB(
        path: path,
        options: DatabaseOptions(
          compression: method,
          fileProtection: .none,
          format: format,
          encryptionKey: encryptionKey,
          maxFragmentation: 0.2
        )
      )
    } catch {
      fatalError("\(ANSI.FG.red)Failed to initialize NyaruDB: \(error)\(ANSI.reset)")
    }

    let collOpts = CollectionOptions(
      idField: "id",
      partitionKey: partitioned ? "category" : nil,
      indexedFields: ["category", "name", "id"]
    )

    // Warmup: populates OS page cache and warms up the engine
    await gracefulDrop(db: db)
    do {
      let warmupCol = try await db.collection("test", of: TestDocument.self, options: collOpts)
      let warmupDocs = generateDocuments(
        count: warmupCount, partitioned: partitioned, startingID: 0, fixedContent: true)
      try await warmupCol.insert(contentsOf: warmupDocs)
      _ = try await warmupCol.find().where("id", isGreaterThan: 0).limit(10).execute()
      await gracefulDrop(db: db)
    } catch {
      print("\(ANSI.FG.dim)Warmup skipped: \(error)\(ANSI.reset)")
    }

    // 1. InsertMany
    let insertManyTime = await measureInsertManyPerformance(
      db: db, options: collOpts, partitioned: partitioned)

    // 2. InsertBatch
    let insertBatchTime = await measureInsertBatchPerformance(
      db: db, options: collOpts, partitioned: partitioned)

    // 3. InsertTransaction (chunked inserts inside a single withTransaction)
    let insertTransactionTime = await measureInsertTransactionPerformance(
      db: db, options: collOpts, partitioned: partitioned)

    let collection: NyaruCollection<TestDocument>
    do {
      collection = try await db.collection("test", of: TestDocument.self, options: collOpts)
    } catch {
      fatalError(
        "\(ANSI.FG.red)Failed to create collection for measurements: \(error)\(ANSI.reset)")
    }

    let size = calculateDatabaseSize(path: path)
    let stats = await collection.stats()
    let shardCount = stats.shardCount
    let fragmentationRatio = stats.fragmentationRatio

    try? await db.sync()

    // 3. Queries
    let queryTime = await measureQueryPerformance(collection: collection, partitioned: partitioned)

    // 4. Updates
    let updateTime = await measureUpdatePerformance(collection: collection)

    // 5. Patches
    let patchTime = await measurePatchPerformance(collection: collection)

    // 6. Deletes
    let deleteTime = await measureDeletePerformance(collection: collection)

    // 7. Compaction
    let compactTime = await measureCompactionPerformance(
      collection: collection, documentCount: documentCount)

    let memory = measureMemoryUsage()

    try? await db.close()

    return BenchmarkResult(
      method: method.rawValue,
      format: format.rawValue,
      encrypted: encrypted,
      partitioned: partitioned,
      insertManyTime: insertManyTime,
      insertBatchTime: insertBatchTime,
      insertTransactionTime: insertTransactionTime,
      queryTime: queryTime,
      updateTime: updateTime,
      patchTime: patchTime,
      deleteTime: deleteTime,
      compactTime: compactTime,
      fileSize: size,
      shardCount: shardCount,
      fragmentationRatio: fragmentationRatio,
      memoryUsage: memory
    )
  }

  // MARK: - Performance Measurements

  private func measureInsertManyPerformance(
    db: NyaruDB, options: CollectionOptions, partitioned: Bool
  ) async -> Double {
    do {
      await gracefulDrop(db: db)
      let collection = try await db.collection("test", of: TestDocument.self, options: options)
      let documents = generateDocuments(
        count: documentCount, partitioned: partitioned, startingID: 1)
      let start = CFAbsoluteTimeGetCurrent()
      try await collection.insert(contentsOf: documents)
      return CFAbsoluteTimeGetCurrent() - start
    } catch {
      print("\n\(ANSI.FG.red)InsertMany error: \(error)\(ANSI.reset)")
      return 0
    }
  }

  private func measureInsertBatchPerformance(
    db: NyaruDB, options: CollectionOptions, partitioned: Bool
  ) async -> Double {
    do {
      await gracefulDrop(db: db)
      let collection = try await db.collection("test", of: TestDocument.self, options: options)
      let documents = generateDocuments(
        count: documentCount, partitioned: partitioned, startingID: 1)

      let start = CFAbsoluteTimeGetCurrent()
      for chunk in documents.chunked(into: batchSize) {
        try await collection.insert(contentsOf: chunk)
      }
      return CFAbsoluteTimeGetCurrent() - start
    } catch {
      print("\n\(ANSI.FG.red)InsertBatch error: \(error)\(ANSI.reset)")
      return 0
    }
  }

  private func measureInsertTransactionPerformance(
    db: NyaruDB, options: CollectionOptions, partitioned: Bool
  ) async -> Double {
    do {
      await gracefulDrop(db: db)
      let collection = try await db.collection("test", of: TestDocument.self, options: options)
      let documents = generateDocuments(
        count: documentCount, partitioned: partitioned, startingID: 1)
      let start = CFAbsoluteTimeGetCurrent()
      try await collection.withTransaction { tx in
        for chunk in documents.chunked(into: batchSize) {
          tx.insert(contentsOf: chunk)
        }
      }
      return CFAbsoluteTimeGetCurrent() - start
    } catch {
      print("\n\(ANSI.FG.red)InsertTransaction error: \(error)\(ANSI.reset)")
      return 0
    }
  }

  private func measureQueryPerformance(
    collection: NyaruCollection<TestDocument>,
    partitioned: Bool
  ) async -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    do {
      for _ in 0..<5 {
        if partitioned {
          _ = try await collection.find()
            .where("category", isEqualTo: "Test")
            .where("id", isGreaterThan: 100)
            .sort(by: "name", ascending: true)
            .limit(100)
            .execute()
        } else {
          _ = try await collection.find()
            .where("id", isGreaterThan: 100)
            .limit(100)
            .execute()
          _ = try await collection.find()
            .where("name", isEqualTo: "Document 42")
            .execute()
          _ = try await collection.find()
            .where("id", isBetween: 1000, and: 2000)
            .sort(by: "name")
            .execute()
        }
      }
    } catch {
      print("\n\(ANSI.FG.red)Query error: \(error)\(ANSI.reset)")
    }
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureUpdatePerformance(
    collection: NyaruCollection<TestDocument>
  ) async -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    do {
      for id in 1...100 {
        guard let doc = try await collection.get(id: id) else { continue }
        let updated = TestDocument(
          id: doc.id,
          name: doc.name + " - Updated",
          category: doc.category,
          content: doc.content + " (modified)"
        )
        try await collection.update(updated)
      }
    } catch {
      print("\n\(ANSI.FG.red)Update error: \(error)\(ANSI.reset)")
    }
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measurePatchPerformance(
    collection: NyaruCollection<TestDocument>
  ) async -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    do {
      for id in 1...100 {
        guard (try await collection.get(id: id)) != nil else { continue }
        let changes: [String: FieldValue] = [
          "name": .string("Patched Document \(id)"),
          "category": .string("Patched"),
        ]
        try await collection.patch(id: id, changes: changes)
      }
    } catch {
      print("\n\(ANSI.FG.red)Patch error: \(error)\(ANSI.reset)")
    }
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureDeletePerformance(
    collection: NyaruCollection<TestDocument>
  ) async -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    do {
      _ = try await collection.find()
        .where("id", isGreaterThan: documentCount - 1000)
        .delete()
    } catch {
      print("\n\(ANSI.FG.red)Delete error: \(error)\(ANSI.reset)")
    }
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureCompactionPerformance(
    collection: NyaruCollection<TestDocument>, documentCount: Int
  ) async -> Double {
    do {
      let extraDocs = generateDocuments(
        count: 20_000, partitioned: partitioning, startingID: documentCount + 1)
      try await collection.insert(contentsOf: extraDocs)
      _ = try await collection.find().where("id", isGreaterThan: documentCount).delete()
    } catch {
      print("\n\(ANSI.FG.red)Compaction setup error: \(error)\(ANSI.reset)")
      return 0.0
    }

    let start = CFAbsoluteTimeGetCurrent()
    do {
      try await collection.compact()
    } catch {
      print("\n\(ANSI.FG.red)Compaction error: \(error)\(ANSI.reset)")
    }
    return CFAbsoluteTimeGetCurrent() - start
  }

  // MARK: - Helpers

  private func generateDocuments(
    count: Int, partitioned: Bool, startingID: Int = 1, fixedContent: Bool = false
  ) -> [TestDocument] {
    let contentCount = fixedContent ? 3 : 3  // deterministic: always 3 repetitions
    return (startingID..<(startingID + count)).map { id in
      let category: String = partitioned
        ? shardValues[Int(id - startingID) % shardValues.count] : "Test"
      return TestDocument(
        id: id,
        name: "Document \(id)",
        category: category,
        content: String(repeating: testString, count: contentCount)
      )
    }
  }

  private func calculateDatabaseSize(path: String) -> Int64 {
    let url = URL(fileURLWithPath: path)
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey])
    else {
      return 0
    }
    return enumerator.reduce(0) { size, element in
      guard let fileURL = element as? URL else { return size }
      do {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        return size + Int64(values.fileSize ?? 0)
      } catch {
        return size
      }
    }
  }

  private func measureMemoryUsage() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)

    let kerr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard kerr == KERN_SUCCESS else { return 0 }
    return Int(info.resident_size) / 1_000_000
  }

  /// Drops a collection if it exists; silently continues if it doesn't.
  private func gracefulDrop(db: NyaruDB) async {
    do {
      try await db.drop("test")
    } catch let e as NyaruError {
      if case .collectionNotFound = e { return }
      print("\(ANSI.FG.yellow)Warning: drop failed: \(e)\(ANSI.reset)")
    } catch {
      print("\(ANSI.FG.yellow)Warning: drop failed: \(error)\(ANSI.reset)")
    }
  }

  private func cleanup() async {
    try? FileManager.default.removeItem(at: tempDir)
  }
}

// MARK: - SQLite Benchmark Runner

public final class SQLiteBenchmark {
  private let documentCount: Int
  private let batchSize: Int
  private let testString = String(repeating: "NyaruDB", count: 50)
  private var db: OpaquePointer?
  private var dbPath: String = ""

  init(documentCount: Int, batchSize: Int) {
    self.documentCount = documentCount
    self.batchSize = batchSize
  }

  func runTestScenario() -> BenchmarkResult {
    print("\n\(ANSI.bold)\(ANSI.FG.yellow)📦 Running SQLite3 Benchmark...\(ANSI.reset)")

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SQLiteBenchmark-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbPath = tempDir.appendingPathComponent("sqlite_test.db").path

    if sqlite3_open(dbPath, &db) != SQLITE_OK {
      fatalError("Failed to open SQLite DB")
    }

    // Configure SQLite with FULL sync = same durability guarantee as NyaruDB
    execute("PRAGMA journal_mode=WAL;")
    execute("PRAGMA synchronous=FULL;")

    // Setup table and indexes (mimicking NyaruDB2 indexedFields)
    execute("DROP TABLE IF EXISTS test;")
    execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, category TEXT, content TEXT);")
    execute("CREATE INDEX idx_category ON test(category);")
    execute("CREATE INDEX idx_name ON test(name);")

    // 1. InsertMany
    let insertManyTime = measureInsertMany()

    // 2. InsertBatch
    let insertBatchTime = measureInsertBatch()

    // 3. Query
    let queryTime = measureQuery()

    // 4. Update
    let updateTime = measureUpdate()

    // 5. Patch
    let patchTime = measurePatch()

    // 6. Delete
    let deleteTime = measureDelete()

    // 7. Compact (VACUUM)
    let compactTime = measureCompact()

    let size = calculateDatabaseSize()
    let memory = measureMemoryUsage()

    sqlite3_close(db)
    try? FileManager.default.removeItem(at: tempDir)

    return BenchmarkResult(
      method: "sqlite", format: "sqlite3", encrypted: false, partitioned: false,
      insertManyTime: insertManyTime, insertBatchTime: insertBatchTime,
      insertTransactionTime: 0,
      queryTime: queryTime, updateTime: updateTime, patchTime: patchTime, deleteTime: deleteTime,
      compactTime: compactTime,
      fileSize: size, shardCount: 1, fragmentationRatio: 0.0, memoryUsage: memory
    )
  }

  private func execute(_ sql: String) {
    var err: UnsafeMutablePointer<Int8>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
      if let err = err { print("SQLite error: \(String(cString: err))") }
    }
  }

  private func generateDocuments(count: Int, startingID: Int = 1) -> [TestDocument] {
    (startingID..<(startingID + count)).map { id in
      TestDocument(
        id: id, name: "Document \(id)", category: "Test",
        content: String(repeating: testString, count: Int.random(in: 1...5))
      )
    }
  }

  private func measureInsertMany() -> Double {
    execute("DELETE FROM test;")
    let docs = generateDocuments(count: documentCount, startingID: 1)
    let start = CFAbsoluteTimeGetCurrent()

    execute("BEGIN TRANSACTION;")
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(
      db, "INSERT INTO test (id, name, category, content) VALUES (?, ?, ?, ?);", -1, &stmt, nil)
      == SQLITE_OK
    {
      for doc in docs {
        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(doc.id))
        sqlite3_bind_text(stmt, 2, doc.name, -1, nil)
        sqlite3_bind_text(stmt, 3, doc.category, -1, nil)
        sqlite3_bind_text(stmt, 4, doc.content, -1, nil)
        sqlite3_step(stmt)
      }
      sqlite3_finalize(stmt)
    }
    execute("COMMIT;")

    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureInsertBatch() -> Double {
    execute("DELETE FROM test;")
    let docs = generateDocuments(count: documentCount, startingID: 1)
    let start = CFAbsoluteTimeGetCurrent()

    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(
      db, "INSERT INTO test (id, name, category, content) VALUES (?, ?, ?, ?);", -1, &stmt, nil)
      == SQLITE_OK
    {
      for chunk in docs.chunked(into: batchSize) {
        execute("BEGIN TRANSACTION;")
        for doc in chunk {
          sqlite3_reset(stmt)
          sqlite3_bind_int64(stmt, 1, Int64(doc.id))
          sqlite3_bind_text(stmt, 2, doc.name, -1, nil)
          sqlite3_bind_text(stmt, 3, doc.category, -1, nil)
          sqlite3_bind_text(stmt, 4, doc.content, -1, nil)
          sqlite3_step(stmt)
        }
        execute("COMMIT;")
      }
      sqlite3_finalize(stmt)
    }

    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureQuery() -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT * FROM test WHERE id > 100 LIMIT 100;", -1, &stmt, nil)
      == SQLITE_OK
    {
      while sqlite3_step(stmt) == SQLITE_ROW {}
      sqlite3_finalize(stmt)
    }
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureUpdate() -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    execute(
      "UPDATE test SET name = name || ' - Updated', content = content || ' (modified)' WHERE id = 1;"
    )
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measurePatch() -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    execute("UPDATE test SET name = 'Patched Document', category = 'Patched' WHERE id = 2;")
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureDelete() -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    execute("DELETE FROM test WHERE id > \(documentCount - 1000);")
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func measureCompact() -> Double {
    // Insert and delete 20k to mimic the same disk garbage scenario
    let extraDocs = generateDocuments(count: 20_000, startingID: documentCount + 1)
    execute("BEGIN TRANSACTION;")
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(
      db, "INSERT INTO test (id, name, category, content) VALUES (?, ?, ?, ?);", -1, &stmt, nil)
      == SQLITE_OK
    {
      for doc in extraDocs {
        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(doc.id))
        sqlite3_bind_text(stmt, 2, doc.name, -1, nil)
        sqlite3_bind_text(stmt, 3, doc.category, -1, nil)
        sqlite3_bind_text(stmt, 4, doc.content, -1, nil)
        sqlite3_step(stmt)
      }
      sqlite3_finalize(stmt)
    }
    execute("COMMIT;")
    execute("DELETE FROM test WHERE id > \(documentCount);")

    // Measure VACUUM (equivalent to compact)
    let start = CFAbsoluteTimeGetCurrent()
    execute("VACUUM;")
    return CFAbsoluteTimeGetCurrent() - start
  }

  private func calculateDatabaseSize() -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath)
    return Int64((attrs?[.size] as? UInt64) ?? 0)
  }

  private func measureMemoryUsage() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard kerr == KERN_SUCCESS else { return 0 }
    return Int(info.resident_size) / 1_000_000
  }
}

// MARK: - Reporting

func printReport(results: [BenchmarkResult], documentCount: Int, batchSize: Int, partitioned: Bool)
{
  let headers = [
    ("Method", 8), ("Format", 8), ("Enc", 4), ("Part", 5),
    ("InsertMany (50k)", 17), ("InsertBatch (50k)", 17), ("InsertTx (50k)", 15),
    ("Query (5x)", 13), ("Update (100)", 13), ("Patch (100)", 13), ("Delete (1k)", 13),
    ("Compact (20k)", 13), ("Size (MB)", 10), ("Shards", 6), ("Frag (%)", 8), ("Memory (MB)", 12),
  ]

  let headerLine = headers.map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }
    .joined(separator: " │ ")
  let separatorLine = headers.map { String(repeating: "─", count: $0.1) }.joined(separator: "─┼─")
  let topLine =
    "┌" + headers.map { String(repeating: "─", count: $0.1) }.joined(separator: "─┬─") + "┐"
  let bottomLine =
    "└" + headers.map { String(repeating: "─", count: $0.1) }.joined(separator: "─┴─") + "┘"

  print("\n" + ANSI.FG.cyan + topLine + ANSI.reset)
  print(
    ANSI.FG.cyan + "│ " + ANSI.bold + headerLine + ANSI.reset + ANSI.FG.cyan + " │" + ANSI.reset)
  print(ANSI.FG.cyan + "├" + separatorLine + "┤" + ANSI.reset)

  let sortedResults = results.sorted { ($0.method, $0.format) < ($1.method, $1.format) }

  for result in sortedResults {
    let insertTxDisplay =
      result.insertTransactionTime > 0
      ? String(format: "%15.2f", result.insertTransactionTime * 1000) : "            N/A"
    let row = [
      result.method.padding(toLength: 8, withPad: " ", startingAt: 0),
      result.format.padding(toLength: 8, withPad: " ", startingAt: 0),
      result.encrypted ? "✅" : "❌",
      result.partitioned ? "✅" : "❌",
      String(format: "%17.2f", result.insertManyTime * 1000),
      String(format: "%17.2f", result.insertBatchTime * 1000),
      insertTxDisplay,
      String(format: "%13.2f", result.queryTime * 1000),
      String(format: "%13.2f", result.updateTime * 1000),
      String(format: "%13.2f", result.patchTime * 1000),
      String(format: "%13.2f", result.deleteTime * 1000),
      String(format: "%13.2f", result.compactTime * 1000),
      String(format: "%10.2f", Double(result.fileSize) / 1_000_000),
      String(format: "%6d", result.shardCount),
      String(format: "%8.1f", result.fragmentationRatio * 100),
      String(format: "%12d", result.memoryUsage),
    ].joined(separator: " │ ")
    print(ANSI.FG.cyan + "│ " + ANSI.reset + row + ANSI.FG.cyan + " │" + ANSI.reset)
  }

  print(ANSI.FG.cyan + bottomLine + ANSI.reset)
}

// MARK: - Entry Point

@main
struct BenchmarkRunner {
  static func main() async {
    setbuf(stdout, nil)

    print("\n🚀 NyaruDB2 vs SQLite Benchmark\n")

    var documentCount = 50_000
    var batchSize = 1_000
    var quick = false
    var encryption = false
    var partitioning = false
    var compression: String? = nil
    var format: String? = nil

    let args = CommandLine.arguments.dropFirst()
    var i = args.startIndex
    while i < args.endIndex {
      let arg = args[i]
      switch arg {
      case "--quick", "-q": quick = true
      case "--encryption", "-e": encryption = true
      case "--partitioning", "-p": partitioning = true
      case "--document-count", "-d":
        if i + 1 < args.endIndex {
          documentCount = Int(args[i + 1]) ?? documentCount
          i += 1
        }
      case "--batch-size", "-b":
        if i + 1 < args.endIndex {
          batchSize = Int(args[i + 1]) ?? batchSize
          i += 1
        }
      case "--compression", "-c":
        if i + 1 < args.endIndex {
          compression = args[i + 1]
          i += 1
        }
      case "--format", "-f":
        if i + 1 < args.endIndex {
          format = args[i + 1]
          i += 1
        }
      case "--help", "-h":
        print(
          """
          Usage: NyaruDB2Benchmark [options]

          Options:
            -q, --quick              Run only one quick scenario
            -e, --encryption         Enable encryption
            -p, --partitioning       Enable partitioning
            -d, --document-count N   Number of documents (default: 50000)
            -b, --batch-size N       Batch size (default: 1000)
            -c, --compression M      Compression: none, gzip, lzfse, lz4
            -f, --format F           Format: json, msgpack
            -h, --help               Show this help
          """)
        Foundation.exit(0)
      default: break
      }
      i += 1
    }

    print("📄 Documents: \(documentCount)")
    print("📦 Batch size: \(batchSize)")
    print("🔒 Encryption: \(encryption ? "ON" : "OFF")")
    print("🗂️  Partitioning: \(partitioning ? "ON" : "OFF")")
    print("⚡ Quick mode: \(quick ? "YES" : "NO")")
    if let c = compression { print("📦 Compression: \(c)") }
    if let f = format { print("📄 Format: \(f)") }
    print("")

    var allResults = [BenchmarkResult]()

    let nyaruBenchmark = NyaruDBBenchmark(
      documentCount: documentCount, batchSize: batchSize, encryption: encryption,
      partitioning: partitioning)

    if quick {
      allResults.append(
        contentsOf: await nyaruBenchmark.runFullBenchmark(
          enabledCompression: ["gzip"], enabledFormats: ["msgpack"], encryption: encryption,
          partitioning: partitioning))
    } else {
      let enabledCompression =
        compression.map { [$0] } ?? CompressionMethod.allCases.map { $0.rawValue }
      let enabledFormats = format.map { [$0] } ?? SerializationFormat.allCases.map { $0.rawValue }

      allResults.append(
        contentsOf: await nyaruBenchmark.runFullBenchmark(
          enabledCompression: enabledCompression,
          enabledFormats: enabledFormats,
          encryption: encryption,
          partitioning: partitioning))
    }

    // Run SQLite Benchmark
    let sqliteBenchmark = SQLiteBenchmark(documentCount: documentCount, batchSize: batchSize)
    allResults.append(sqliteBenchmark.runTestScenario())

    // Print Combined Report
    print("\n\n\(ANSI.bold)📊 Combined Results Summary (NyaruDB2 vs SQLite)\(ANSI.reset)\n")
    print(
      "\(ANSI.FG.gray)Note: SQLite VACUUM rewrites the entire file (heavier than NyaruDB compact).\(ANSI.reset)"
    )
    print(
      "\(ANSI.FG.gray)Both use FULL sync durability. Query/Update/Patch times are totals for N operations.\(ANSI.reset)\n"
    )
    printReport(
      results: allResults, documentCount: documentCount, batchSize: batchSize,
      partitioned: partitioning)

    Foundation.exit(0)
  }
}
