import Foundation

/// Binary min-heap of row numbers.
struct MinHeap {
    private var items: [Int32] = []

    mutating func push(_ value: Int32) {
        items.append(value)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child] < items[parent] else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int32? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            siftDown()
        }
        return top
    }

    private mutating func siftDown() {
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left] < items[smallest] { smallest = left }
            if right < items.count, items[right] < items[smallest] { smallest = right }
            if smallest == parent { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
