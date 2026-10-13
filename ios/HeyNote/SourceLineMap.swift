import Foundation

struct SourceLineMap {
    let starts: [Int]
    let length: Int

    init(_ text: String) {
        let units = Array(text.utf16)
        var offsets = [0]
        for index in units.indices {
            if units[index] == 10 || (units[index] == 13 && (index + 1 == units.count || units[index + 1] != 10)) {
                offsets.append(index + 1)
            }
        }
        starts = offsets
        length = units.count
    }

    func line(at offset: Int) -> Double {
        let position = min(max(offset, 0), length)
        var low = 0
        var high = starts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle } else { high = middle }
        }
        let end = low + 1 < starts.count ? starts[low + 1] : length
        return Double(low + 1) + Double(position - starts[low]) / Double(max(1, end - starts[low]))
    }

    func offset(at line: Double) -> Int {
        let index = min(max(Int(line.rounded(.down)) - 1, 0), starts.count - 1)
        let end = index + 1 < starts.count ? starts[index + 1] : length
        let fraction = min(max(line - Double(index + 1), 0), 1)
        return min(length, starts[index] + Int(Double(end - starts[index]) * fraction))
    }

    func range(of line: Int) -> NSRange? {
        guard line > 0, line <= starts.count else { return nil }
        let index = line - 1
        let end = index + 1 < starts.count ? starts[index + 1] : length
        return NSRange(location: starts[index], length: end - starts[index])
    }
}
