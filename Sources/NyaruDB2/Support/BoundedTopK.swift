import Foundation

/// Keeps the first K elements of a sort order while streaming over an
/// arbitrarily large input, in O(K) memory and O(log K) per insert.
///
/// Backed by a binary max-heap relative to `areInIncreasingOrder`: the root
/// is the worst element retained so far and is evicted when a better one
/// arrives. Used by the query engine for `sort + limit` — with `limit(10)`
/// over 100k matches, sorting everything does five orders of magnitude more
/// comparisons than selecting the top 10.
///
/// Ties are not kept in arrival order (heap selection is not stable); the
/// query API makes no ordering promise between equal sort keys.
struct BoundedTopK<Element> {
  private var heap: [Element] = []
  private let k: Int
  private let less: (Element, Element) -> Bool

  init(k: Int, areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
    self.k = max(0, k)
    self.less = areInIncreasingOrder
    heap.reserveCapacity(self.k)
  }

  mutating func insert(_ element: Element) {
    guard k > 0 else { return }
    if heap.count < k {
      heap.append(element)
      siftUp(from: heap.count - 1)
    } else if less(element, heap[0]) {
      heap[0] = element
      siftDown(from: 0)
    }
  }

  /// The retained elements, in sort order.
  func sorted() -> [Element] { heap.sorted(by: less) }

  private mutating func siftUp(from index: Int) {
    var child = index
    while child > 0 {
      let parent = (child - 1) / 2
      guard less(heap[parent], heap[child]) else { return }
      heap.swapAt(parent, child)
      child = parent
    }
  }

  private mutating func siftDown(from index: Int) {
    var parent = index
    while true {
      var largest = parent
      let left = 2 * parent + 1
      let right = left + 1
      if left < heap.count && less(heap[largest], heap[left]) { largest = left }
      if right < heap.count && less(heap[largest], heap[right]) { largest = right }
      if largest == parent { return }
      heap.swapAt(parent, largest)
      parent = largest
    }
  }
}
