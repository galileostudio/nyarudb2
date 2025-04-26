//
//  QuickStart.swift
//  NyaruDB2
//
//  Created by d.a.albuquerque on 15/04/25.
//

import Foundation
import NyaruDB2

// Define your model types.
struct User: Codable, Equatable {
    let id: Int
    let name: String
    let createdAt: String // Updated field naming for clarity and Swift conventions.
}

struct Location: Codable, Equatable {
    let id: Int
    let name: String
    let country: String
}


///  QuickStart guide for NyaruDB2.
///  
///  This guide demonstrates how to:
///  - Create a new database instance.
///  - Register collections with customized partition and index configurations.
///  - Perform basic CRUD operations using the NyaruCollection interface (formerly known as NDBCollection).
///  
///  The documentation provides a comprehensive walk-through of setting up and interacting with the database, ensuring that developers can quickly integrate and utilize NyaruDB2 in their projects.

func runQuickStart() async {
    do {
        // 1. Initialize the database.
        // Data is persisted in a folder named "NyaruDB_Quickstart".
        let db = try NyaruDB2(
            path: "NyaruDB_QuickStart",
            compressionMethod: .none,     // You can change this to .gzip, .lzfse, etc.
            fileProtectionType: .none,
            storageFormat: .messagePack   // Adjust file protection as needed.
        )
        print("Database initialized successfully.")

        // 2. Create a collection for Users.
        // We now use the NyaruCollection class (formerly NDBCollection) for collection-level operations.
        // The partition key for Users is "createdAt". This ensures that documents are stored into shards based on their creation date.
        let usersCollection = try await db.createCollection(name: "Users", indexes: ["id"], partitionKey: "createdAt")
        
        // 3. Insert a single User document.
        let user1 = User(id: 1, name: "Alice", createdAt: "2022-05-01")
        try await usersCollection.insert(user1)
        print("Inserted user: \(user1)")

        // 4. Bulk insert multiple User documents.
        let bulkUsers = [
            User(id: 2, name: "Bob", createdAt: "2023-05-01"),
            User(id: 3, name: "Charlie", createdAt: "2022-05-01"),
            User(id: 4, name: "David", createdAt: "2024-05-01")
        ]
        try await usersCollection.bulkInsert(bulkUsers)
        print("Bulk inserted users: \(bulkUsers)")

        // 5. Create a collection for Locations.
        // In this example, assume that partitioning is not necessary or uses a different key.
        let locationsCollection = try await db.createCollection(name: "Locations", indexes: ["id"], partitionKey: "country")
        let bulkLocations = [
            Location(id: 2, name: "Bob", country: "USA"),
            Location(id: 3, name: "Charlie", country: "Canada"),
            Location(id: 4, name: "David", country: "USA")
        ]
        try await locationsCollection.bulkInsert(bulkLocations)
        print("Bulk inserted locations: \(bulkLocations)")

        // 6. Query the Users collection.
        // Global query: find the user with id == 1 by scanning all shards.
        var query = try await usersCollection.query() as Query<User>
        query.where(\User.id, .equal(1))
        let queryResults = try await query.execute()
        print("Query result for user with id = 1: \(queryResults)")

        // 7. Update a document.
        // Update user1's name from "Alice" to "Alicia".
        let updatedUser1 = User(id: 1, name: "Alicia", createdAt: "2022-05-01")
        try await usersCollection.update(updatedUser1, matching: { $0.id == 1 })
        print("Updated user1 to: \(updatedUser1)")

        // 8. Delete a document.
        // Delete the user with id == 2.
        try await usersCollection.delete { (user: User) -> Bool in
            return user.id == 2
        }
        print("Deleted user with id = 2.")

        // 9. Fetch all Users.
        let allUsers: [User] = try await usersCollection.fetch()
        print("All users in 'Users' collection after updates and deletion: \(allUsers)")
        
    } catch {
        print("Error running NyaruDB2 QuickStart: \(error)")
    }
}

@main
struct QuickStartRunner {
    static func main() async {
        await runQuickStart()
        exit(0)
    }
}
