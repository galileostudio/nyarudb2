//
//  PersistenceLifecycleTest.swift
//  NyaruDB2
//
//  Created on 16/05/25.
//

import XCTest
@testable import NyaruDB2

// Simple test document
struct SimpleDocument: Codable, Equatable {
    let id: Int
    let name: String
}

/**
 This test demonstrates a significant bug in NyaruDB2's persistence mechanism.
 
 ISSUE DESCRIPTION:
 When reopening a database, NyaruDB2 does not automatically load existing shards from disk.
 This means that after closing and reopening a database, querying for documents returns
 empty results, even though the data still exists on disk.
 
 ROOT CAUSE:
 The issue is in StorageEngine.swift's `getOrCreateShardManager` method. When it creates
 a new ShardManager, it doesn't call `loadShards()` on it, which means the ShardManager
 doesn't load existing shards from disk.
 
 FIX RECOMMENDATION:
 The fix would be to modify the `getOrCreateShardManager` method in StorageEngine.swift
 to call `loadShards()` after creating a new ShardManager:
 
 ```swift
 private func getOrCreateShardManager(for collection: String) async throws -> ShardManager {
     if let existing = activeShardManagers[collection] {
         return existing
     }
     
     let collectionURL = baseURL.appendingPathComponent(collection, isDirectory: true)
     try FileManager.default.createDirectory(at: collectionURL, withIntermediateDirectories: true)
     
     let newManager = ShardManager(baseURL: collectionURL, compressionMethod: compressionMethod)
     newManager.loadShards()  // Add this line to fix the persistence issue
     activeShardManagers[collection] = newManager
     return newManager
 }
 ```
 */
final class PersistenceLifecycleTests: XCTestCase {
    // Temporary path for the database
    private var tempDBPath: String!
    
    override func setUp() async throws {
        // Create a unique temporary directory path for the test database
        tempDBPath = NSTemporaryDirectory().appending("nyarudb2_persistence_test_\(UUID().uuidString)")
        print("Database path: \(tempDBPath!)")
    }
    
    override func tearDown() async throws {
        // Clean up by removing the test database directory
        if let path = tempDBPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    
    // Helper function to list all files in a directory recursively
    private func listFiles(at path: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return []
        }
        
        var files: [String] = []
        while let file = enumerator.nextObject() as? String {
            files.append(file)
        }
        return files
    }
    
    // Print contents of a file for debugging
    private func printFileContents(at path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else {
            print("Could not read file at \(path)")
            return
        }
        print("File contents of \(path):")
        print(content)
    }
    
    /**
     This test verifies the persistence bug by:
     1. Creating a database and inserting a document
     2. Closing the database
     3. Examining the files on disk to confirm the data was saved
     4. Reopening the database and confirming that the document can't be fetched (bug)
     */
    func testPersistenceBug() async throws {
        // Simple test document
        let document = SimpleDocument(id: 1, name: "Test Document")
        let collectionName = "testCollection"
        
        // PART 1: Create and populate the database
        do {
            print("STEP 1: Creating database and inserting document")
            let db = try NyaruDB2(path: tempDBPath)
            
            // Create collection
            let collection = try await db.createCollection(
                name: collectionName,
                indexes: ["id"],
                partitionKey: "id"
            )
            
            // Insert document
            try await collection.insert(document)
            
            // Verify document was inserted
            let fetchedDocs: [SimpleDocument] = try await collection.fetch()
            XCTAssertEqual(fetchedDocs.count, 1, "Should have 1 document after insertion")
            print("✅ Document successfully inserted and retrieved")
            
            // Print that we're closing the first database instance
            print("💾 Closing first database instance")
        }
        
        // PART 2: Verify that files exist on disk
        do {
            print("\nSTEP 2: Verifying data was saved to disk")
            print("Files on disk after database closure:")
            let filesAfterClosure = listFiles(at: tempDBPath)
            filesAfterClosure.forEach { print("  \($0)") }
            
            // Print contents of any json files (that may contain the document)
            let jsonFiles = filesAfterClosure.filter { $0.hasSuffix(".json") }
            for file in jsonFiles {
                printFileContents(at: tempDBPath + "/" + file)
            }
            
            // Verify that files exist
            XCTAssertTrue(filesAfterClosure.count > 0, "Files should exist on disk after database is closed")
            XCTAssertTrue(filesAfterClosure.contains(collectionName), "Collection directory should exist on disk")
            print("✅ Files verified on disk")
        }
        
        // PART 3: Reopen the database and observe the bug
        do {
            print("\nSTEP 3: Reopening database (will demonstrate the bug)")
            // Create new database instance
            let db = try NyaruDB2(path: tempDBPath)
            
            // Verify the collection exists in the reopened database
            let collections = try await db.listCollections()
            XCTAssertTrue(collections.contains(collectionName), "Collection should exist after reopening")
            print("✅ Collection exists in reopened database")
            
            // Set the partition key as needed for proper operation
            await db.storage.setPartitionKey(for: collectionName, key: "id")
            
            // Try to fetch documents (this will fail due to the bug)
            let fetchedDocs: [SimpleDocument] = try await db.storage.fetchDocuments(from: collectionName)
            
            // Print results
            print("❌ BUG DEMONSTRATED: Documents found after reopening: \(fetchedDocs.count)")
            print("   Expected: 1, Actual: \(fetchedDocs.count)")
            
            // This assertion will fail due to the bug in ShardManager initialization
            XCTAssertEqual(fetchedDocs.count, 1, "BUG: Should find 1 document after reopening")
            
            print("""
            
            EXPLANATION OF THE BUG:
            ---------------------
            1. The document was successfully saved to disk (as we can see from the files)
            2. However, when reopening the database, NyaruDB2 doesn't load the existing shards
            3. This happens because StorageEngine.getOrCreateShardManager() doesn't call loadShards()
               when creating a new ShardManager instance
            4. The fix would be to modify that method to call loadShards() after creating the ShardManager
            
            """)
        }
    }
}

