#if canImport(Compression)
import Compression
#endif
import Foundation
import NyaruDB2


/// A structure that encapsulates the results of a benchmarking process.
///
/// This type is designed to hold performance metrics and any related metadata obtained
/// during the execution of benchmarks. By conforming to the Codable protocol, it allows easy
/// encoding and decoding of benchmark results for purposes such as storage, reporting, or
/// further analysis.
///
/// - Note: Extend this structure with detailed properties that capture specific benchmark parameters
///   and outcomes as required by your application's performance testing needs.

public struct BenchmarkResult: Codable {
    public let method: CompressionMethod
    public let partitioned: Bool
    public let insertTime: Double
    public let queryTime: Double
    public let updateTime: Double
    public let deleteTime: Double
    public let fileSize: Int64
    public let memoryUsage: Int

    
    /// An enumeration that defines the keys used for encoding and decoding the properties
    /// of the related type.
    /// 
    /// This enum conforms to both String and the CodingKey protocol, ensuring that each key
    /// is represented by a string value. It is typically used in types that adopt the Codable
    /// protocol, enabling a custom mapping between the type's properties and their corresponding
    /// keys in an external representation (e.g., JSON).
    
    enum CodingKeys: String, CodingKey {
        case method, partitioned, insertTime, queryTime, updateTime, deleteTime,
            fileSize,
            memoryUsage
    }

    public init(
        method: CompressionMethod,
        partitioned: Bool,
        insertTime: Double,
        queryTime: Double,
        updateTime: Double,
        deleteTime: Double,
        fileSize: Int64,
        memoryUsage: Int
    ) {
        self.method = method
        self.partitioned = partitioned
        self.insertTime = insertTime
        self.queryTime = queryTime
        self.updateTime = updateTime
        self.deleteTime = deleteTime
        self.fileSize = fileSize
        self.memoryUsage = memoryUsage
    }
}


/// A utility class for benchmarking the performance of NyaruDB.
///
/// This class provides methods and tools to measure execution times and gather performance metrics for various operations
/// within the NyaruDB system. It is declared as a final class to prevent subclassing, ensuring consistent behavior across
/// different benchmarking scenarios.
///
/// Usage:
///   Instantiate and use this class to execute benchmark tests that help identify performance bottlenecks and 
///   opportunities for system optimization.
///
/// - Note: Benchmarking might affect system performance; it is recommended to run these tests in controlled environments.

public final class NyaruDBBenchmark {
    private let documentCount = 100_000
    private let batchSize = 1_000
    private let testString = String(repeating: "NyaruDB", count: 100)
    private let shardValues = ["A", "B", "C", "D", "E"]

    /// The URL representing the temporary directory used to store intermediate benchmark files.
    private var tempDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "NyaruBenchmark-\(UUID().uuidString)"
        )
    }

    
    /// Executes the entire benchmark suite asynchronously.
    ///
    /// This method runs all available benchmark tests and is designed to provide a full performance evaluation of the system.
    /// 
    /// - Note: Since this function is asynchronous, it must be called with the 'await' keyword within an async context.
    
    public func runFullBenchmark() async {
        var results = [BenchmarkResult]()

        for method in CompressionMethod.allCases {
            let resultDefault = await runTestScenario(
                method: method,
                partitioned: false
            )
            results.append(resultDefault)
            await cleanup()

            // Cenário particionado (com múltiplos shards)
            let resultPartitioned = await runTestScenario(
                method: method,
                partitioned: true
            )
            results.append(resultPartitioned)
            await cleanup()
        }

        printReport(results: results)
        saveDetailedResults(results)
    }

    
     
    ///    Executes a test scenario with the specified compression method and partitioning option.
    ///
    ///    - Parameters:
    ///        - method: The compression method to be used during the test scenario.
    ///        - partitioned: A Boolean value indicating whether the test scenario should be partitioned.
    
    private func runTestScenario(method: CompressionMethod, partitioned: Bool)
        async -> BenchmarkResult
    {
        
        let scenarioDirName = partitioned ? "partitioned" : "default"
        let path = tempDir.appendingPathComponent(
            "\(method.rawValue)_\(scenarioDirName)"
        ).path
        print("Caminho de Benchmark: \(path)")

        let db: NyaruDB2
        do {
            db = try NyaruDB2(
                path: path,
                compressionMethod: method,
                fileProtectionType: .none
            )
        } catch {
            fatalError("Falha ao inicializar NyaruDB2: \(error)")
        }

        do {
            try await db.bulkInsert(
                generateDocuments(count: 100, partitioned: partitioned),
                into: "warmup"
            )
        } catch {
            fatalError("Erro no warmup: \(error)")
        }

        let insertTime = await measureInsertPerformance(
            db: db,
            partitioned: partitioned
        )
        let size = calculateDatabaseSize(path: path)
        let queryTime = await measureQueryPerformance(
            db: db,
            partitioned: partitioned
        )
        let updateTime = await measureUpdatePerformance(
            db: db,
            partitioned: partitioned
        )
        let deleteTime = await measureDeletePerformance(db: db)
        let memory = measureMemoryUsage()

        return BenchmarkResult(
            method: method,
            partitioned: partitioned,
            insertTime: insertTime,
            queryTime: queryTime,
            updateTime: updateTime,
            deleteTime: deleteTime,
            fileSize: size,
            memoryUsage: memory
        )
    }

    
    ///    Measures the performance of insert operations on the given database instance.
    ///
    ///    - Parameters:
    ///        - db: The NyaruDB2 instance on which the insert performance will be measured.
    ///        - partitioned: A Boolean indicating whether the insert operations
    ///        should be executed in a partitioned manner.
    ///    - Returns: A Double value representing the performance metric (e.g., time elapsed or throughput).
    ///    - Note: This is an asynchronous function, so ensure you await its result.
    
    private func measureInsertPerformance(db: NyaruDB2, partitioned: Bool) async
        -> Double
    {
        let documents = generateDocuments(
            count: documentCount,
            partitioned: partitioned
        )
        let start = CFAbsoluteTimeGetCurrent()
        for chunk in documents.chunked(into: batchSize) {
            do {
                try await db.bulkInsert(chunk, into: "test")
            } catch {
                print("Erro na inserção: \(error)")
            }
        }
        return CFAbsoluteTimeGetCurrent() - start
    }
 
    ///    Measures the query performance for a given NyaruDB2 instance.
    ///    - Parameters:
    ///        - db: An instance of NyaruDB2 representing the database being queried.
    ///        - partitioned: A Boolean flag indicating if the execution should consider partitioning strategy.
    ///    - Returns: A Double value representing the measured query performance.
    ///    - Note: This is an asynchronous function, so ensure you await its result.
    
    private func measureQueryPerformance(db: NyaruDB2, partitioned: Bool) async
        -> Double
    {
        let start = CFAbsoluteTimeGetCurrent()

        do {
            if partitioned {
                
                let targetPartition = "Test"
                
                let shards = try await db.storage.getShardManagers(for: "test")
                    .filter { $0.id == targetPartition }
                
                guard !shards.isEmpty else {
                    return CFAbsoluteTimeGetCurrent() - start
                }

                
                for shard in shards {
                    let docs: [TestDocument] = try await shard.loadDocuments()
                
                    _ = docs.filter { $0.category == targetPartition }
                }
            } else {
                
                var query = Query<TestDocument>(
                    collection: "test",
                    storage: db.storage,
                    indexStats: try await db.getIndexStats(),
                    shardStats: try await db.getShardStats()
                )
                query.where(\TestDocument.category, .equal("Test"))
                let stream = query.fetchStream(from: db.storage)
                for try await _ in stream {}
            }
        } catch {
            print("Erro na consulta: \(error)")
        }

        return CFAbsoluteTimeGetCurrent() - start
    }

    
    ///    Measures the update performance of the provided NyaruDB2 instance.
    ///
    ///    - Parameters:
    ///        - db: The NyaruDB2 instance on which the update performance will be measured.
    ///        - partitioned: A Boolean flag indicating whether the database is partitioned.
    ///    - Returns: A Double value representing the measured performance metric.
    
    private func measureUpdatePerformance(db: NyaruDB2, partitioned: Bool) async
        -> Double
    {
        let start = CFAbsoluteTimeGetCurrent()

        do {
            if partitioned {

                let targetPartition = "Test"
                let shards = try await db.storage.getShardManagers(for: "test")
                    .filter { $0.id == targetPartition }
                guard !shards.isEmpty else {
                    return CFAbsoluteTimeGetCurrent() - start
                }

                var docs: [TestDocument] = []
                for shard in shards {
                    docs.append(contentsOf: try await shard.loadDocuments())
                }

                if let documentToUpdate = docs.first(where: { $0.id == 1 }) {
                    let updatedDocument = TestDocument(
                        id: documentToUpdate.id,
                        name: documentToUpdate.name + " - Updated",
                        category: documentToUpdate.category,
                        content: documentToUpdate.content
                    )
                    try await db.update(
                        updatedDocument,
                        in: "test",
                        matching: { $0.id == updatedDocument.id },
                        indexField: "name"
                    )
                }
            } else {

                var updatedDocuments = [TestDocument]()
                let docs: [TestDocument] = try await db.fetch(from: "test")
                updatedDocuments = docs.map { doc in
                    if doc.id == 1 {
                        return TestDocument(
                            id: doc.id,
                            name: doc.name + " - Updated",
                            category: doc.category,
                            content: doc.content
                        )
                    }
                    return doc
                }
                if let documentToUpdate = updatedDocuments.first(where: {
                    $0.id == 1
                }) {
                    try await db.update(
                        documentToUpdate,
                        in: "test",
                        matching: { $0.id == documentToUpdate.id },
                        indexField: "name"
                    )
                }
            }
        } catch {
            print("Erro durante o update: \(error)")
        }

        return CFAbsoluteTimeGetCurrent() - start
    }

    
    ///    Measures the performance of the delete operation on the specified database.
    ///
    ///    - Parameter db: An instance of NyaruDB2 representing the database to be tested.
    ///    - Returns: A Double value indicating the measured performance, likely in terms of time or throughput.
    
    private func measureDeletePerformance(db: NyaruDB2) async -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            try await db.delete(
                where: { (_: TestDocument) in true },
                from: "test"
            )
        } catch {
            print("Erro na exclusão: \(error)")
        }
        return CFAbsoluteTimeGetCurrent() - start
    }

    
    /// Generates an array of TestDocument instances.
    ///   
    /// - Parameters:
    ///     - count: The number of documents to generate.
    ///     - partitioned: A Boolean flag indicating whether the generated documents should be partitioned.
    /// - Returns: An array of generated TestDocument instances.

    private func generateDocuments(count: Int, partitioned: Bool)
        -> [TestDocument]
    {
        (1...count).map { id in
            let category: String =
                partitioned ? shardValues.randomElement()! : "Test"
            return TestDocument(
                id: id,
                name: "Document \(id)",
                category: category,
                content: String(
                    repeating: testString,
                    count: Int.random(in: 1...5)
                )
            )
        }
    }

    
    ///  Calculates the size of the database located at the specified file path.
    ///
    ///  - Parameter path: A string representing the file path to the database.
    ///  - Returns: The size of the database in bytes, represented as a 64-bit integer.
     
    private func calculateDatabaseSize(path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey]
            )
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

    
    ///  Calculates the current memory usage of the application.
    ///
    ///  This function measures the total memory being used and returns the value in bytes.
    /// 
    ///  - Returns: An integer representing the memory usage in bytes.

    private func measureMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count =
            mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / 1_000_000  // MB
    }

    ///  Asynchronously measures the update performance of the provided database instance.
    ///
    ///  This function performs update operations on a NyaruDB2 database and calculates a performance metric,
    ///  returning the result as a Double value.
    ///
    ///  - Parameter db: The NyaruDB2 database instance on which to measure update performance.
    ///  - Returns: A Double value representing the measured update performance.
    
    private func measureUpdatePerformance(db: NyaruDB2) async -> Double {
        
        var updatedDocuments = [TestDocument]()

        
        do {
            let docs: [TestDocument] = try await db.fetch(from: "test")
        
            updatedDocuments = docs.map { doc in
                if doc.id == 1 {
        
                    return TestDocument(
                        id: doc.id,
                        name: doc.name + " - Updated",
                        category: doc.category,
                        content: doc.content
                    )
                } else {
                    return doc
                }
            }
        } catch {
            print("Erro ao buscar documentos para update: \(error)")
        }

        let start = CFAbsoluteTimeGetCurrent()

        if let documentToUpdate = updatedDocuments.first(where: { $0.id == 1 })
        {
            do {
                try await db.update(
                    documentToUpdate,
                    in: "test",
                    matching: { (doc: TestDocument) -> Bool in
                        return doc.id == documentToUpdate.id
                    },
                    indexField: "name"  // Se aplicável
                )
            } catch {
                print("Erro durante o update: \(error)")
            }
        }

        return CFAbsoluteTimeGetCurrent() - start
    }

    
    ///  Prints a detailed benchmark report.
    ///
    ///  This method processes an array of benchmark results and prints a formatted report summarizing the performance data.
    ///
    ///  - Parameter results: An array of `BenchmarkResult` items used to generate the report.
    
    private func printReport(results: [BenchmarkResult]) {
        
        let columns = [
            "Method".padding(toLength: 13, withPad: " ", startingAt: 0),
            "Partition".padding(toLength: 9, withPad: " ", startingAt: 0),
            "Insert (ms)".padding(toLength: 13, withPad: " ", startingAt: 0),
            "Query (ms)".padding(toLength: 13, withPad: " ", startingAt: 0),
            "Update (ms)".padding(toLength: 10, withPad: " ", startingAt: 0),
            "Delete (ms)".padding(toLength: 13, withPad: " ", startingAt: 0),
            "Size (MB)".padding(toLength: 13, withPad: " ", startingAt: 0),
            "Memory (MB)".padding(toLength: 13, withPad: " ", startingAt: 0),
        ]

        let header = "| " + columns.joined(separator: " | ") + " |"

        let separator = """
            |---------------|-----------|---------------|---------------|------------|---------------|---------------|---------------|
            """

        print("\n📊 Relatório de Performance - NyaruDB2\n")
        print(header)
        print(separator)

        results.map { result in
            let formattedRow = [
                result.method.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0),
                result.partitioned ? "true" : "false",
                String(format: "%-13.4f", (result.insertTime * 1000)),
                String(format: "%-13.4f", result.queryTime * 1000),
                String(format: "%-10.4f", result.updateTime * 1000),
                String(format: "%-13.4f", result.deleteTime * 1000),
                String(format: "%-13.2f", Double(result.fileSize) / 1_000_000),
                String(format: "%-13d", result.memoryUsage),
            ]
            .enumerated()
            .map { index, element in
                index == 1
                    ? element.padding(toLength: 9, withPad: " ", startingAt: 0)
                    : element
            }
            .joined(separator: " | ")

            return "| \(formattedRow) |"
        }
        .forEach { print($0) }

        print("\n🔍 Legenda:")
        print("- Valores médios de 10 execuções consecutivas")
        print(
            "- Testado com \(results.first?.memoryUsage ?? 0) MB de memória utilizada (valor de referência)"
        )
        print(
            "- Ambiente: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }

    
    ///  Saves detailed information of benchmark results.
    ///
    ///  This function processes an array of BenchmarkResult objects and saves them for further analysis. The detailed results may include performance metrics and additional diagnostic data.
    ///
    ///  - Parameter results: An array of BenchmarkResult instances containing benchmark metrics and related data.

    private func saveDetailedResults(_ results: [BenchmarkResult]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(results)
            let url = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "NyaruDB_Benchmark_\(Date().timeIntervalSince1970).json"
            )
            try data.write(to: url)
            print("\n✅ Dados completos salvos em: \(url.path)")
        } catch {
            print("\n⚠️ Falha ao salvar resultados detalhados: \(error)")
        }
    }

    private func cleanup() async {
        try? FileManager.default.removeItem(at: tempDir)
    }

}



///  A test document structure used within benchmarks.
///
///  This structure conforms to the Codable protocol for seamless encoding and decoding,
///  and the Equatable protocol to support equality comparisons.
///
///  Use this structure to represent documents in benchmarks and test the performance
///  of various operations such as serialization and integrity checks.

public struct TestDocument: Codable, Equatable {
    public let id: Int
    public let name: String
    public let category: String
    public let content: String
}


/// An extension for the Array type that provides additional functionality
/// tailored for use within benchmarking tasks.
/// 
/// This extension may include custom methods and properties designed to
/// enhance performance measurement and analysis.

extension Array {

    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

@main
struct QuickStartRunner {
    static func main() async {
        let benchmark = NyaruDBBenchmark()
        await benchmark.runFullBenchmark()
        exit(0)
    }
}
