#if canImport(Compression)
import Compression
#endif
import Foundation


/// An actor-based implementation of a B-Tree index for managing and organizing data.
/// 
/// `BTreeIndex` is a generic class that supports keys conforming to both `Comparable`
/// and `Codable` protocols. It provides thread-safe operations for indexing and 
/// retrieving data in a concurrent environment.
///
/// - Note: This implementation leverages Swift's `actor` model to ensure data 
///   consistency and thread safety.
///
/// - Parameters:
///   - Key: The type of the keys used in the B-Tree. Keys must conform to 
///     `Comparable` for ordering and `Codable` for serialization.
public actor BTreeIndex<Key: Comparable & Codable> {

    
    /// A private final class representing a node in the B-Tree structure.
    ///
    /// This class conforms to `Codable` for serialization and deserialization,
    /// and `@unchecked Sendable` to allow concurrent access, though thread-safety
    /// must be ensured externally.
    ///
    /// - Properties:
    ///   - keys: An array of keys stored in the node.
    ///   - values: A 2D array where each sub-array contains the data associated with a key.
    ///   - children: An array of child nodes, used for non-leaf nodes.
    ///   - isLeaf: A Boolean indicating whether the node is a leaf node (true) or an internal node (false).
    private final class Node: Codable, @unchecked Sendable {
        var keys: [Key] = []
        var values: [[Data]] = []
        var children: [Node] = []
        var isLeaf: Bool

        /// Initializes a new instance of the BTreeIndex with the specified leaf status.
        /// 
        /// - Parameter isLeaf: A Boolean value indicating whether the node is a leaf node.
        init(isLeaf: Bool) {
            self.isLeaf = isLeaf
        }

        /// An enumeration that defines the coding keys used for encoding and decoding
        /// the properties of a B-Tree index node. These keys correspond to the
        /// serialized representation of the node's data.
        ///
        /// - `keys`: Represents the keys stored in the node.
        /// - `values`: Represents the values associated with the keys in the node.
        /// - `children`: Represents the child nodes of the current node.
        /// - `isLeaf`: Indicates whether the node is a leaf node (i.e., it has no children).
        private enum CodingKeys: String, CodingKey {
            case keys, values, children, isLeaf
        }
    }

    private let t: Int
    private var root: Node

    private let serializationQueue = DispatchQueue(
        label: "com.nyarudb2.btree.serialization"
    )

    /// Initializes a new instance of the BTreeIndex with a specified minimum degree.
    ///
    /// - Parameter minimumDegree: The minimum degree of the B-tree. This determines the minimum number of children
    ///   each internal node must have. The default value is 2.
    public init(minimumDegree: Int = 2) {
        precondition(minimumDegree >= 2, "O grau mínimo deve ser pelo menos 2.")
        self.t = minimumDegree
        self.root = Node(isLeaf: true)
    }


    /// Searches for the specified key in the B-Tree index and returns the associated data.
    ///
    /// - Parameter key: The key to search for in the B-Tree index.
    /// - Returns: An optional array of `Data` associated with the given key. 
    ///            Returns `nil` if the key is not found.
    public func search(key: Key) -> [Data]? {
        return search(in: root, key: key)
    }

    /// Searches for the specified key within the given B-Tree node.
    ///
    /// - Parameters:
    ///   - node: The B-Tree node to search in.
    ///   - key: The key to search for.
    /// - Returns: An optional array of `Data` associated with the key if found, or `nil` if the key does not exist in the node.
    private func search(in node: Node, key: Key) -> [Data]? {
        var i = 0
        while i < node.keys.count && key > node.keys[i] {
            i += 1
        }
        if i < node.keys.count && key == node.keys[i] {
            return node.values[i]
        }
        if node.isLeaf {
            return nil
        } else {
            return search(in: node.children[i], key: key)
        }
    }

    /// Loads a persisted index from the provided data.
    ///
    /// This method asynchronously reads and reconstructs the index structure
    /// from the given binary data. It is used to restore the state of the
    /// index from a previously saved state.
    ///
    /// - Parameter data: The binary data containing the persisted index.
    /// - Throws: An error if the data cannot be parsed or the index cannot be
    ///           reconstructed.
    /// - Returns: This method does not return a value but updates the index
    ///            state internally.
    public func loadPersistedIndex(from data: Data) async throws {
        let decoder = JSONDecoder()
        let decodedRoot = try decoder.decode(Node.self, from: data)
        self.root = decodedRoot
    }

    /// Loads a persisted index from the specified file URL.
    ///
    /// This asynchronous method attempts to load the index data from the given
    /// file URL. If the operation fails, it throws an error.
    ///
    /// - Parameter url: The file URL pointing to the persisted index data.
    /// - Throws: An error if the index cannot be loaded from the specified URL.
    /// - Returns: This method does not return a value but completes asynchronously
    ///            once the index is successfully loaded or an error is thrown.
    public func loadPersistedIndex(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        try await loadPersistedIndex(from: data)
    }

    /// Inserts a key-value pair into the B-tree index.
    ///
    /// - Parameters:
    ///   - key: The key to be inserted into the index.
    ///   - data: The associated data to be stored with the key.
    public func insert(key: Key, data: Data) {
        if let existing = search(key: key), !existing.isEmpty {
            insertDataIfExists(in: root, key: key, data: data)
            return
        }
        if root.keys.count == (2 * t - 1) {
            let s = Node(isLeaf: false)
            s.children.append(root)
            splitChild(parent: s, index: 0, child: root)
            root = s
            insertNonFull(node: root, key: key, data: data)
        } else {
            insertNonFull(node: root, key: key, data: data)
        }
    }

    /// Inserts the provided data into the specified node if the key already exists.
    ///
    /// - Parameters:
    ///   - node: The `Node` in which the data should be inserted.
    ///   - key: The `Key` to check for existence in the node.
    ///   - data: The `Data` to insert if the key exists.
    private func insertDataIfExists(in node: Node, key: Key, data: Data) {
        var i = 0
        while i < node.keys.count && key > node.keys[i] {
            i += 1
        }
        if i < node.keys.count && key == node.keys[i] {
            node.values[i].append(data)
            return
        }
        if node.isLeaf {
            node.keys.insert(key, at: i)
            node.values.insert([data], at: i)
        } else {
            insertDataIfExists(in: node.children[i], key: key, data: data)
        }
    }

    /// Inserts a key and associated data into a non-full node of the B-tree.
    ///
    /// - Parameters:
    ///   - node: The node into which the key and data should be inserted. This node is assumed to not be full.
    ///   - key: The key to be inserted into the node.
    ///   - data: The data associated with the key to be inserted.
    private func insertNonFull(node: Node, key: Key, data: Data) {
        var i = node.keys.count - 1
        if node.isLeaf {
            while i >= 0 && key < node.keys[i] {
                i -= 1
            }
            let insertIndex = i + 1
            node.keys.insert(key, at: insertIndex)
            node.values.insert([data], at: insertIndex)
        } else {
            while i >= 0 && key < node.keys[i] {
                i -= 1
            }
            i += 1
            if node.children[i].keys.count == (2 * t - 1) {
                splitChild(parent: node, index: i, child: node.children[i])
                if key > node.keys[i] {
                    i += 1
                }
            }
            insertNonFull(node: node.children[i], key: key, data: data)
        }
    }

    /// Splits a child node of a B-tree into two nodes and adjusts the parent node accordingly.
    ///
    /// - Parameters:
    ///   - parent: The parent node that contains the child node to be split.
    ///   - index: The index of the child node in the parent's children array.
    ///   - child: The child node to be split into two nodes.
    private func splitChild(parent: Node, index: Int, child: Node) {
        let newNode = Node(isLeaf: child.isLeaf)
        newNode.keys = Array(child.keys[t...])
        newNode.values = Array(child.values[t...])
        if !child.isLeaf {
            newNode.children = Array(child.children[t...])
            child.children.removeSubrange(t..<child.children.count)
        }
        child.keys.removeSubrange(t..<child.keys.count)
        child.values.removeSubrange(t..<child.values.count)

        parent.children.insert(newNode, at: index + 1)
        // Seleciona a chave mediana para subir para o pai
        let medianKey = child.keys[t - 1]
        let medianValue = child.values[t - 1]
        parent.keys.insert(medianKey, at: index)
        parent.values.insert(medianValue, at: index)

        child.keys.remove(at: t - 1)
        child.values.remove(at: t - 1)
    }

    
    /// Performs an in-order traversal of the B-Tree index and returns an array of `Data` elements.
    ///
    /// - Returns: An array of `Data` elements in the order they appear during an in-order traversal.
    public func inOrder() -> [Data] {
        var result: [Data] = []
        inOrderTraversal(node: root, result: &result)
        return result
    }

    /// Performs an in-order traversal of the B-tree starting from the given node.
    ///
    /// - Parameters:
    ///   - node: The starting node for the traversal.
    ///   - result: An inout array of `Data` that will be populated with the traversal results in sorted order.
    private func inOrderTraversal(node: Node, result: inout [Data]) {
        if node.isLeaf {
            for valueGroup in node.values {
                result.append(contentsOf: valueGroup)
            }
        } else {
            for i in 0..<node.keys.count {
                inOrderTraversal(node: node.children[i], result: &result)
                result.append(contentsOf: node.values[i])
            }
            if let lastChild = node.children.last {
                inOrderTraversal(node: lastChild, result: &result)
            }
        }
    }

    /// Persists the current state of the B-tree index to the specified file URL.
    ///
    /// This method asynchronously writes the index data to the provided URL, ensuring
    /// that the index can be saved and restored later. It is useful for maintaining
    /// the state of the index across application launches or sessions.
    ///
    /// - Parameter url: The file URL where the index data should be persisted.
    /// - Throws: An error if the persistence operation fails.
    /// - Note: Ensure that the provided URL is writable and that there is sufficient
    ///   storage space available for the operation to complete successfully.
    public func persist(to url: URL) async throws {
        let currentRoot = self.root
        try await withCheckedThrowingContinuation { continuation in
            serializationQueue.async {
                do {
                    // Encode the tree (here we encode the root which is recursive)
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(currentRoot)

                    // Optionally, compress the data before writing.
                    let compressedData = try? compressData(data, method: .gzip)

                    // Write the data (compressed or not) to disk.
                    try (compressedData ?? data).write(
                        to: url,
                        options: .atomic
                    )

                    // Resume after successful persist.
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    
    /// Retrieves a subset of data from the B-tree index based on the specified offset and limit.
    ///
    /// - Parameters:
    ///   - offset: The starting position in the data set from which to begin retrieving items.
    ///   - limit: The maximum number of items to retrieve.
    /// - Returns: An array of `Data` objects representing the requested subset of the index.
    public func page(offset: Int, limit: Int) -> [Data] {
        let allData = inOrder()
        guard offset < allData.count else { return [] }
        let end = min(allData.count, offset + limit)
        return Array(allData[offset..<end])
    }

    public func getTotalCount() async -> Int {
        return inOrder().count
    }
}
