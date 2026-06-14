//
//  RegressionTier1Tests.swift
//  NyaruDB2
//
//  Testes de regressão para problemas de Tier-1 (correção / perda de dados).
//  Cada teste foi escrito para FALHAR no código anterior ao fix e PASSAR depois dele.
//

import XCTest
@testable import NyaruDB2

private struct Item: Codable, Equatable {
    let id: Int
    let group: String
    let name: String
}

final class RegressionTier1Tests: XCTestCase {
    private var dbPath: String!

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory()
            .appending("nyarudb2_tier1_\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
    }

    /// Lista apenas os arquivos de dados de shard (`*.nyaru`), ignorando os
    /// sidecars de metadado (`*.nyaru.meta.json`).
    private func shardFiles(in collection: String) -> [URL] {
        let dir = URL(fileURLWithPath: dbPath).appendingPathComponent(collection)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasSuffix(".nyaru") }
    }

    /// `countDocuments(in:)` precisa retornar o total correto depois que o banco
    /// é fechado e reaberto.
    ///
    /// Antes do fix isto retornava 0 porque (a) `countDocuments` nunca carregava o
    /// ShardManager a partir do disco e (b) o metadado por shard (`documentCount`)
    /// nunca era persistido, então os shards recarregados reportavam 0.
    func testDocumentCountSurvivesReopen() async throws {
        let name = "items"
        let items = [
            Item(id: 1, group: "A", name: "a1"),
            Item(id: 2, group: "A", name: "a2"),
            Item(id: 3, group: "B", name: "b1"),
            Item(id: 4, group: "B", name: "b2"),
            Item(id: 5, group: "B", name: "b3"),
        ]

        // Sessão 1: cria a coleção e insere.
        do {
            let db = try NyaruDB2(path: dbPath)
            let collection = try await db.createCollection(
                name: name, indexes: [], partitionKey: "group")
            try await collection.bulkInsert(items)
            let countSameSession = try await db.countDocuments(in: name)
            XCTAssertEqual(countSameSession, items.count,
                "Sanidade: a contagem deve estar correta na mesma sessão")
        }

        // Sessão 2: reabre e conta.
        do {
            let db = try NyaruDB2(path: dbPath)
            let countAfterReopen = try await db.countDocuments(in: name)
            XCTAssertEqual(countAfterReopen, items.count,
                "countDocuments deve sobreviver a um reopen (metadado de shard persistido)")
        }
    }

    /// Inserir em um shard cujo arquivo em disco está ilegível/corrompido precisa
    /// lançar erro — nunca sobrescrever silenciosamente os dados existentes com
    /// apenas o novo documento.
    ///
    /// Antes do fix, `appendDocument` usava `try?`, então uma leitura que falhava
    /// virava um array vazio e o save seguinte destruía os dados existentes sem
    /// propagar qualquer erro.
    func testInsertDoesNotDestroyShardOnCorruptRead() async throws {
        let name = "items"
        let first = Item(id: 1, group: "A", name: "original")

        // Sessão 1: insere um documento (compressão .none => JSON cru em disco).
        do {
            let db = try NyaruDB2(path: dbPath, compressionMethod: .none)
            let collection = try await db.createCollection(
                name: name, indexes: [], partitionKey: "group")
            try await collection.insert(first)
        }

        // Corrompe o arquivo de dados do shard em disco.
        let files = shardFiles(in: name)
        XCTAssertEqual(files.count, 1, "Esperava exatamente um arquivo de shard para corromper")
        let shardURL = try XCTUnwrap(files.first)
        try Data("isto nao e um json valido".utf8).write(to: shardURL, options: .atomic)

        // Sessão 2 (cache em memória novo): inserir no mesmo shard precisa lançar.
        let db = try NyaruDB2(path: dbPath, compressionMethod: .none)
        await db.storage.setPartitionKey(for: name, key: "group")
        let second = Item(id: 2, group: "A", name: "new")
        do {
            try await db.insert(second, into: name)
            XCTFail("Insert em um shard corrompido deveria lançar, mas teve sucesso — "
                + "os dados existentes foram sobrescritos silenciosamente (bug de perda de dados presente).")
        } catch {
            // Esperado: a leitura corrompida é propagada em vez de destruir os dados.
        }
    }
}
