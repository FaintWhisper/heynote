import Foundation
import CryptoKit

struct BufferEntry: Identifiable, Hashable {
    let id: String
    let modified: Date?
    let size: Int
    var name: String { ((id as NSString).lastPathComponent as NSString).deletingPathExtension }
    var directory: String { (id as NSString).deletingLastPathComponent }

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

    private func fileURL(_ id: String, in folder: URL) throws -> URL {
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
            let url = try fileURL(id, in: folder)
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

    func search(_ query: String, overriding local: BufferSearchOverride?,
                progress: @Sendable (Int, Int) async -> Void) async throws -> BufferSearchReport {
        let selectedFolder = folder
        var entries = try scan()
        if let local, !entries.contains(where: { $0.id == local.id }) {
            entries.append(BufferEntry(id: local.id, modified: nil, size: local.data.count))
        }
        var report = BufferSearchReport()
        await progress(0, entries.count)
        for (fileIndex, entry) in entries.enumerated() {
            try Task.checkCancellation()
            guard folder == selectedFolder else { throw CancellationError() }
            do {
                let note: NoteDocument
                if let local, local.id == entry.id {
                    note = try NoteDocument(data: local.data)
                } else {
                    note = try read(entry.id).document
                }
                for (index, block) in note.blocks.enumerated() {
                    try Task.checkCancellation()
                    guard let match = block.text.bufferMatch(query) else { continue }
                    report.hits.append(BufferSearchHit(bufferID: entry.id, bufferName: note.title ?? entry.name,
                                                       blockIndex: index, delimiter: block.delimiter, language: block.language,
                                                       excerpt: block.text.searchExcerpt(around: match)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failures.append(BufferSearchFailure(id: entry.id, message: error.localizedDescription))
            }
            await progress(fileIndex + 1, entries.count)
            // Let editing and saves proceed between files instead of retaining
            // the repository actor throughout a large library search.
            await Task.yield()
        }
        try Task.checkCancellation()
        return report
    }

    func write(_ id: String, data: Data, expectedDigest: String?) throws -> String {
        try withFolder { folder in
            let url = try fileURL(id, in: folder)
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
            return try result.get()
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
