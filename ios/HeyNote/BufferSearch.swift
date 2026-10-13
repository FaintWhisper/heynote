import Foundation

struct BufferSearchHit: Identifiable, Hashable {
    let bufferID: String
    let bufferName: String
    let blockIndex: Int
    let delimiter: String
    let language: String
    let excerpt: String
    var id: String { "\(bufferID):\(blockIndex)" }
}

struct BufferSearchFailure: Identifiable {
    let id: String
    let message: String
}

struct BufferSearchReport {
    var hits: [BufferSearchHit] = []
    var failures: [BufferSearchFailure] = []
}

struct BufferSearchOverride {
    let id: String
    let data: Data
}

struct LibrarySearchRequest: Hashable {
    let query: String
    let folder: UUID
    let reload: UUID
    let active: Bool
}

struct BufferRoute: Hashable {
    let bufferID: String
    var hit: BufferSearchHit? = nil
    var query: String = ""
}

extension String {
    func bufferMatch(_ query: String) -> Range<String.Index>? {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func searchExcerpt(around match: Range<String.Index>) -> String {
        let start = index(match.lowerBound, offsetBy: -70, limitedBy: startIndex) ?? startIndex
        let end = index(match.upperBound, offsetBy: 150, limitedBy: endIndex) ?? endIndex
        let excerpt = self[start..<end].replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
        return (start == startIndex ? "" : "…") + excerpt + (end == endIndex ? "" : "…")
    }
}
