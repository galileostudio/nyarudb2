import Foundation

public actor StorageEngine {

    private let baseURL: URL
    private let compressionMethod: CompressionMethod
    private let fileProtectionType: FileProtectionType
    public var collectionPartitionKeys: [String: String] = [:]
    public var activeShardManagers = [String: ShardManager]()
    public var indexManagers: [String: IndexManager<String>] = [:]
    private lazy var statsEngine: StatsEngine = StatsEngine(storage: self)

    public enum StorageError: Error {
        case invalidDocument
        case partitionKeyNotFound(String)
        case indexKeyNotFound(String)
        case shardManagerCreationFailed
        case updateDocumentNotFound
    }

    public init(
        path: String,
        compressionMethod: CompressionMethod = .none,
        fileProtectionType: FileProtectionType = .none

    ) throws {
        self.baseURL = URL(fileURLWithPath: path, isDirectory: true)
        self.compressionMethod = compressionMethod
        self.fileProtectionType = fileProtectionType

        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
    }

    public func insertDocument<T: Codable>(
        _ document: T,
        collection: String,
        indexField: String? = nil
    ) async throws {
        let jsonData = try JSONEncoder().encode(document)

        // 1. Otimização: Decodificação parcial apenas para chaves necessárias
        let partitionField = collectionPartitionKeys[collection]
        let partitionValue: String =
            partitionField != nil
            ? try DynamicDecoder.extractValue(
                from: jsonData,
                key: partitionField!
            ) : "default"

        // 2. Gerenciamento eficiente de shards
        let shardManager = try await getOrCreateShardManager(for: collection)
        let shard = try await shardManager.getOrCreateShard(id: partitionValue)

        // 3. Operações de I/O assíncronas
        try await shard.appendDocument(document, jsonData: jsonData)

        if let indexField = indexField {
            let key = try DynamicDecoder.extractValue(
                from: jsonData,
                key: indexField,
                forIndex: true
            )
            let indexManager =
                indexManagers[collection] ?? IndexManager<String>()
            // Remove a criação do índice se ele já existe;
            // a criação deve acontecer uma única vez (por exemplo, na configuração inicial do datasource)
            await indexManager.createIndex(for: indexField)  // NÃO chamar se o índice já foi criado
            await indexManager.insert(
                index: indexField,
                key: key,
                data: jsonData
            )
            indexManagers[collection] = indexManager
        }

        try await self.statsEngine.updateCollectionMetadata(for: collection)

    }

    public func fetchDocuments<T: Codable>(from collection: String) async throws
        -> [T]
    {
        try await activeShardManagers[collection]?
            .allShards()
            .concurrentMap { try await $0.loadDocuments() }
            .flatMap { $0 } ?? []
    }

    public func fetchFromIndex<T: Codable>(
        collection: String,
        field: String,
        value: String
    ) async throws -> [T] {
        // Verifica se existe um indexManager para a coleção
        guard let indexManager = indexManagers[collection] else {
            return []
        }
        // Realiza a busca no índice
        let dataArray = await indexManager.search(field, value: value)
        // Decodifica cada item de Data para o tipo T
        return try dataArray.map { try JSONDecoder().decode(T.self, from: $0) }
    }

    public func fetchDocumentsLazy<T: Codable>(from collection: String)
        -> AsyncThrowingStream<T, Error>
    {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await activeShardManagers[collection]?
                        .allShards()
                        .asyncForEach { shard in
                            try await shard.loadDocuments()
                                .forEach { continuation.yield($0) }
                        }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func deleteDocuments<T: Codable>(
        where predicate: @escaping (T) -> Bool,
        from collection: String
    ) async throws {
        guard let shardManager = activeShardManagers[collection] else { return }

        try await shardManager.allShards()
            .asyncForEach { shard in
                let docs = try await shard.loadDocuments() as [T]
                let newDocs = docs.filter { !predicate($0) }
                if docs.count != newDocs.count {
                    try await shard.saveDocuments(newDocs)
                }
            }

        try await statsEngine.updateCollectionMetadata(for: collection)
    }

    public func updateDocument<T: Codable>(
        _ document: T,
        in collection: String,
        matching predicate: (T) -> Bool,
        indexField: String? = nil
    ) async throws {
        // 1. Codifica o documento atualizado
        let jsonData = try JSONEncoder().encode(document)

        // 2. Determina o shard onde o documento deve residir.
        // Se houver uma shardKey, extrai seu valor; caso contrário, usa "default".
        let shardManager = try await getOrCreateShardManager(for: collection)
        let shard: Shard
        if let partitionField = collectionPartitionKeys[collection] {
            let partitionValue: String = try DynamicDecoder.extractValue(
                from: jsonData,
                key: partitionField
            )
            shard = try await shardManager.getOrCreateShard(id: partitionValue)
        } else {
            shard = try await shardManager.getOrCreateShard(id: "default")
        }

        // 3. Carrega os documentos existentes no shard
        var documents: [T] = try await shard.loadDocuments()

        // 4. Procura pelo documento correspondente utilizando o predicado fornecido (ex.: por ID)
        guard let indexToUpdate = documents.firstIndex(where: predicate) else {
            throw StorageEngine.StorageError.updateDocumentNotFound
        }

        // 5. Atualiza o documento no array local
        documents[indexToUpdate] = document

        // 6. Salva os documentos atualizados de volta ao shard
        try await shard.saveDocuments(documents)

        // 7. Se um campo de índice for informado, atualiza a entrada no índice
        if let indexField = indexField {
            // Extrai o valor do campo de índice (usando forIndex=true)
            let key: String = try DynamicDecoder.extractValue(
                from: jsonData,
                key: indexField,
                forIndex: true
            )

            // Obtém ou cria o IndexManager para a coleção
            var indexManager: IndexManager<String>
            if let existing = indexManagers[collection] {
                indexManager = existing
            } else {
                indexManager = IndexManager<String>()
                await indexManager.createIndex(for: indexField)
                indexManagers[collection] = indexManager
            }

            // Atualiza a entrada no índice. A estratégia aplicada aqui é inserir a nova versão;
            // o método de insert deve estar preparado para acumular entradas quando a chave já existir.
            await indexManager.insert(
                index: indexField,
                key: key,
                data: jsonData
            )
        }
    }

    public func bulkInsertDocuments<T: Codable>(
        _ documents: [T],
        collection: String,
        indexField: String? = nil
    ) async throws {

        guard !documents.isEmpty else { return }

        let shardManager = try await getOrCreateShardManager(for: collection)

        if let indexField = indexField, indexManagers[collection] == nil {
            let newManager = IndexManager<String>()
            await newManager.createIndex(for: indexField)
            indexManagers[collection] = newManager
        }

        let groups: [String: [(document: T, jsonData: Data)]] =
            try documents.reduce(into: [:]) { result, document in
                let jsonData = try JSONEncoder().encode(document)
                // Consulta a chave de partição configurada para a coleção.
                let partitionField = collectionPartitionKeys[collection]
                let partitionValue =
                    partitionField != nil
                    ? try DynamicDecoder.extractValue(
                        from: jsonData,
                        key: partitionField!
                    )
                    : "default"

                result[partitionValue, default: []].append((document, jsonData))
            }

        if let indexField = indexField {
            try await documents.asyncForEach { document in
                let jsonData = try JSONEncoder().encode(document)
                let indexKey = try DynamicDecoder.extractValue(
                    from: jsonData,
                    key: indexField,
                    forIndex: true
                )
                let indexManager: IndexManager<String>
                if let existing = indexManagers[collection] {
                    indexManager = existing
                } else {
                    let newManager = IndexManager<String>()
                    await newManager.createIndex(for: indexField)
                    indexManagers[collection] = newManager
                    indexManager = newManager
                }
                await indexManager.insert(
                    index: indexField,
                    key: indexKey,
                    data: jsonData
                )
            }
        }

        try await groups.forEachAsync { (shardId, groupDocuments) in
            let shard = try await shardManager.getOrCreateShard(id: shardId)
            let existingDocs: [T] = try await shard.loadDocuments()
            let newDocs = groupDocuments.map { $0.document }
            let updatedDocs = existingDocs + newDocs
            try await shard.saveDocuments(updatedDocs)
        }

        try await self.statsEngine.updateCollectionMetadata(for: collection)
    }

    public func countDocuments(in collection: String) async throws -> Int {
        return activeShardManagers[collection]?.allShards()
            .map(\.metadata.documentCount)
            .reduce(0, +) ?? 0
    }

    public func dropCollection(_ collection: String) async throws {
        // Remove o diretório da coleção
        let collectionURL = baseURL.appendingPathComponent(
            collection,
            isDirectory: true
        )
        try FileManager.default.removeItem(at: collectionURL)

        // Remove a coleção dos gerenciadores ativos
        activeShardManagers.removeValue(forKey: collection)
        indexManagers.removeValue(forKey: collection)
    }

    public func listCollections() throws -> [String] {
        // Obtém todos os itens contidos no diretório base.
        let items = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        )

        // Filtra apenas os itens que são diretórios (que são nossas coleções)
        let collections = items.filter { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
            return isDirectory.boolValue
        }

        // Retorna os nomes dos diretórios
        return collections.map { $0.lastPathComponent }
    }

    // TODO: move to ShardManager
    public func getShardManagers(for collection: String) async throws -> [Shard]
    {
        guard let shardManager = activeShardManagers[collection] else {
            return []
        }
        return shardManager.allShards()
    }

    // TODO: move to ShardManager
    public func getShard(forPartition partition: String, in collection: String)
        async throws -> Shard?
    {
        let shards = try await getShardManagers(for: collection)
        return shards.first(where: { $0.id == partition })
    }

    // TODO: move to ShardManager
    private func getOrCreateShardManager(for collection: String) async throws
        -> ShardManager
    {
        if let existing = activeShardManagers[collection] {
            return existing
        }

        let collectionURL = baseURL.appendingPathComponent(
            collection,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: collectionURL,
            withIntermediateDirectories: true
        )

        let newManager = ShardManager(
            baseURL: collectionURL,
            compressionMethod: compressionMethod
        )
        activeShardManagers[collection] = newManager
        return newManager
    }

    // TODO: move to IndexManager
    private func updateIndex(
        collection: String,
        indexField: String,
        jsonData: Data
    ) async throws {
        let indexManager: IndexManager<String>
        if let existing = indexManagers[collection] {
            indexManager = existing
        } else {
            let newManager = IndexManager<String>()
            await newManager.createIndex(for: indexField)
            indexManagers[collection] = newManager
            indexManager = newManager
        }

        let key = try DynamicDecoder.extractValue(
            from: jsonData,
            key: indexField,
            forIndex: true
        )
        await indexManager.insert(index: indexField, key: key, data: jsonData)

    }

    public func bulkUpdateIndexes(
        collection: String,
        updates: [(indexField: String, indexKey: String, data: Data)]
    ) async {
        guard let indexManager = self.indexManagers[collection] else { return }
        await withTaskGroup(of: Void.self) { group in
            for update in updates {
                group.addTask {
                    await indexManager.insert(
                        index: update.indexField,
                        key: update.indexKey,
                        data: update.data
                    )
                }
            }
        }
    }

    public func setPartitionKey(for collection: String, key: String) {
        collectionPartitionKeys[collection] = key
    }

    public func collectionDirectory(for collection: String) async throws -> URL
    {
        let collectionURL = baseURL.appendingPathComponent(
            collection,
            isDirectory: true
        )
        return collectionURL
    }

    public func repartitionCollection<T: Codable>(
        collection: String,
        newPartitionKey: String,
        as type: T.Type
    ) async throws {
        
        let allDocs: [T] = try await fetchDocuments(from: collection)
        let shardManager = try await getOrCreateShardManager(for: collection)
        try shardManager.removeAllShards()
        setPartitionKey(for: collection, key: newPartitionKey)
        let groups = try allDocs.reduce(into: [String: [T]]()) {
            result,
            document in
            let jsonData = try JSONEncoder().encode(document)
            let partitionValue = try DynamicDecoder.extractValue(
                from: jsonData,
                key: newPartitionKey
            )
            result[partitionValue, default: []].append(document)
        }

        for (partitionValue, docsGroup) in groups {
            let shard = try await shardManager.getOrCreateShard(
                id: partitionValue
            )
            try await shard.saveDocuments(docsGroup)
        }
        try await statsEngine.updateCollectionMetadata(for: collection)
    }

    public func cleanupEmptyShards(for collection: String) async throws {
        let shardManager = try await getOrCreateShardManager(for: collection)
        try await shardManager.cleanupEmptyShards()
    }

}

extension Sequence {
    func asyncForEach(
        _ operation: (Element) async throws -> Void
    ) async rethrows {
        for element in self {
            try await operation(element)
        }
    }
    func concurrentMap<T>(_ transform: @escaping (Element) async throws -> T)
        async rethrows -> [T]
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            forEach { element in
                group.addTask { try await transform(element) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}

extension Dictionary {
    /// Executa de forma assíncrona a função passada para cada par chave/valor,
    /// aguardando a conclusão de cada iteração sequencialmente.
    func forEachAsync(_ body: (Key, Value) async throws -> Void) async rethrows
    {
        for (key, value) in self {
            try await body(key, value)
        }
    }
}
