import Foundation

struct BufferSearchHit: Identifiable, Hashable, Sendable {
    let bufferID: String
    let bufferName: String
    let blockIndex: Int
    let delimiter: String
    let language: String
    let excerpt: String
    var id: String { "\(bufferID):\(blockIndex)" }
}

struct BufferSearchFailure: Identifiable, Sendable {
    let id: String
    let message: String
}

struct BufferSearchReport: Sendable {
    var hits: [BufferSearchHit] = []
    var failures: [BufferSearchFailure] = []
}

struct BufferSearchOverride: Sendable {
    let id: String
    let data: Data
}

struct BufferSearchStamp: Equatable, Sendable {
    let modified: Date
    let size: Int
}

struct BufferSearchIndex: Sendable {
    let name: String
    let blocks: [NoteBlock]
    let sourceBytes: Int
    var cost: Int { sourceBytes * 2 + blocks.count * 256 }

    init(data: Data, defaultName: String) throws {
        let note = try NoteDocument(data: data)
        name = note.title ?? defaultName
        blocks = note.blocks
        sourceBytes = data.count
    }
}

struct BufferSearchCacheEntry {
    let stamp: BufferSearchStamp
    let index: BufferSearchIndex
    var lastUse: UInt64
}

struct BufferSearchJob: Sendable {
    let entry: BufferEntry
    let folder: URL
    let cached: BufferSearchIndex?
    let local: Data?
}

struct BufferSearchFileResult: Sendable {
    let id: String
    let index: BufferSearchIndex?
    let report: BufferSearchReport
}

enum BufferSearchWorker {
    static let maximumFileSize = 64 * 1024 * 1024
    static let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.faintwhisper.heynote.search"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    static func run(_ job: BufferSearchJob, query: String?) async throws -> BufferSearchFileResult {
        try Task.checkCancellation()
        do {
            let index: BufferSearchIndex
            if let cached = job.cached {
                index = cached
            } else if let local = job.local {
                index = try BufferSearchIndex(data: local, defaultName: job.entry.name)
            } else {
                guard job.folder.startAccessingSecurityScopedResource() else { throw NoteError.permission }
                defer { job.folder.stopAccessingSecurityScopedResource() }
                let url = try FolderRepository.bufferURL(job.entry.id, in: job.folder)
                let data = try await BufferSearchRead().read(url)
                try Task.checkCancellation()
                index = try BufferSearchIndex(data: data, defaultName: job.entry.name)
            }
            var report = BufferSearchReport()
            guard let query else {
                return BufferSearchFileResult(id: job.entry.id, index: index, report: report)
            }
            for (blockIndex, block) in index.blocks.enumerated() {
                try Task.checkCancellation()
                if blockIndex % 32 == 0 { await Task.yield() }
                guard let match = block.text.bufferMatch(query) else { continue }
                report.hits.append(BufferSearchHit(bufferID: job.entry.id, bufferName: index.name,
                                                   blockIndex: blockIndex, delimiter: block.delimiter, language: block.language,
                                                   excerpt: block.text.searchExcerpt(around: match)))
            }
            try Task.checkCancellation()
            return BufferSearchFileResult(id: job.entry.id, index: index, report: report)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            var report = BufferSearchReport()
            report.failures.append(BufferSearchFailure(id: job.entry.id, message: error.localizedDescription))
            return BufferSearchFileResult(id: job.entry.id, index: nil, report: report)
        }
    }
}

// The lock protects registration/cancellation. NSFileCoordinator explicitly
// permits cancel() from any thread; all file access stays inside its accessor.
private final class BufferSearchRead: @unchecked Sendable {
    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        coordinator.cancel()
    }

    func read(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(url, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ url: URL, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [])
        coordinator.coordinate(with: [intent], queue: BufferSearchWorker.readQueue) { error in
            let result = Result<Data, Error> {
                guard !self.isCancelled else { throw CancellationError() }
                if let error { throw error }
                let size = try intent.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BufferSearchWorker.maximumFileSize else { throw NoteError.tooLarge }
                let data = try Data(contentsOf: intent.url)
                guard !self.isCancelled else { throw CancellationError() }
                return data
            }
            continuation.resume(with: result)
        }
        lock.unlock()
    }
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
