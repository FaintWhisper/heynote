import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var buffers: [BufferEntry] = []
    @Published private(set) var document: NoteDocument?
    @Published private(set) var activeID: String?
    @Published private(set) var dirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var isOpening = false
    @Published private(set) var hasConflict = false
    @Published private(set) var cloudConflict = false
    @Published var message: String?

    private let repository = FolderRepository()
    private var baseline = ""
    private var revision = 0
    private var autosave: Task<Void, Never>?
    private var refreshInProgress = false
    private var foreground = true

    var title: String { document?.title ?? activeID.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "HeyNote" }
    var busy: Bool { isSaving || isOpening }
    var saveStatus: String {
        if hasConflict { return "Sync conflict · edits kept on this device" }
        if isSaving { return "Saving…" }
        if dirty { return message == nil ? "Unsaved changes" : "Save paused · tap Save to retry" }
        return "Saved to folder"
    }

    func start() async {
        isOpening = true
        defer { isOpening = false }
        do {
            folderName = try await repository.restore()
            if folderName != nil { buffers = try await repository.scan() }
        } catch { message = error.localizedDescription }
    }

    func connect(_ url: URL) async {
        guard !busy else { return }
        isOpening = true
        defer { isOpening = false }
        await save()
        guard !dirty else { return }
        do {
            folderName = try await repository.connect(url)
            document = nil
            activeID = nil
            buffers = []
            buffers = try await repository.scan()
            message = nil
        } catch { message = error.localizedDescription }
    }

    @discardableResult
    func open(_ id: String) async -> Bool {
        guard !busy else { return false }
        if activeID == id { return true }
        isOpening = true
        defer { isOpening = false }
        await save()
        guard !dirty else { return false }
        do {
            let remote = try await repository.read(id)
            let draft = try await repository.loadDraft(id)
            var loaded = remote.document
            if let draft { loaded = try NoteDocument(data: draft.content) }
            autosave?.cancel()
            document = loaded
            activeID = id
            baseline = draft?.baseline ?? remote.digest
            revision = 0
            dirty = draft != nil
            cloudConflict = remote.hasCloudConflict
            hasConflict = remote.hasCloudConflict || (draft != nil && draft?.baseline != remote.digest)
            message = hasConflict ? NoteError.changedOnDisk.localizedDescription : (draft != nil ? "Recovered unsaved edits from this device." : nil)
            if cloudConflict { message = NoteError.cloudConflict.localizedDescription }
            if dirty && !hasConflict { scheduleSave() }
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func text(for id: UUID) -> String {
        document?.blocks.first(where: { $0.id == id })?.text ?? ""
    }

    func updateText(_ text: String, id: UUID) {
        guard let index = document?.blocks.firstIndex(where: { $0.id == id }), document?.blocks[index].text != text else { return }
        document?.blocks[index].text = text
        edited()
    }

    func setLanguage(_ language: String, id: UUID) {
        guard let index = document?.blocks.firstIndex(where: { $0.id == id }) else { return }
        document?.blocks[index].setLanguage(language)
        edited()
    }

    func addBlock() -> UUID? {
        guard document != nil else { return nil }
        let id = document?.addBlock()
        edited()
        return id
    }

    private func edited() {
        revision += 1
        dirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                try await self.persistDraft()
                try await Task.sleep(nanoseconds: 700_000_000)
                if !self.hasConflict { await self.save() }
            } catch is CancellationError {
                // A newer edit owns the next save.
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    private func persistDraft() async throws {
        guard dirty, let id = activeID, let document else { return }
        let draft = RecoveryDraft(id: id, baseline: baseline, content: try document.data(forSaving: false))
        try await repository.keepDraft(draft)
    }

    func save() async {
        guard dirty, !isSaving, !hasConflict, let id = activeID, let captured = document else { return }
        let capturedRevision = revision
        let expected = baseline
        isSaving = true
        defer { isSaving = false }
        do {
            // Persist locally before asking the file provider to write anything.
            try await repository.keepDraft(RecoveryDraft(id: id, baseline: expected, content: try captured.data(forSaving: false)))
            let data = try captured.data(forSaving: true)
            let digest = try await repository.write(id, data: data, expectedDigest: expected)
            baseline = digest
            if revision == capturedRevision {
                dirty = false
                // If cleanup fails, this draft still references the committed version.
                try await repository.keepDraft(RecoveryDraft(id: id, baseline: digest, content: data))
                try await repository.removeDraft(id)
            } else {
                try await persistDraft()
                scheduleSave()
            }
            message = nil
        } catch {
            if let noteError = error as? NoteError {
                switch noteError {
                case .changedOnDisk: hasConflict = true
                case .cloudConflict: hasConflict = true; cloudConflict = true
                default: break
                }
            }
            message = error.localizedDescription
        }
    }

    func refresh() async {
        guard folderName != nil, foreground, !busy, !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        do {
            buffers = try await repository.scan()
            guard !busy, let id = activeID, let previous = document else { return }
            let expectedBaseline = baseline
            let remote = try await repository.read(id)
            // A save may have started while the provider was returning a file.
            guard !busy, activeID == id, baseline == expectedBaseline else { return }
            if remote.hasCloudConflict {
                cloudConflict = true
                hasConflict = true
                message = NoteError.cloudConflict.localizedDescription
            } else if remote.digest != baseline {
                if dirty || hasConflict {
                    hasConflict = true
                    message = NoteError.changedOnDisk.localizedDescription
                } else {
                    var updated = remote.document
                    updated.preserveBlockIDs(from: previous)
                    document = updated
                    baseline = remote.digest
                }
            }
        } catch { message = error.localizedDescription }
    }

    func useCloudVersion() async {
        guard !busy, let id = activeID, !cloudConflict else { return }
        isOpening = true
        defer { isOpening = false }
        autosave?.cancel()
        do {
            let remote = try await repository.read(id)
            guard !remote.hasCloudConflict else { throw NoteError.cloudConflict }
            try await repository.removeDraft(id)
            document = remote.document
            baseline = remote.digest
            dirty = false
            hasConflict = false
            cloudConflict = false
            revision += 1
            message = nil
        } catch { message = error.localizedDescription }
    }

    @discardableResult
    func saveCopy() async -> Bool {
        guard !busy, let oldID = activeID, var copy = document else { return false }
        isOpening = true
        defer { isOpening = false }
        autosave?.cancel()
        do {
            let stem = (oldID as NSString).deletingPathExtension
            let id = stem + "-ios-copy-" + UUID().uuidString.prefix(8).lowercased() + ".txt"
            copy.rename(title + " (iOS copy)")
            let data = try copy.data(forSaving: true)
            let digest = try await repository.write(id, data: data, expectedDigest: nil)
            // Keep the original draft until the new file has been committed.
            try await repository.removeDraft(oldID)
            activeID = id
            document = copy
            baseline = digest
            dirty = false
            hasConflict = false
            cloudConflict = false
            buffers = try await repository.scan()
            message = "Saved your edits as a separate buffer."
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func create(name: String) async -> Bool {
        guard !busy else { return false }
        isOpening = true
        defer { isOpening = false }
        await save()
        guard !dirty else { return false }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw NoteError.invalidFormat("enter a buffer name.") }
            let slug = trimmed.replacingOccurrences(of: #"[^\p{L}\p{N}_-]+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !slug.isEmpty, slug.utf8.count <= 160 else { throw NoteError.invalidFormat("choose a shorter buffer name containing letters or numbers.") }
            let id = slug.lowercased() + ".txt"
            let new = NoteDocument(name: trimmed)
            let digest = try await repository.write(id, data: new.data(forSaving: true), expectedDigest: nil)
            activeID = id
            document = new
            baseline = digest
            revision = 0
            dirty = false
            hasConflict = false
            cloudConflict = false
            buffers = try await repository.scan()
            message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func sceneChanged(_ phase: ScenePhase) async {
        foreground = phase == .active
        if foreground {
            await refresh()
        } else {
            let token = UIApplication.shared.beginBackgroundTask(withName: "Save HeyNote edits")
            do { try await persistDraft() }
            catch { message = "Could not keep a recovery draft: \(error.localizedDescription)" }
            await save()
            if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
        }
    }
}
