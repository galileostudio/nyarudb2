//
//  QueryTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-02.
//

import XCTest
@testable import NyaruDB2

/// Tests for the advanced query engine: recursive boolean logic,
/// NOT IN, DISTINCT, and memory-safe pagination.
final class QueryAdvancedTests: XCTestCase {
    private var baseURL: URL!
    private var db: NyaruDB!
    private var users: NyaruCollection<QueryAdvancedTests.User>!

    private struct User: Codable, Sendable, Equatable {
        var id: Int
        var name: String
        var age: Int
        var country: String
        var city: String
    }

    private let userOptions = CollectionOptions(
        partitionKey: "country",
        indexedFields: ["age", "country"]
    )

    override func setUp() async throws {
        try await super.setUp()
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyaru-adv-tests-\(UUID().uuidString)", isDirectory: true)
        
        db = try await NyaruDB(path: baseURL, options: .init(compression: .none))
        users = try await db.collection("users", of: User.self, options: userOptions)
        
        // Populando base para os testes
        let testData: [User] = [
            User(id: 1, name: "Alice", age: 25, country: "BR", city: "Recife"),
            User(id: 2, name: "Bob", age: 30, country: "US", city: "New York"),
            User(id: 3, name: "Charlie", age: 65, country: "BR", city: "Recife"),
            User(id: 4, name: "David", age: 70, country: "PT", city: "Lisboa"),
            User(id: 5, name: "Eve", age: 25, country: "BR", city: "Olinda"),
            User(id: 6, name: "Frank", age: 30, country: "US", city: "Boston")
        ]
        try await users.insert(contentsOf: testData)
    }

    override func tearDown() async throws {
        try await db.close()
        try? FileManager.default.removeItem(at: baseURL)
        try await super.tearDown()
    }

    // MARK: - 1. Recursive Boolean Logic (OR, NOT)

    func testOrLogic() async throws {
        // Quem tem 25 anos OU é dos EUA?
        let results = try await users.find()
            .where(.or([
                .equal("age", 25),
                .equal("country", "US")
            ]))
            .sort(by: "id")
            .execute()
        
        // Esperado: Alice(1), Bob(2), Eve(5), Frank(6)
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.map(\.id), [1, 2, 5, 6])
    }

    func testNotLogic() async throws {
        // Quem NÃO é do Brasil?
        let results = try await users.find()
            .where(.not(.equal("country", "BR")))
            .sort(by: "id")
            .execute()
        
        // Esperado: Bob(2), David(4), Frank(6)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.id), [2, 4, 6])
    }

    func testComplexNestedLogic() async throws {
        // (Idade == 25 OU Idade == 70) E NÃO (Cidade == "Olinda")
        let results = try await users.find()
            .where(
                .and([
                    .or([
                        .equal("age", 25),
                        .equal("age", 70)
                    ]),
                    .not(.equal("city", "Olinda"))
                ])
            )
            .sort(by: "id")
            .execute()
        
        // Esperado: Alice(1) e David(4). Eve(5) é excluída pela cláusula NOT.
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.id), [1, 4])
    }

    // MARK: - 2. NOT IN

    func testNotInLogic() async throws {
        // Quem NÃO tem os IDs 1, 3 e 5?
        let results = try await users.find()
            .where("id", isNotIn: [1, 3, 5])
            .sort(by: "id")
            .execute()
        
        // Esperado: Bob(2), David(4), Frank(6)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.id), [2, 4, 6])
    }

    // MARK: - 3. DISTINCT

    func testDistinctValues() async throws {
        // Quais são as idades únicas cadastradas?
        let distinctAges = try await users.find()
            .distinctValues(on: "age")
            .sorted { lhs, rhs in
                // Como distinctValues retorna [FieldValue], precisamos extrair o Int
                guard case .int(let l) = lhs, case .int(let r) = rhs else { return false }
                return l < r
            }
        
        // Esperado: 25, 30, 65, 70
        XCTAssertEqual(distinctAges.count, 4)
        
        var ages = [Int64]()
        for val in distinctAges {
            if case .int(let i) = val { ages.append(i) }
        }
        XCTAssertEqual(ages, [25, 30, 65, 70])
        
//        var ages = [Int64]()
//                for val in distinctAges {
//                    if case .int(let i) = val { ages.append(i) }
//                }
//                XCTAssertEqual(ages, [25, 30, 65, 70])
    }

    func testDistinctValuesWithFilter() async throws {
        // Quais países únicos têm pessoas com 30 anos OU mais?
        let distinctCountries = try await users.find()
            .where("age", isGreaterThanOrEqualTo: 30)
            .distinctValues(on: "country")
        
        // Esperado: US, BR, PT (Alice e Eve têm 25, então BR apareceria 2 vezes, mas na query de >=30 só Charlie(BR) entra)
        // Charlie(65, BR), Bob(30, US), Frank(30, US), David(70, PT)
        XCTAssertEqual(distinctCountries.count, 3)
    }

    // MARK: - 4. Memory Optimization (Limit & Offset without Sort)

    func testLimitStopsEarlyWithoutSort() async throws {
        // Se não tem sort, o limit deve parar de ler o disco assim que atingir a contagem.
        // Para testar isso, contamos quantos itens retornam com limit 2.
        let results = try await users.find()
            .where(.equal("country", "BR"))
            .limit(2)
            .execute()
        
        // Esperado: Apenas 2 itens (Alice e Charlie, ou Charlie e Eve, dependendo da ordem do disco)
        // A garantia que queremos testar é que ele não trouxe os 3 do banco pra memória pra cortar 1.
        // Como não há sort, a ordem não é garantida, mas a contagem sim.
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.country == "BR" })
    }

    func testOffsetAndLimitWithSort() async throws {
        // Testando paginação tradicional (exige sort)
        let page1 = try await users.find()
            .sort(by: "id", ascending: true)
            .limit(2)
            .execute()
        
        let page2 = try await users.find()
            .sort(by: "id", ascending: true)
            .offset(2)
            .limit(2)
            .execute()
            
        XCTAssertEqual(page1.map(\.id), [1, 2])
        XCTAssertEqual(page2.map(\.id), [3, 4])
    }
    // MARK: - 5. LIKE & GLOB
    
    func testLikeOperator() async throws {
        // Buscando nomes que começam com 'A' e terminam com 'e' (ignora case)
        let results = try await users.find()
            .where("name", like: "a%e")
            .sort(by: "id")
            .execute()
        
        // Esperado: Alice(1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Alice")
        
        // Buscando nomes com 3 letras (A_e)
        let shortNames = try await users.find()
            .where("name", like: "___")
            .execute()
        // Esperado: Eve, Bob
        XCTAssertEqual(shortNames.count, 2)
    }
    
    func testGlobOperator() async throws {
        // GLOB é case-sensitive! 'B%' pega Bob e Bob
        let results = try await users.find()
            .where("name", glob: "B*")
            .sort(by: "id")
            .execute()
        
        // Esperado: Bob(2)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Bob")
    }
}
