import Foundation

/// How a query will be executed. Returned by `QueryBuilder.explain()`.
public enum QueryStrategy: Sendable, Equatable, CustomStringConvertible {
  /// Candidate set resolved through the index on the given field.
  case indexLookup(field: String)
  /// Scan restricted to a single partition shard.
  case partitionScan(value: String)
  /// Every live document is scanned.
  case fullScan

  public var description: String {
    switch self {
    case .indexLookup(let field): return "index lookup on '\(field)'"
    case .partitionScan(let value): return "partition scan of '\(value)'"
    case .fullScan: return "full scan"
    }
  }
}

public struct QueryPlan: Sendable {
  public let strategy: QueryStrategy
  public let residualPredicates: Int
}

/// A fluent, immutable query over one collection.
///
/// Field names are JSON key paths ("age", "address.city"). Equality and
/// range predicates on indexed fields are pushed down to the index; an
/// equality predicate on the partition key restricts the scan to one shard.
/// Every predicate is *also* re-verified against the fetched document, so a
/// pushed-down predicate can never return a false positive.
public struct QueryBuilder<T: Codable & Sendable>: Sendable {
  enum Predicate: Sendable {
    case equal(String, FieldValue)
    case notEqual(String, FieldValue)
    case lessThan(String, FieldValue)
    case lessThanOrEqual(String, FieldValue)
    case greaterThan(String, FieldValue)
    case greaterThanOrEqual(String, FieldValue)
    case between(String, FieldValue, FieldValue)
    case inSet(String, [FieldValue])
    case contains(String, String)
    case startsWith(String, String)
    case endsWith(String, String)
    case exists(String)
    case notExists(String)

    var field: String {
      switch self {
      case .equal(let f, _), .notEqual(let f, _),
        .lessThan(let f, _), .lessThanOrEqual(let f, _),
        .greaterThan(let f, _), .greaterThanOrEqual(let f, _),
        .between(let f, _, _), .inSet(let f, _),
        .contains(let f, _), .startsWith(let f, _), .endsWith(let f, _),
        .exists(let f), .notExists(let f):
        return f
      }
    }
  }

  private let core: CollectionCore
  private let partitionKey: String?
  private var predicates: [Predicate] = []
  private var sortField: String?
  private var sortAscending = true
  private var limitCount: Int?
  private var offsetCount = 0

  init(core: CollectionCore, partitionKey: String?) {
    self.core = core
    self.partitionKey = partitionKey
  }

  // MARK: - Fluent predicate API

  private func adding(_ predicate: Predicate) -> Self {
    var copy = self
    copy.predicates.append(predicate)
    return copy
  }

  public func `where`(_ field: String, isEqualTo value: FieldValueConvertible) -> Self {
    adding(.equal(field, value.fieldValue))
  }
  public func `where`(_ field: String, isNotEqualTo value: FieldValueConvertible) -> Self {
    adding(.notEqual(field, value.fieldValue))
  }
  public func `where`(_ field: String, isLessThan value: FieldValueConvertible) -> Self {
    adding(.lessThan(field, value.fieldValue))
  }
  public func `where`(_ field: String, isLessThanOrEqualTo value: FieldValueConvertible) -> Self {
    adding(.lessThanOrEqual(field, value.fieldValue))
  }
  public func `where`(_ field: String, isGreaterThan value: FieldValueConvertible) -> Self {
    adding(.greaterThan(field, value.fieldValue))
  }
  public func `where`(_ field: String, isGreaterThanOrEqualTo value: FieldValueConvertible) -> Self
  {
    adding(.greaterThanOrEqual(field, value.fieldValue))
  }
  public func `where`(
    _ field: String, isBetween lower: FieldValueConvertible, and upper: FieldValueConvertible
  ) -> Self {
    adding(.between(field, lower.fieldValue, upper.fieldValue))
  }
  public func `where`(_ field: String, isIn values: [FieldValueConvertible]) -> Self {
    adding(.inSet(field, values.map(\.fieldValue)))
  }
  public func `where`(_ field: String, contains substring: String) -> Self {
    adding(.contains(field, substring))
  }
  public func `where`(_ field: String, startsWith prefix: String) -> Self {
    adding(.startsWith(field, prefix))
  }
  public func `where`(_ field: String, endsWith suffix: String) -> Self {
    adding(.endsWith(field, suffix))
  }
  public func whereExists(_ field: String) -> Self {
    adding(.exists(field))
  }
  public func whereNotExists(_ field: String) -> Self {
    adding(.notExists(field))
  }

  public func sort(by field: String, ascending: Bool = true) -> Self {
    var copy = self
    copy.sortField = field
    copy.sortAscending = ascending
    return copy
  }

  public func limit(_ count: Int) -> Self {
    var copy = self
    copy.limitCount = max(0, count)
    return copy
  }

  public func offset(_ count: Int) -> Self {
    var copy = self
    copy.offsetCount = max(0, count)
    return copy
  }

  // MARK: - Planning

  /// Chooses the cheapest access path without pseudo-statistics:
  /// index equality > index in-set > index range > partition scan > full
  /// scan. (The old planner "estimated" costs from access-frequency
  /// metrics that had nothing to do with selectivity; this deterministic
  /// ordering is honest and predictable.)
  private func plan() async -> (QueryStrategy, pushedDown: Int) {
    // 1. Index equality.
    for predicate in predicates {
      if case .equal(let field, _) = predicate, await core.isIndexed(field: field) {
        return (.indexLookup(field: field), 1)
      }
    }
    // 2. Index in-set.
    for predicate in predicates {
      if case .inSet(let field, _) = predicate, await core.isIndexed(field: field) {
        return (.indexLookup(field: field), 1)
      }
    }
    // 3. Index range / comparison.
    for predicate in predicates {
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
    // 4. Partition pruning.
    if let partitionKey {
      for predicate in predicates {
        if case .equal(let field, let value) = predicate, field == partitionKey {
          return (.partitionScan(value: value.description), 0)
        }
      }
    }
    return (.fullScan, 0)
  }

  public func explain() async -> QueryPlan {
    let (strategy, pushed) = await plan()
    return QueryPlan(strategy: strategy, residualPredicates: predicates.count - pushed)
  }

  // MARK: - Execution

  /// Gathers candidate documents according to the plan.
  private func candidates() async throws -> [Data] {
    let (strategy, _) = await plan()
    switch strategy {
    case .indexLookup(let field):
      let pointers = await pointers(forIndexedField: field)
      return try await core.fetch(pointers: pointers)
    case .partitionScan:
      // Recover the FieldValue from the matching predicate.
      if let partitionKey {
        for predicate in predicates {
          if case .equal(let f, let v) = predicate, f == partitionKey {
            return try await core.scanPartition(value: v)
          }
        }
      }
      return try await core.scanAll()
    case .fullScan:
      return try await core.scanAll()
    }
  }

  private func pointers(forIndexedField field: String) async -> [RecordPointer] {
    for predicate in predicates where predicate.field == field {
      switch predicate {
      case .equal(_, let value):
        return await core.indexSearch(field: field, key: value)
      case .inSet(_, let values):
        var out: [RecordPointer] = []
        for value in values {
          out.append(contentsOf: await core.indexSearch(field: field, key: value))
        }
        return out
      case .between(_, let lower, let upper):
        return await core.indexRange(
          field: field,
          lower: lower, lowerInclusive: true,
          upper: upper, upperInclusive: true
        )
      case .lessThan(_, let value):
        return await core.indexRange(
          field: field, lower: nil, lowerInclusive: true,
          upper: value, upperInclusive: false
        )
      case .lessThanOrEqual(_, let value):
        return await core.indexRange(
          field: field, lower: nil, lowerInclusive: true,
          upper: value, upperInclusive: true
        )
      case .greaterThan(_, let value):
        return await core.indexRange(
          field: field, lower: value, lowerInclusive: false,
          upper: nil, upperInclusive: true
        )
      case .greaterThanOrEqual(_, let value):
        return await core.indexRange(
          field: field, lower: value, lowerInclusive: true,
          upper: nil, upperInclusive: true
        )
      default:
        continue
      }
    }
    return []
  }

  /// Runs the query and decodes matching documents.
  public func execute() async throws -> [T] {
    let matching = try await matchingDocuments()
    let decoder = JSONDecoder()
    return try matching.map { json in
      do {
        return try decoder.decode(T.self, from: json)
      } catch {
        throw NyaruError.decodingFailed(String(describing: error))
      }
    }
  }

  public func first() async throws -> T? {
    try await limit(1).execute().first
  }

  public func count() async throws -> Int {
    try await matchingDocuments().count
  }

  /// Deletes every matching document through the primary-index delete
  /// path (so all secondary indexes stay consistent). `sort`/`offset`/
  /// `limit` are honored, which allows patterns like "delete the 100
  /// oldest". Returns the number of documents removed.
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

  private func matchingDocuments() async throws -> [Data] {
    try await matchedParsed().map(\.json)
  }

  private func matchedParsed() async throws -> [(dict: [String: Any], json: Data)] {
    let raw = try await candidates()

    // Parse once, evaluate all predicates.
    var matched: [(dict: [String: Any], json: Data)] = []
    for json in raw {
      guard let dict = try? FieldExtractor.parse(json) else { continue }
      if predicates.allSatisfy({ Self.evaluate($0, in: dict) }) {
        matched.append((dict, json))
      }
    }

    if let sortField {
      matched.sort { lhs, rhs in
        let a = FieldExtractor.value(in: lhs.dict, path: sortField) ?? .null
        let b = FieldExtractor.value(in: rhs.dict, path: sortField) ?? .null
        return sortAscending ? a < b : b < a
      }
    }

    if offsetCount > 0 {
      matched = offsetCount < matched.count ? Array(matched[offsetCount...]) : []
    }
    if let limitCount, matched.count > limitCount {
      matched = Array(matched.prefix(limitCount))
    }
    return matched
  }

  // MARK: - Predicate evaluation

  /// Comparisons are only meaningful between values of the same JSON kind;
  /// cross-kind comparisons evaluate to false. (The old engine compared
  /// mismatched types via `hashValue` casts, which produced garbage.)
  private static func comparable(_ a: FieldValue, _ b: FieldValue) -> Bool {
    switch (a, b) {
    case (.int(_), .int(_)), (.double(_), .double(_)), (.string(_), .string(_)),
      (.bool(_), .bool(_)):
      return true
    default:
      return false
    }
  }

  static func evaluate(_ predicate: Predicate, in dict: [String: Any]) -> Bool {
    let value = FieldExtractor.value(in: dict, path: predicate.field)
    switch predicate {
    case .exists:
      return value != nil
    case .notExists:
      return value == nil
    case .equal(_, let target):
      return value == target
    case .notEqual(_, let target):
      return value != target
    case .lessThan(_, let target):
      guard let value, comparable(value, target) else { return false }
      return value < target
    case .lessThanOrEqual(_, let target):
      guard let value, comparable(value, target) else { return false }
      return value <= target
    case .greaterThan(_, let target):
      guard let value, comparable(value, target) else { return false }
      return value > target
    case .greaterThanOrEqual(_, let target):
      guard let value, comparable(value, target) else { return false }
      return value >= target
    case .between(_, let lower, let upper):
      guard let value, comparable(value, lower), comparable(value, upper) else { return false }
      return value >= lower && value <= upper
    case .inSet(_, let targets):
      guard let value else { return false }
      return targets.contains(value)
    case .contains(_, let substring):
      guard case .string(let s)? = value else { return false }
      return s.contains(substring)
    case .startsWith(_, let prefix):
      guard case .string(let s)? = value else { return false }
      return s.hasPrefix(prefix)
    case .endsWith(_, let suffix):
      guard case .string(let s)? = value else { return false }
      return s.hasSuffix(suffix)
    }
  }
}
