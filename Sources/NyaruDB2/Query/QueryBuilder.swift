import Foundation

/// Describes the strategy that `QueryBuilder` will use to execute a query.
///
/// The strategy is determined by `explain()` based on the availability of
/// indexes and partition key predicates. The query planner selects the most
/// efficient access path automatically.
public enum QueryStrategy: Sendable, Equatable, CustomStringConvertible {
  /// Use a sorted index on the given field for point or range lookups.
  /// This is the most efficient strategy when a matching index exists.
  case indexLookup(field: String)
  /// Restrict the scan to a single partition shard based on the partition
  /// key value. Avoids scanning other shards entirely.
  case partitionScan(value: String)
  /// Scan every shard in the collection. Used when no index or partition
  /// pruning is applicable. All predicates are evaluated in memory.
  case fullScan

  /// A human-readable description of the strategy.
  public var description: String {
    switch self {
    case .indexLookup(let field): return "index lookup on '\(field)'"
    case .partitionScan(let value): return "partition scan of '\(value)'"
    case .fullScan: return "full scan"
    }
  }
}

/// The query execution plan produced by `QueryBuilder.explain()`.
///
/// A query plan describes the chosen access path and how many predicates
/// can be pushed down to the index versus evaluated in memory.
public struct QueryPlan: Sendable {
  /// The chosen access path (index, partition scan, or full scan).
  public let strategy: QueryStrategy
  /// The number of predicates that must still be evaluated in memory after
  /// the initial scan. Fewer residual predicates means faster execution.
  public let residualPredicates: Int
}

/// A thread-safe wrapper around `NSRegularExpression` that makes regex
/// instances compatible with `Sendable` requirements.
public struct SafeRegex: @unchecked Sendable {
  /// The compiled regular expression, or `nil` if the pattern could not
  /// be compiled (e.g. invalid syntax).
  public let regex: NSRegularExpression?
}

// MARK: - Predicate Tree

/// A recursive predicate tree that represents complex boolean logic for
/// filtering documents.
///
/// Predicates can be combined with `.and`, `.or`, and `.not` to build
/// arbitrary boolean expressions. Leaf predicates compare a document field
/// against a value using operators such as equals, less-than, range,
/// substring, and regex.
///
/// The predicate tree is evaluated bottom-up by `QueryBuilder.evaluate(_:in:)`,
/// which walks the tree recursively for each candidate document.
public indirect enum Predicate: Sendable {
  // Comparisons

  /// Matches documents where the field equals the given value. This is the
  /// most efficient predicate because it can be pushed down to an indexed
  /// lookup O(log n) via binary search when an index on the field exists.
  case equal(String, any FieldValueConvertible)
  /// Matches documents where the field differs from the given value.
  /// Always evaluated in memory — the index can only answer equality, not
  /// inequality, without a full scan.
  case notEqual(String, any FieldValueConvertible)
  /// Matches documents where the field is strictly less than the given value.
  /// Uses an indexed range scan (O(log n + k)) when an index on the field
  /// exists; falls back to in-memory filtering otherwise.
  case lessThan(String, any FieldValueConvertible)
  /// Matches documents where the field is less than or equal to the given
  /// value. Uses an indexed range scan when available.
  case lessThanOrEqual(String, any FieldValueConvertible)
  /// Matches documents where the field is strictly greater than the given
  /// value. Uses an indexed range scan when available.
  case greaterThan(String, any FieldValueConvertible)
  /// Matches documents where the field is greater than or equal to the given
  /// value. Uses an indexed range scan when available.
  case greaterThanOrEqual(String, any FieldValueConvertible)
  /// Matches documents where the field falls within the inclusive range
  /// `[lower, upper]`. Uses an indexed range scan when available. Both
  /// bounds are required and must be of compatible types.
  case between(String, any FieldValueConvertible, any FieldValueConvertible)
  /// Matches documents where the field is a member of the given set. When an
  /// index exists, each element is looked up individually and the results are
  /// merged (OR semantics). This avoids a full scan for small-to-medium IN
  /// lists; for large sets a full scan may be cheaper.
  case inSet(String, [any FieldValueConvertible])
  /// Matches documents where the field is **not** a member of the given set.
  /// Always evaluated in memory because the index stores only positive
  /// membership — exclusion requires scanning the posting list or filtering.
  case notInSet(String, [any FieldValueConvertible])

  // Text matching

  /// Matches documents where the string field contains the given substring
  /// anywhere in its value. Comparison is case-sensitive and uses
  /// `String.contains(_:)`. Always evaluated in memory — there is no
  /// substring index.
  case contains(String, String)
  /// Matches documents where the string field starts with the given prefix.
  /// Comparison is case-sensitive and uses `String.hasPrefix(_:)`. Always
  /// evaluated in memory.
  case startsWith(String, String)
  /// Matches documents where the string field ends with the given suffix.
  /// Comparison is case-sensitive and uses `String.hasSuffix(_:)`. Always
  /// evaluated in memory.
  case endsWith(String, String)
  /// Matches documents where the string field matches a SQL-style LIKE
  /// pattern. Supports `%` (any sequence of characters) and `_` (any single
  /// character). The pattern is compiled into an `NSRegularExpression` at
  /// predicate-construction time (so the regex is built once, not once per
  /// document). Matching is **case-insensitive**. Always evaluated in memory.
  ///
  /// - Note: There is no escape character. To match a literal `%` or `_`,
  ///   use a custom `Predicate.glob` or `.equal` instead.
  case like(String, String, SafeRegex)
  /// Matches documents where the string field matches a shell-style glob
  /// pattern. Supports `*` (any sequence), `?` (any single character), and
  /// `[...]` (character class with optional negation via `[!...]`). The
  /// pattern is compiled into an `NSRegularExpression` at predicate-construction
  /// time. Matching is **case-sensitive**. Always evaluated in memory.
  ///
  /// - Note: The implementation converts the glob to a regex, so edge cases
  ///   with path separators or special file-glob rules may not apply.
  case glob(String, String, SafeRegex)

  // Existence

  /// Matches documents where the given field is present (not null and not
  /// absent from the document). The field must exist at any depth reachable
  /// via dot-path notation. Always evaluated in memory.
  case exists(String)
  /// Matches documents where the given field is absent (null or missing from
  /// the document). Always evaluated in memory.
  case notExists(String)

  // Logical Operators

  /// Matches documents that satisfy **all** child predicates (logical AND).
  /// Evaluation short-circuits on the first failure for performance.
  case and([Predicate])
  /// Matches documents that satisfy **any** child predicate (logical OR).
  /// Evaluation short-circuits on the first success for performance.
  case or([Predicate])
  /// Matches documents that do **not** satisfy the child predicate
  /// (logical NOT).
  case not(Predicate)

  /// The field name referenced by this predicate, if it is a leaf predicate.
  /// Returns `nil` for `.and`, `.or`, and `.not` nodes.
  var field: String? {
    switch self {
    case .equal(let f, _), .notEqual(let f, _),
      .lessThan(let f, _), .lessThanOrEqual(let f, _),
      .greaterThan(let f, _), .greaterThanOrEqual(let f, _),
      .between(let f, _, _), .inSet(let f, _),
      .notInSet(let f, _), .contains(let f, _),
      .startsWith(let f, _), .endsWith(let f, _),
      .like(let f, _, _), .glob(let f, _, _),
      .exists(let f), .notExists(let f):
      return f
    case .and, .or, .not:
      return nil
    }
  }
}

// MARK: - QueryBuilder

/// An immutable, fluent query builder for executing typed queries against a
/// NyaruDB collection.
///
/// `QueryBuilder` is created by `NyaruCollection.find()` and provides a
/// chainable API for adding predicates, sorting, pagination, and executing
/// the query:
///
/// ```swift
/// let results = try await collection.find()
///     .where("age", isGreaterThan: 18)
///     .where("status", isEqualTo: "active")
///     .sort(by: "name", ascending: true)
///     .limit(20)
///     .offset(0)
///     .execute()
/// ```
///
/// **Query planning.** The builder includes a simple cost-based planner that
/// selects the most efficient access path:
/// 1. Index equality lookup (highest priority).
/// 2. Index `IN` set lookup.
/// 3. Index range/comparison lookup.
/// 4. Partition scan (if a partition key equality predicate exists).
/// 5. Full collection scan (fallback).
///
/// Call `explain()` to inspect the plan without executing.
public struct QueryBuilder<T: Codable & Sendable>: Sendable {
  private let core: CollectionCore
  private let partitionKey: String?
  private let format: SerializationFormat

  internal var rootPredicate: Predicate = .and([])
  internal var sortField: String?
  internal var sortAscending = true
  internal var limitCount: Int?
  internal var offsetCount = 0

  init(core: CollectionCore, partitionKey: String?, format: SerializationFormat) {
    self.core = core
    self.partitionKey = partitionKey
    self.format = format
  }

  // MARK: - Fluent predicate API

  /// Internal: appends a predicate to the root AND conjunction.
  internal func adding(_ predicate: Predicate) -> Self {
    var copy = self
    if case .and(var arr) = copy.rootPredicate {
      arr.append(predicate)
      copy.rootPredicate = .and(arr)
    } else {
      copy.rootPredicate = .and([copy.rootPredicate, predicate])
    }
    return copy
  }

  /// Adds an equality predicate: `field == value`.
  ///
  /// - Parameters:
  ///   - field: The field name.
  ///   - value: The expected value.
  /// - Returns: A new query builder with the predicate added.
  public func `where`(_ field: String, isEqualTo value: FieldValueConvertible) -> Self {
    adding(.equal(field, value))
  }

  /// Adds a not-equal predicate: `field != value`.
  public func `where`(_ field: String, isNotEqualTo value: FieldValueConvertible) -> Self {
    adding(.notEqual(field, value))
  }

  /// Adds a less-than predicate: `field < value`.
  public func `where`(_ field: String, isLessThan value: FieldValueConvertible) -> Self {
    adding(.lessThan(field, value))
  }

  /// Adds a less-than-or-equal predicate: `field <= value`.
  public func `where`(_ field: String, isLessThanOrEqualTo value: FieldValueConvertible) -> Self {
    adding(.lessThanOrEqual(field, value))
  }

  /// Adds a greater-than predicate: `field > value`.
  public func `where`(_ field: String, isGreaterThan value: FieldValueConvertible) -> Self {
    adding(.greaterThan(field, value))
  }

  /// Adds a greater-than-or-equal predicate: `field >= value`.
  public func `where`(_ field: String, isGreaterThanOrEqualTo value: FieldValueConvertible) -> Self
  {
    adding(.greaterThanOrEqual(field, value))
  }

  /// Adds an inclusive range predicate: `lower <= field <= upper`.
  ///
  /// - Parameters:
  ///   - field: The field name.
  ///   - lower: The lower bound.
  ///   - upper: The upper bound.
  public func `where`(
    _ field: String, isBetween lower: FieldValueConvertible, and upper: FieldValueConvertible
  ) -> Self {
    adding(.between(field, lower, upper))
  }

  /// Adds a membership predicate: `field IN values`.
  public func `where`(_ field: String, isIn values: [FieldValueConvertible]) -> Self {
    adding(.inSet(field, values))
  }

  /// Adds a negated membership predicate: `field NOT IN values`.
  public func `where`(_ field: String, isNotIn values: [FieldValueConvertible]) -> Self {
    adding(.notInSet(field, values))
  }

  /// Adds a substring containment predicate on a string field.
  public func `where`(_ field: String, contains substring: String) -> Self {
    adding(.contains(field, substring))
  }

  /// Adds a string prefix predicate.
  public func `where`(_ field: String, startsWith prefix: String) -> Self {
    adding(.startsWith(field, prefix))
  }

  /// Adds a string suffix predicate.
  public func `where`(_ field: String, endsWith suffix: String) -> Self {
    adding(.endsWith(field, suffix))
  }

  /// Adds a SQL-style LIKE predicate. The pattern supports `%` (any sequence)
  /// and `_` (single character). Matching is case-insensitive.
  ///
  /// - Parameter pattern: The LIKE pattern.
  public func `where`(_ field: String, like pattern: String) -> Self {
    var regexStr = ""
    for char in pattern {
      switch char {
      case "%": regexStr += ".*"
      case "_": regexStr += "."
      default:
        if "\\^$.|?*+()[]{}".contains(char) {
          regexStr += "\\\(char)"
        } else {
          regexStr += String(char)
        }
      }
    }
    let regex = try? NSRegularExpression(pattern: "^" + regexStr + "$", options: .caseInsensitive)
    return adding(.like(field, pattern, SafeRegex(regex: regex)))
  }

  /// Adds a shell-style glob predicate. The pattern supports `*` (any
  /// sequence), `?` (single character), and `[...]` (character class).
  /// Matching is case-sensitive.
  ///
  /// - Parameter pattern: The glob pattern.
  public func `where`(_ field: String, glob pattern: String) -> Self {
    var regexStr = ""
    var inClass = false

    for char in pattern {
      switch char {
      case "*": regexStr += inClass ? String(char) : ".*"
      case "?": regexStr += inClass ? String(char) : "."
      case "[":
        regexStr += "["
        inClass = true
      case "]":
        regexStr += "]"
        inClass = false
      default:
        if !inClass && "\\^$.|+(){}".contains(char) {
          regexStr += "\\\(char)"
        } else {
          regexStr += String(char)
        }
      }
    }

    let regex = try? NSRegularExpression(pattern: "^" + regexStr + "$", options: [])
    return adding(.glob(field, pattern, SafeRegex(regex: regex)))
  }

  /// Requires that the given field is present (not null/absent).
  public func whereExists(_ field: String) -> Self {
    adding(.exists(field))
  }

  /// Requires that the given field is absent (null or missing).
  public func whereNotExists(_ field: String) -> Self {
    adding(.notExists(field))
  }

  /// Adds an arbitrary predicate node to the conjunction.
  public func `where`(_ predicate: Predicate) -> Self {
    adding(predicate)
  }

  /// Sets the sort field and direction for the query results.
  ///
  /// Sorting is performed in memory after fetching matching documents.
  /// When a sort field is set, pagination (offset/limit) is applied after
  /// sorting.
  ///
  /// - Parameters:
  ///   - field: The field to sort by.
  ///   - ascending: `true` for ascending order (default), `false` for descending.
  /// - Returns: A new query builder with sort applied.
  public func sort(by field: String, ascending: Bool = true) -> Self {
    var copy = self
    copy.sortField = field
    copy.sortAscending = ascending
    return copy
  }

  /// Limits the number of results returned.
  ///
  /// - Parameter count: Maximum number of documents to return (0 means none).
  /// - Returns: A new query builder with the limit applied.
  public func limit(_ count: Int) -> Self {
    var copy = self
    copy.limitCount = max(0, count)
    return copy
  }

  /// Skips the first `count` results.
  ///
  /// Pagination (offset) requires a sort field to guarantee deterministic
  /// ordering. Throws `unsupportedOperation` if offset is set without a
  /// sort field.
  ///
  /// - Parameter count: Number of results to skip.
  /// - Returns: A new query builder with the offset applied.
  public func offset(_ count: Int) -> Self {
    var copy = self
    copy.offsetCount = max(0, count)
    return copy
  }

  // MARK: - Planning

  /// Selects the best query execution strategy based on the available indexes
  /// and the partition key configuration.
  ///
  /// The planner walks top-level AND predicates in priority order and picks
  /// the **first** matching strategy — once a strategy is selected, no
  /// further predicates are evaluated for pushdown. Remaining predicates
  /// become residual filters applied in memory.
  ///
  /// Priority order (most to least efficient):
  /// 1. **Index equality** — exact match on an indexed field. O(log n) via
  ///    binary search. Always selected when available.
  /// 2. **Index IN set** — each element looked up via index, results merged.
  ///    Efficient for small-to-medium sets.
  /// 3. **Index range/comparison** — range scan on an indexed field. Avoids
  ///    scanning non-matching keys entirely.
  /// 4. **Partition scan** — equality on the partition key. Restricts I/O to
  ///    a single shard file instead of all shards.
  /// 5. **Full scan** — reads every shard. Used when no index or partition
  ///    pruning applies. All predicates are evaluated in memory.
  private func plan() async -> (QueryStrategy, pushedDown: Int) {
    var topLevelPredicates: [Predicate] = []
    if case .and(let arr) = rootPredicate {
      topLevelPredicates = arr
    } else {
      topLevelPredicates = [rootPredicate]
    }

    for predicate in topLevelPredicates {
      if case .equal(let field, _) = predicate, await core.isIndexed(field: field) {
        return (.indexLookup(field: field), 1)
      }
    }
    for predicate in topLevelPredicates {
      if case .inSet(let field, _) = predicate, await core.isIndexed(field: field) {
        return (.indexLookup(field: field), 1)
      }
    }
    for predicate in topLevelPredicates {
      switch predicate {
      case .between(let field, _, _),
        .lessThan(let field, _), .lessThanOrEqual(let field, _),
        .greaterThan(let field, _), .greaterThanOrEqual(let field, _):
        if await core.isIndexed(field: field) {
          return (.indexLookup(field: field), 1)
        }
      default:
        break
      }
    }
    if let partitionKey {
      for predicate in topLevelPredicates {
        if case .equal(let field, let value) = predicate, field == partitionKey {
          return (.partitionScan(value: value.fieldValue.description), 0)
        }
      }
    }
    return (.fullScan, 0)
  }

  /// Returns the query execution plan without running the query.
  ///
  /// Use this to inspect how the query will be executed and which access
  /// path the planner selected. The planner uses a fixed priority order
  /// (index equality > IN set > range > partition scan > full scan) and
  /// reports how many top-level predicates remain as residual memory filters.
  ///
  /// - Returns: A `QueryPlan` describing the strategy and residual predicates.
  public func explain() async -> QueryPlan {
    let (strategy, pushed) = await plan()
    return QueryPlan(strategy: strategy, residualPredicates: topLevelPredicateCount() - pushed)
  }

  private func topLevelPredicateCount() -> Int {
    if case .and(let arr) = rootPredicate { return arr.count }
    return 1
  }

  // MARK: - Execution

  /// Fetches candidate documents from the most efficient access path.
  private func candidates() async throws -> ([Data], Bool) {
    let (strategy, _) = await plan()
    switch strategy {
    case .indexLookup(let field):
      var pointers = await pointers(forIndexedField: field)

      // We can only do this if there are no residual predicates that might filter out
      // documents AFTER the fetch, and if the sort is aligned with the index (or absent).
      let canPushdown = topLevelPredicateCount() == 1 && (sortField == nil || sortField == field)
      if canPushdown {
        let start = min(offsetCount, pointers.count)
        let end = min(start + (limitCount ?? (pointers.count - start)), pointers.count)
        pointers = Array(pointers[start..<end])
      }

      // PHASE 0.2: Batch fetch per shard
      let data = try await core.fetch(pointers: pointers)
      return (data, canPushdown)

    case .partitionScan:
      if let partitionKey {
        var topLevelPredicates: [Predicate] = []
        if case .and(let arr) = rootPredicate {
          topLevelPredicates = arr
        } else {
          topLevelPredicates = [rootPredicate]
        }

        for predicate in topLevelPredicates {
          if case .equal(let f, let v) = predicate, f == partitionKey {
            let data = try await core.scanPartition(value: v.fieldValue)
            return (data, false)
          }
        }
      }
      let data = try await core.scanAll()
      return (data, false)
    case .fullScan:
      let data = try await core.scanAll()
      return (data, false)
    }
  }

  /// Resolves index pointers for the indexed field used in the plan.
  private func pointers(forIndexedField field: String) async -> [RecordPointer] {
    var topLevelPredicates: [Predicate] = []
    if case .and(let arr) = rootPredicate {
      topLevelPredicates = arr
    } else {
      topLevelPredicates = [rootPredicate]
    }

    for predicate in topLevelPredicates where predicate.field == field {
      switch predicate {
      case .equal(_, let value):
        return await core.indexSearch(field: field, key: value.fieldValue)
      case .inSet(_, let values):
        var out: [RecordPointer] = []
        for value in values {
          out.append(contentsOf: await core.indexSearch(field: field, key: value.fieldValue))
        }
        return out
      case .between(_, let lower, let upper):
        return await core.indexRange(
          field: field,
          lower: lower.fieldValue, lowerInclusive: true,
          upper: upper.fieldValue, upperInclusive: true
        )
      case .lessThan(_, let value):
        return await core.indexRange(
          field: field, lower: nil, lowerInclusive: true,
          upper: value.fieldValue, upperInclusive: false
        )
      case .lessThanOrEqual(_, let value):
        return await core.indexRange(
          field: field, lower: nil, lowerInclusive: true,
          upper: value.fieldValue, upperInclusive: true
        )
      case .greaterThan(_, let value):
        return await core.indexRange(
          field: field, lower: value.fieldValue, lowerInclusive: false,
          upper: nil, upperInclusive: true
        )
      case .greaterThanOrEqual(_, let value):
        return await core.indexRange(
          field: field, lower: value.fieldValue, lowerInclusive: true,
          upper: nil, upperInclusive: true
        )
      default:
        continue
      }
    }
    return []
  }

  /// Executes the query and returns all matching documents, decoded.
  ///
  /// - Returns: An array of decoded documents matching all predicates.
  /// - Throws: `NyaruError.decodingFailed` if a document fails to decode.
  public func execute() async throws -> [T] {
    let matching = try await matchingDocuments()
    return try matching.map { json in
      do {
        return try Serializer.decode(T.self, from: json, format: format)
      } catch {
        throw NyaruError.decodingFailed(String(describing: error))
      }
    }
  }

  /// Returns the first matching document, or `nil` if none match.
  ///
  /// Internally applies `limit(1)` before executing.
  public func first() async throws -> T? {
    try await limit(1).execute().first
  }

  /// Returns the count of matching documents without decoding them.
  ///
  /// More efficient than `execute().count` because it skips decoding.
  public func count() async throws -> Int {
    try await matchingDocuments().count
  }

  /// Returns all distinct values of a field among the matching documents.
  ///
  /// - Parameter field: The field to collect distinct values from.
  /// - Returns: An array of distinct `FieldValue` instances.
  public func distinctValues(on field: String) async throws -> [FieldValue] {
    let (raw, _) = try await candidates()
    var seen = Set<FieldValue>()
    var result: [FieldValue] = []

    for json in raw {
      guard let dict = try? FieldExtractor.parse(json, using: format) else { continue }
      if Self.evaluate(rootPredicate, in: dict) {
        if let value = FieldExtractor.value(in: dict, path: field), !seen.contains(value) {
          seen.insert(value)
          result.append(value)
        }
      }
    }
    return result
  }

  /// Deletes all matching documents and returns the number removed.
  ///
  /// - Returns: The count of deleted documents.
  /// - Throws: Errors from the underlying delete operation.
  @discardableResult
  public func delete() async throws -> Int {
    let matched = try await matchedParsed()
    let idField = await core.idField
    var removed = 0
    for item in matched {
      guard let id = FieldExtractor.value(in: item.dict, path: idField) else { continue }
      if try await core.delete(id: id) { removed += 1 }
    }
    return removed
  }

  /// Returns matching documents as raw data (for counting).
  private func matchingDocuments() async throws -> [Data] {
    try await matchedParsed().map(\.json)
  }

  /// Returns matching documents as parsed dictionaries with their raw data.
  private func matchedParsed() async throws -> [(dict: [String: Any], json: Data)] {
    let (raw, alreadyPaginated) = try await candidates()

    if !alreadyPaginated && offsetCount > 0 && sortField == nil {
      throw NyaruError.unsupportedOperation(
        "Pagination (offset) requires a sort field to guarantee deterministic order."
      )
    }

    let requiresFullEvaluation = sortField != nil

    var matched: [(dict: [String: Any], json: Data)] = []
    var skipped = 0

    for json in raw {
      guard let dict = try? FieldExtractor.parse(json, using: format) else { continue }

      if Self.evaluate(rootPredicate, in: dict) {
        if requiresFullEvaluation {
          matched.append((dict, json))
        } else {
          if alreadyPaginated {
            // Limit/offset já foi aplicado no array de ponteiros, só adiciona.
            matched.append((dict, json))
          } else {
            if skipped < offsetCount {
              skipped += 1
              continue
            }
            matched.append((dict, json))
            if let limitCount, matched.count >= limitCount {
              break
            }
          }
        }
      }
    }

    if requiresFullEvaluation, let sortField {
      matched.sort { lhs, rhs in
        let a = FieldExtractor.value(in: lhs.dict, path: sortField) ?? .null
        let b = FieldExtractor.value(in: rhs.dict, path: sortField) ?? .null
        return sortAscending ? a < b : b < a
      }

      // Aplica offset/limit apenas se não foi feito pushdown
      if !alreadyPaginated {
        if offsetCount > 0 {
          matched = offsetCount < matched.count ? Array(matched[offsetCount...]) : []
        }
        if let limitCount, matched.count > limitCount {
          matched = Array(matched.prefix(limitCount))
        }
      }
    }

    return matched
  }

  // MARK: - Predicate evaluation

  /// Checks whether two `FieldValue` instances are of comparable types.
  ///
  /// Two values are comparable if they share the same base type or are both
  /// numeric (int and double).
  private static func comparable(_ a: FieldValue, _ b: FieldValue) -> Bool {
    switch (a, b) {
    case (.int(_), .int(_)), (.double(_), .double(_)), (.string(_), .string(_)),
      (.bool(_), .bool(_)), (.int(_), .double(_)), (.double(_), .int(_)):
      return true
    default:
      return false
    }
  }

  /// Recursively evaluates a predicate against a parsed document dictionary.
  ///
  /// - Parameters:
  ///   - predicate: The predicate tree to evaluate.
  ///   - dict: The parsed document dictionary.
  /// - Returns: `true` if the document matches the predicate.
  static func evaluate(_ predicate: Predicate, in dict: [String: Any]) -> Bool {
    switch predicate {

    case .and(let predicates):
      return predicates.allSatisfy { evaluate($0, in: dict) }

    case .or(let predicates):
      return predicates.contains { evaluate($0, in: dict) }

    case .not(let pred):
      return !evaluate(pred, in: dict)

    case .exists(let field):
      return FieldExtractor.value(in: dict, path: field) != nil

    case .notExists(let field):
      return FieldExtractor.value(in: dict, path: field) == nil

    case .equal(let field, let target):
      return FieldExtractor.value(in: dict, path: field) == target.fieldValue

    case .notEqual(let field, let target):
      return FieldExtractor.value(in: dict, path: field) != target.fieldValue

    case .lessThan(let field, let target):
      guard let value = FieldExtractor.value(in: dict, path: field),
        comparable(value, target.fieldValue)
      else { return false }
      return value < target.fieldValue

    case .lessThanOrEqual(let field, let target):
      guard let value = FieldExtractor.value(in: dict, path: field),
        comparable(value, target.fieldValue)
      else { return false }
      return value <= target.fieldValue

    case .greaterThan(let field, let target):
      guard let value = FieldExtractor.value(in: dict, path: field),
        comparable(value, target.fieldValue)
      else { return false }
      return value > target.fieldValue

    case .greaterThanOrEqual(let field, let target):
      guard let value = FieldExtractor.value(in: dict, path: field),
        comparable(value, target.fieldValue)
      else { return false }
      return value >= target.fieldValue

    case .between(let field, let lower, let upper):
      guard let value = FieldExtractor.value(in: dict, path: field),
        comparable(value, lower.fieldValue), comparable(value, upper.fieldValue)
      else { return false }
      return value >= lower.fieldValue && value <= upper.fieldValue

    case .inSet(let field, let targets):
      guard let value = FieldExtractor.value(in: dict, path: field) else { return false }
      return targets.contains { $0.fieldValue == value }

    case .notInSet(let field, let targets):
      guard let value = FieldExtractor.value(in: dict, path: field) else { return true }
      return !targets.contains { $0.fieldValue == value }

    case .contains(let field, let substring):
      guard case .string(let s)? = FieldExtractor.value(in: dict, path: field) else { return false }
      return s.contains(substring)

    case .startsWith(let field, let prefix):
      guard case .string(let s)? = FieldExtractor.value(in: dict, path: field) else { return false }
      return s.hasPrefix(prefix)

    case .endsWith(let field, let suffix):
      guard case .string(let s)? = FieldExtractor.value(in: dict, path: field) else { return false }
      return s.hasSuffix(suffix)

    case .like(let field, _, let safeRegex):
      guard case .string(let s)? = FieldExtractor.value(in: dict, path: field) else { return false }
      guard let regex = safeRegex.regex else { return false }
      let range = NSRange(s.startIndex..., in: s)
      return regex.firstMatch(in: s, options: [], range: range) != nil

    case .glob(let field, _, let safeRegex):
      guard case .string(let s)? = FieldExtractor.value(in: dict, path: field) else { return false }
      guard let regex = safeRegex.regex else { return false }
      let range = NSRange(s.startIndex..., in: s)
      return regex.firstMatch(in: s, options: [], range: range) != nil
    }
  }
}
