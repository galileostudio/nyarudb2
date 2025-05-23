//
//  QueryEngineTest.swift
//  NyaruDB2
//
//  Created by demetrius albuquerque on 13/04/25.
//

import XCTest

@testable import NyaruDB2

// Modelo para os testes do QueryEngine
struct Users: Codable, Equatable {
    let id: Int
    let name: String
    let age: Int
}

final class QueryEngineTests: XCTestCase {

    var tempDirectory: URL!
    var storage: StorageEngine!
    var engine: NyaruDB2!

    override func setUp() async throws {
        // Cria um diretório temporário para isolar o teste
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        // Inicializa o StorageEngine sem particionamento para este teste
        storage = try StorageEngine(
            path: tempDirectory.path,
            compressionMethod: .none
        )

        engine = try NyaruDB2(
            path: tempDirectory.path,
            compressionMethod: .none
        )

        // Cria e insere alguns registros na coleção "Userss"
        let Userss: [Users] = [
            Users(id: 1, name: "Alice", age: 30),
            Users(id: 2, name: "Bob", age: 25),
            Users(id: 3, name: "Charlie", age: 35),
            Users(id: 4, name: "David", age: 40),
            Users(id: 5, name: "Alice", age: 45),
        ]

        for Users in Userss {
            try await storage.insertDocument(Users, collection: "Users")
        }
    }

    override func tearDown() async throws {
        // Remove o diretório temporário para limpar o ambiente de teste
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // Helper para coletar os itens de um AsyncThrowingStream em um array.
    private func collect<T>(stream: AsyncThrowingStream<T, Error>) async throws
        -> [T]
    {
        var results: [T] = []
        for try await item in stream {
            results.append(item)
        }
        return results
    }

    func testQueryEqualOperator() async throws {
        // Query: Filtra usuários cujo nome é "Alice"
        var query = Query<Users>(
            collection: "Users",
            storage: storage,
            indexStats: try await engine.getIndexStats(),
            shardStats: try await engine.getShardStats()
        )
        query.where(
            \Users.name,
            .equal("Alice" as String)
        )
        let results = try await collect(
            stream: query.fetchStream(from: storage)
        )

        // Espera dois registros (com ids 1 e 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.id == 1 }))
        XCTAssertTrue(results.contains(where: { $0.id == 5 }))
    }

    func testQueryGreaterThanOperator() async throws {
        // Query: Filtra usuários com idade maior que 30
        var query = Query<Users>(
            collection: "Users",
            storage: storage,
            indexStats: try await engine.getIndexStats(),
            shardStats: try await engine.getShardStats()
        )
        query.where(
            \Users.age,
            .greaterThan(30)
        )
        let results = try await collect(
            stream: query.fetchStream(from: storage)
        )

        // Espera 3 registros: Charlie (35), David (40), Alice (45)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.contains(where: { $0.id == 3 }))
        XCTAssertTrue(results.contains(where: { $0.id == 4 }))
        XCTAssertTrue(results.contains(where: { $0.id == 5 }))
    }

    func testQueryBetweenOperator() async throws {
        // Query: Filtra usuários com idade entre 30 e 40 inclusive

        var query = Query<Users>(
            collection: "Users",
            storage: storage,
            indexStats: try await engine.getIndexStats(),
            shardStats: try await engine.getShardStats()
        )
        query.where(
            \Users.age,
            .between(lower: 30, upper: 40)
        )
        let results = try await collect(
            stream: query.fetchStream(from: storage)
        )

        // Espera: Alice (30), Charlie (35) e David (40)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.contains(where: { $0.id == 1 }))
        XCTAssertTrue(results.contains(where: { $0.id == 3 }))
        XCTAssertTrue(results.contains(where: { $0.id == 4 }))
    }

    func testQueryStartsWithOperator() async throws {
        // Query: Filtra usuários cujo nome começa com "A"

        var query = Query<Users>(
            collection: "Users",
            storage: storage,
            indexStats: try await engine.getIndexStats(),
            shardStats: try await engine.getShardStats()
        )
        query.where(
            \Users.name,
            .startsWith("A")
        )
        let results = try await collect(
            stream: query.fetchStream(from: storage)
        )

        // Espera: Usuários "Alice" (ids 1 e 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.id == 1 }))
        XCTAssertTrue(results.contains(where: { $0.id == 5 }))
    }

    func testQueryContainsOperator() async throws {
        // Query: Filtra usuários cujo nome contenha a letra "v" (deve pegar "David")
        var query = Query<Users>(
            collection: "Users",
            storage: storage,
            indexStats: try await engine.getIndexStats(),
            shardStats: try await engine.getShardStats()
        )
        query.where(
            \Users.name,
            .contains("v")
        )
        let results = try await collect(
            stream: query.fetchStream(from: storage)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, 4)
    }

    func testFetchStreamFiltering() async throws {
        // Cria um diretório temporário para isolar o teste
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        // Inicializa o StorageEngine sem particionamento para simplificar
        let storage = try StorageEngine(
            path: tempDirectory.path,
            compressionMethod: .none,
            fileProtectionType: .none
        )

        // Insere alguns documentos
        let model1 = Users(id: 1, name: "Alice", age: 30)
        let model2 = Users(id: 2, name: "Bob", age: 25)
        let model3 = Users(id: 3, name: "Charlie", age: 30)
        try await storage.insertDocument(model1, collection: "Users")
        try await storage.insertDocument(model2, collection: "Users")
        try await storage.insertDocument(model3, collection: "Users")

        // Cria a query para filtrar onde a idade é igual a 30
        // var query = Query<Users>(collection: "Users")
        var query = Query<Users>(
            collection: "Users",
            storage: storage,
            indexStats: try await engine.getIndexStats(),
            shardStats: try await engine.getShardStats()
        )
        query.where(\Users.age, .equal(30 as Int))

        // Executa o fetchStream para recuperar os documentos que atendem ao predicado
        let stream = query.fetchStream(from: storage)
        var results: [Users] = []
        for try await person in stream {
            results.append(person)
        }

        // Espera-se que apenas os documentos com age == 30 sejam retornados (model1 e model3)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(model1))
        XCTAssertTrue(results.contains(model3))
    }
}
