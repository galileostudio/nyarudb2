import Foundation

/// How a query will be executed. Returned by `QueryBuilder.explain()`.
public enum QueryStrategy: Sendable, Equatable, CustomStringConvertible {
  case indexLookup(field: String)
  case partitionScan(value: String)
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

// MARK: - Regex Wrapper for Concurrency
public struct SafeRegex: @unchecked Sendable {
  public let regex: NSRegularExpression?
}

// MARK: - Predicate Tree

/// A recursive predicate tree allowing complex boolean logic (AND, OR, NOT).
public indirect enum Predicate: Sendable {
  // Comparisons
  case equal(String, any FieldValueConvertible)
  case notEqual(String, any FieldValueConvertible)
  case lessThan(String, any FieldValueConvertible)
  case lessThanOrEqual(String, any FieldValueConvertible)
  case greaterThan(String, any FieldValueConvertible)
  case greaterThanOrEqual(String, any FieldValueConvertible)
  case between(String, any FieldValueConvertible, any FieldValueConvertible)
  case inSet(String, [any FieldValueConvertible])
  case notInSet(String, [any FieldValueConvertible])

  // Text matching
  case contains(String, String)
  case startsWith(String, String)
  case endsWith(String, String)
  case like(String, String, SafeRegex)
  case glob(String, String, SafeRegex)

  // Existence
  case exists(String)
  case notExists(String)

  // Logical Operators
  case and([Predicate])
  case or([Predicate])
  case not(Predicate)

  /// Attempts to extract the field name if this is a leaf predicate.
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

/// A fluent, immutable query over one collection.
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

  public func `where`(_ field: String, isEqualTo value: FieldValueConvertible) -> Self {
    adding(.equal(field, value))
  }

  public func `where`(_ field: String, isNotEqualTo value: FieldValueConvertible) -> Self {
    adding(.notEqual(field, value))
  }

  public func `where`(_ field: String, isLessThan value: FieldValueConvertible) -> Self {
    adding(.lessThan(field, value))
  }

  public func `where`(_ field: String, isLessThanOrEqualTo value: FieldValueConvertible) -> Self {
    adding(.lessThanOrEqual(field, value))
  }

  public func `where`(_ field: String, isGreaterThan value: FieldValueConvertible) -> Self {
    adding(.greaterThan(field, value))
  }

  public func `where`(_ field: String, isGreaterThanOrEqualTo value: FieldValueConvertible) -> Self
  {
    adding(.greaterThanOrEqual(field, value))
  }

  public func `where`(
    _ field: String, isBetween lower: FieldValueConvertible, and upper: FieldValueConvertible
  ) -> Self {
    adding(.between(field, lower, upper))
  }

  public func `where`(_ field: String, isIn values: [FieldValueConvertible]) -> Self {
    adding(.inSet(field, values))
  }

  public func `where`(_ field: String, isNotIn values: [FieldValueConvertible]) -> Self {
    adding(.notInSet(field, values))
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

  public func whereExists(_ field: String) -> Self {
    adding(.exists(field))
  }

  public func whereNotExists(_ field: String) -> Self {
    adding(.notExists(field))
  }

  public func `where`(_ predicate: Predicate) -> Self {
    adding(predicate)
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

  private func plan() async -> (QueryStrategy, pushedDown: Int) {
    var topLevelPredicates: [Predicate] = []
    if case .and(let arr) = rootPredicate {
      topLevelPredicates = arr
    } else {
      topLevelPredicates = [rootPredicate]
    }

    // 1. Index equality.
    for predicate in topLevelPredicates {
      if case .equal(let field, _) = predicate, await core.isIndexed(field: field) {
        return (.indexLookup(field: field), 1)
      }
    }
    // 2. Index in-set.
    for predicate in topLevelPredicates {
      if case .inSet(let field, _) = predicate, await core.isIndexed(field: field) {
        return (.indexLookup(field: field), 1)
      }
    }
    // 3. Index range / comparison.
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
    // 4. Partition pruning.
    if let partitionKey {
      for predicate in topLevelPredicates {
        if case .equal(let field, let value) = predicate, field == partitionKey {
          return (.partitionScan(value: value.fieldValue.description), 0)
        }
      }
    }
    return (.fullScan, 0)
  }

  public func explain() async -> QueryPlan {
    let (strategy, pushed) = await plan()
    return QueryPlan(strategy: strategy, residualPredicates: topLevelPredicateCount() - pushed)
  }

  private func topLevelPredicateCount() -> Int {
    if case .and(let arr) = rootPredicate { return arr.count }
    return 1
  }

  // MARK: - Execution

  private func candidates() async throws -> [Data] {
    let (strategy, _) = await plan()
    switch strategy {
    case .indexLookup(let field):
      let pointers = await pointers(forIndexedField: field)
      return try await core.fetch(pointers: pointers)
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
            return try await core.scanPartition(value: v.fieldValue)
          }
        }
      }
      return try await core.scanAll()
    case .fullScan:
      return try await core.scanAll()
    }
  }

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

  public func first() async throws -> T? {
    try await limit(1).execute().first
  }

  public func count() async throws -> Int {
    try await matchingDocuments().count
  }

  public func distinctValues(on field: String) async throws -> [FieldValue] {
    let raw = try await candidates()
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
    if offsetCount > 0 && sortField == nil {
      throw NyaruError.unsupportedOperation(
        "Pagination (offset) requires a sort field to guarantee deterministic order.")
    }

    let raw = try await candidates()
    let requiresFullEvaluation = sortField != nil

    var matched: [(dict: [String: Any], json: Data)] = []
    var skipped = 0

    for json in raw {
      guard let dict = try? FieldExtractor.parse(json, using: format) else { continue }

      if Self.evaluate(rootPredicate, in: dict) {
        if requiresFullEvaluation {
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

    if requiresFullEvaluation, let sortField {
      matched.sort { lhs, rhs in
        let a = FieldExtractor.value(in: lhs.dict, path: sortField) ?? .null
        let b = FieldExtractor.value(in: rhs.dict, path: sortField) ?? .null
        return sortAscending ? a < b : b < a
      }

      if offsetCount > 0 {
        matched = offsetCount < matched.count ? Array(matched[offsetCount...]) : []
      }
      if let limitCount, matched.count > limitCount {
        matched = Array(matched.prefix(limitCount))
      }
    }

    return matched
  }

  // MARK: - Predicate evaluation

  private static func comparable(_ a: FieldValue, _ b: FieldValue) -> Bool {
    switch (a, b) {
    case (.int(_), .int(_)), (.double(_), .double(_)), (.string(_), .string(_)),
      (.bool(_), .bool(_)), (.int(_), .double(_)), (.double(_), .int(_)):
      return true
    default:
      return false
    }
  }

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
