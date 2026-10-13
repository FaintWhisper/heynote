import Foundation
import CryptoKit

struct BufferEntry: Identifiable, Hashable, Sendable {
    let id: String
    let modified: Date?
    let size: Int
    var name: String { ((id as NSString).lastPathComponent as NSString).deletingPathExtension }
    var directory: String { (id as NSString).deletingLastPathComponent }
    var searchStamp: BufferSearchStamp? {
        modified.map { BufferSearchStamp(modified: $0, size: size) }
    }

    static func precedes(_ first: BufferEntry, _ second: BufferEntry, oldestFirst: Bool) -> Bool {
        switch (first.modified, second.modified) {
        case let (left?, right?) where left != right:
            return oldestFirst ? left < right : left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let comparison = first.id.localizedStandardCompare(second.id)
            if comparison == .orderedSame {
                return oldestFirst ? first.id < second.id : first.id > second.id
            }
            return oldestFirst ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}

struct BufferSnapshot {
    let id: String
    let document: NoteDocument
    let digest: String
    let hasCloudConflict: Bool
}

struct RecoveryDraft: Codable {
    let id: String
    let baseline: String
    let content: Data
}

actor FolderRepository {
    private var folder: URL?
    private let bookmarkKey = "HeyNote.selectedFolder.v1"
    private let manager = FileManager.default
    private var searchCache: [String: BufferSearchCacheEntry] = [:]
    private var searchCacheCost = 0
    private var searchCacheClock: UInt64 = 0
    private var searchCacheGeneration = UUID()
    private let searchCacheBudget = 32 * 1024 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func restore() throws -> String? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return try connect(url)
    }

    func connect(_ url: URL) throws -> String {
        guard url.startAccessingSecurityScopedResource() else { throw NoteError.permission }
        defer { url.stopAccessingSecurityScopedResource() }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw NoteError.invalidPath }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        clearSearchCache()
        folder = url
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return url.lastPathComponent
    }

    private func withFolder<T>(_ action: (URL) throws -> T) throws -> T {
        guard let folder else { throw NoteError.noFolder }
        guard folder.startAccessingSecurityScopedResource() else { throw NoteError.permission }
        defer { folder.stopAccessingSecurityScopedResource() }
        return try action(folder)
    }

    nonisolated static func bufferURL(_ id: String, in folder: URL) throws -> URL {
        let components = id.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }),
              !id.contains("\\"), id.lowercased().hasSuffix(".txt") else { throw NoteError.invalidPath }
        let url = folder.appendingPathComponent(id).standardizedFileURL
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedFolder) else { throw NoteError.invalidPath }
        return url
    }

    func scan() throws -> [BufferEntry] {
        try withFolder { folder in
            var entries: [BufferEntry] = []
            var coordinationError: NSError?
            var accessError: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { root in
                do {
                    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
                    var enumerationError: Error?
                    guard let files = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }) else { throw NoteError.coordination }
                    for case let url as URL in files {
                        let values = try url.resourceValues(forKeys: keys)
                        if values.isSymbolicLink == true { files.skipDescendants(); continue }
                        guard url.pathExtension.lowercased() == "txt", values.isRegularFile == true else { continue }
                        let relative = String(url.path.dropFirst(root.path.count + 1))
                        entries.append(BufferEntry(id: relative, modified: values.contentModificationDate, size: values.fileSize ?? 0))
                    }
                    if let enumerationError { throw enumerationError }
                } catch { accessError = error }
            }
            if let coordinationError { throw coordinationError }
            if let accessError { throw accessError }
            return entries.sorted { BufferEntry.precedes($0, $1, oldestFirst: true) }
        }
    }

    func read(_ id: String) throws -> BufferSnapshot {
        try withFolder { folder in
            let url = try Self.bufferURL(id, in: folder)
            var result: Result<BufferSnapshot, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    let data = try Data(contentsOf: coordinated)
                    return BufferSnapshot(id: id, document: try NoteDocument(data: data), digest: Self.digest(data),
                                          hasCloudConflict: NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated)?.isEmpty == false)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw NoteError.coordination }
            return try result.get()
        }
    }

    func clearSearchCache() {
        searchCache.removeAll()
        searchCacheCost = 0
        searchCacheGeneration = UUID()
    }

    private func evictSearchIndex(_ id: String) {
        if let removed = searchCache.removeValue(forKey: id) { searchCacheCost -= removed.index.cost }
    }

    private func cacheSearchIndex(_ index: BufferSearchIndex, entry: BufferEntry) {
        guard let stamp = entry.searchStamp, index.sourceBytes == entry.size, index.cost <= searchCacheBudget else { return }
        evictSearchIndex(entry.id)
        while searchCacheCost + index.cost > searchCacheBudget,
              let oldest = searchCache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            evictSearchIndex(oldest)
        }
        searchCacheClock &+= 1
        searchCache[entry.id] = BufferSearchCacheEntry(stamp: stamp, index: index, lastUse: searchCacheClock)
        searchCacheCost += index.cost
    }

    func search(_ query: String, overriding local: BufferSearchOverride?,
                progress: @Sendable (Int, Int, BufferSearchReport) async -> Void) async throws -> BufferSearchReport {
        try Task.checkCancellation()
        guard let selectedFolder = folder else { throw NoteError.noFolder }
        var entries = try scan()
        if let local, !entries.contains(where: { $0.id == local.id }) {
            entries.append(BufferEntry(id: local.id, modified: nil, size: local.data.count))
        }
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let validIDs = Set(entriesByID.keys)
        for id in Array(searchCache.keys) where !validIDs.contains(id) { evictSearchIndex(id) }
        let generation = searchCacheGeneration
        let jobs = entries.map { entry -> BufferSearchJob in
            let cached = searchCache[entry.id]
            let sameVersion = entry.searchStamp != nil && cached?.stamp == entry.searchStamp
            if !sameVersion { evictSearchIndex(entry.id) }
            let localData = local?.id == entry.id ? local?.data : nil
            return BufferSearchJob(entry: entry, folder: selectedFolder,
                                   cached: localData == nil && sameVersion ? cached?.index : nil, local: localData)
        }
        let largest = entries.map(\.size).max() ?? 0
        let memoryLimit = largest > 32 * 1024 * 1024 ? 1 : (largest > 16 * 1024 * 1024 ? 2 : 4)
        let concurrency = min(memoryLimit, max(1, ProcessInfo.processInfo.activeProcessorCount))
        var report = BufferSearchReport()
        await progress(0, entries.count, report)
        try Task.checkCancellation()
        guard folder == selectedFolder, searchCacheGeneration == generation else { throw CancellationError() }
        return try await withThrowingTaskGroup(of: BufferSearchFileResult.self) { group in
            var nextJob = 0
            for _ in 0..<min(concurrency, jobs.count) {
                let job = jobs[nextJob]
                nextJob += 1
                group.addTask { try await BufferSearchWorker.run(job, query: query) }
            }
            var completed = 0
            while let result = try await group.next() {
                try Task.checkCancellation()
                guard folder == selectedFolder, searchCacheGeneration == generation else {
                    group.cancelAll()
                    throw CancellationError()
                }
                if let index = result.index, result.id != local?.id,
                   let entry = entriesByID[result.id] {
                    cacheSearchIndex(index, entry: entry)
                }
                report.hits.append(contentsOf: result.report.hits)
                report.failures.append(contentsOf: result.report.failures)
                completed += 1
                await progress(completed, entries.count, report)
                if nextJob < jobs.count {
                    let job = jobs[nextJob]
                    nextJob += 1
                    group.addTaskUnlessCancelled { try await BufferSearchWorker.run(job, query: query) }
                }
            }
            try Task.checkCancellation()
            guard folder == selectedFolder, searchCacheGeneration == generation else { throw CancellationError() }
            return report
        }
    }

    func write(_ id: String, data: Data, expectedDigest: String?) throws -> String {
        try withFolder { folder in
            let url = try Self.bufferURL(id, in: folder)
            var result: Result<String, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
                result = Result {
                    if let expectedDigest {
                        guard manager.fileExists(atPath: coordinated.path) else { throw NoteError.changedOnDisk }
                        guard Self.digest(try Data(contentsOf: coordinated)) == expectedDigest else { throw NoteError.changedOnDisk }
                        if NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated)?.isEmpty == false { throw NoteError.cloudConflict }
                    } else if manager.fileExists(atPath: coordinated.path) {
                        throw NoteError.alreadyExists
                    }
                    try data.write(to: coordinated, options: .atomic)
                    return Self.digest(data)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw NoteError.coordination }
            let digest = try result.get()
            evictSearchIndex(id)
            searchCacheGeneration = UUID()
            return digest
        }
    }

    private func draftURL(_ id: String) throws -> URL {
        guard let folder else { throw NoteError.noFolder }
        let directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = Self.digest(Data((folder.standardizedFileURL.path + "\n" + id).utf8))
        return directory.appendingPathComponent(key + ".json")
    }

    func keepDraft(_ draft: RecoveryDraft) throws {
        try JSONEncoder().encode(draft).write(to: draftURL(draft.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadDraft(_ id: String) throws -> RecoveryDraft? {
        let url = try draftURL(id)
        guard manager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RecoveryDraft.self, from: Data(contentsOf: url))
    }

    func removeDraft(_ id: String) throws {
        let url = try draftURL(id)
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    }
}
