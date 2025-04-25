//
//  ShardManagerTest.swift
//  NyaruDB2
//
//  Created by demetrius albuquerque on 13/04/25.
//

import XCTest

@testable import NyaruDB2

final class ShardManagerTests: XCTestCase {

    func testShardCreation() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShardManagerTest")
        // Limpa a pasta, se existir
        try? FileManager.default.removeItem(at: baseURL)
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )

        let manager = ShardManager(
            baseURL: baseURL,
            compressionMethod: .none,
            fileProtectionType: .none
        )
        let shard = try await manager.createShard(withID: "testShard")

        XCTAssertEqual(shard.id, "testShard", "O ID do shard deve corresponder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shard.url.path))
    }

    func testGetNonexistentShard() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShardManagerTest2")
        try? FileManager.default.removeItem(at: baseURL)
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )

        let manager = ShardManager(
            baseURL: baseURL,
            compressionMethod: .none,
            fileProtectionType: .none
        )
        XCTAssertThrowsError(try manager.getShard(byID: "inexistente")) {
            error in
            // Valide que o erro é do tipo correto, se desejar
        }
    }
}
