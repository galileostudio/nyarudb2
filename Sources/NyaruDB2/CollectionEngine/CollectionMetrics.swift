import Foundation

/// A snapshot of one collection's internal counters, returned by
/// `NyaruCollection.metrics()`.
///
/// Counters accumulate from the moment the collection is opened and are
/// never persisted — they are diagnostics for understanding how the engine
/// is being exercised (which access paths queries take, how much I/O the
/// workload generates, whether opens needed crash recovery), not state.
/// Maintaining them costs a handful of integer increments inside calls that
/// already exist; there are no timers or background tasks.
public struct CollectionMetrics: Sendable {
  /// Queries answered through an index probe (point, IN-set, or range).
  public let indexLookups: Int
  /// Queries fully covered by an index — predicates, pagination, and (for
  /// counts) the answer itself came from the index with no residual work.
  public let coveredQueries: Int
  /// Queries that fell back to scanning every shard.
  public let fullScans: Int
  /// Queries served by scanning a single partition shard.
  public let partitionScans: Int
  /// Total bytes read from shard files, including compaction rewrites.
  public let bytesRead: UInt64
  /// Total bytes written to shard files, including compaction rewrites.
  public let bytesWritten: UInt64
  /// Number of `compact()` runs since open.
  public let compactionCount: Int
  /// Wall-clock duration of the most recent `compact()`, if any ran.
  public let lastCompactionDuration: TimeInterval?
  /// How many currently open shards found the dirty flag set at open and
  /// ran crash recovery.
  public let shardsRecoveredFromDirty: Int
}
