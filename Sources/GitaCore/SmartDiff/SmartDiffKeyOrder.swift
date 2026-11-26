/// Stable UTF-8 order with work bounded by the total number of key bytes. Sorting the populated
/// child labels at each radix node costs a constant (at most 256 labels), independent of file count.
enum SmartDiffKeyOrder {
    static func sorted(_ keys: some Collection<String>) -> [String] {
        let names = Array(keys)
        guard names.count > 1 else { return names }
        let bytes = names.map { Array($0.utf8) }
        var work = [(indices: Array(names.indices), depth: 0)]
        var result: [String] = []
        result.reserveCapacity(names.count)
        while let node = work.popLast() {
            if node.indices.count == 1, let index = node.indices.first {
                result.append(names[index])
                continue
            }
            var children: [UInt8: [Int]] = [:]
            for index in node.indices {
                if bytes[index].count == node.depth {
                    result.append(names[index])
                } else {
                    children[bytes[index][node.depth], default: []].append(index)
                }
            }
            for label in children.keys.sorted(by: >) {
                if let indices = children[label] { work.append((indices, node.depth + 1)) }
            }
        }
        return result
    }
}
