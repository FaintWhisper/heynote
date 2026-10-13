import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct HeyNoteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .environmentObject(model)
                .tint(Color(red: 0.16, green: 0.58, blue: 0.42))
                .onChange(of: phase) { value in
                    Task { await model.sceneChanged(value) }
                }
        }
    }
}

private struct LibraryScreen: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("HeyNote.buffersOldestFirst.v2") private var oldestFirst = false
    @AppStorage("HeyNote.blocksLastFirst.v1") private var blocksLastFirst = true
    @State private var path: [BufferRoute] = []
    @State private var search = ""
    @State private var chooseFolder = false
    @State private var newBuffer = false
    @State private var name = ""
    @State private var searchReload = UUID()

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var orderedBuffers: [BufferEntry] {
        model.buffers.sorted { BufferEntry.precedes($0, $1, oldestFirst: oldestFirst) }
    }

    private var filtered: [BufferEntry] {
        orderedBuffers.filter { query.isEmpty || $0.id.bufferMatch(query) != nil }
    }

    private var orderedHits: [BufferSearchHit] {
        let positions = Dictionary(uniqueKeysWithValues: orderedBuffers.enumerated().map { ($0.element.id, $0.offset) })
        return model.searchHits.sorted {
            if $0.bufferID == $1.bufferID {
                return blocksLastFirst ? $0.blockIndex > $1.blockIndex : $0.blockIndex < $1.blockIndex
            }
            let left = positions[$0.bufferID] ?? Int.max
            let right = positions[$1.bufferID] ?? Int.max
            if left != right { return left < right }
            return $0.bufferID.localizedStandardCompare($1.bufferID) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                MessageBanner()
                if model.folderName == nil {
                    welcome
                } else {
                    library
                }
            }
            .navigationTitle("HeyNote")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { chooseFolder = true } label: { Image(systemName: "folder") }
                        .accessibilityLabel("Choose HeyNote folder")
                        .disabled(model.busy)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("File modification date", selection: $oldestFirst) {
                            Text("Oldest modified first").tag(true)
                            Text("Newest modified first").tag(false)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel("Sort buffers by file modification date")
                        .disabled(model.folderName == nil)
                    if model.isOpening {
                        ProgressView()
                    } else {
                        Button { name = ""; newBuffer = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New scratchbuffer")
                            .disabled(model.folderName == nil || model.busy)
                    }
                }
            }
            .navigationDestination(for: BufferRoute.self) { route in
                BufferScreen(initialHit: route.hit, initialQuery: route.query)
            }
            .sheet(isPresented: $chooseFolder) {
                FolderPicker { url in Task { await model.connect(url) } }
            }
            .alert("New scratchbuffer", isPresented: $newBuffer) {
                TextField("Buffer name", text: $name)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    Task {
                        if await model.create(name: name), let id = model.activeID { path.append(BufferRoute(bufferID: id)) }
                    }
                }
            } message: {
                Text("Creates a HeyNote .txt buffer in the selected folder.")
            }
        }
        .task(id: LibrarySearchRequest(query: search, folder: model.folderVersion, reload: searchReload, active: path.isEmpty)) {
            guard path.isEmpty else { return }
            await model.searchAll(search)
        }
        .task {
            await model.start()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                catch { break }
                await model.refresh()
            }
        }
    }

    private var library: some View {
        Group {
            if query.isEmpty { bufferList }
            else { searchResults }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search names and contents")
        .refreshable {
            await model.refreshSearch()
            searchReload = UUID()
        }
    }

    private var bufferList: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "folder.badge.gearshape")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.folderName ?? "HeyNote").font(.headline)
                        Text("\(model.buffers.count) buffers · sync managed by Files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            if model.dirty, let id = model.activeID {
                Section {
                    Button { path.append(BufferRoute(bufferID: id)) } label: {
                        Label("Return to unsaved edits", systemImage: "pencil.circle")
                    }
                }
            }
            Section("Scratchbuffers · \(oldestFirst ? "oldest first" : "newest first")") {
                ForEach(orderedBuffers) { entry in bufferRow(entry) }
                if model.buffers.isEmpty {
                    Text("No .txt buffers in this folder.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bufferRow(_ entry: BufferEntry) -> some View {
        Button {
            Task {
                if await model.open(entry.id) { path.append(BufferRoute(bufferID: entry.id)) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).foregroundStyle(.primary)
                    if !entry.directory.isEmpty {
                        Text(entry.directory).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    if let modified = entry.modified {
                        Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Modification date unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 4)
        }.disabled(model.busy)
    }

    private var searchResults: some View {
        List {
            Section {
                if model.isSearching || model.searchQuery != query {
                    HStack {
                        ProgressView()
                        Text(model.searchFileCount == 0 ? "Searching all buffers…" : "Searching \(model.searchedFiles) of \(model.searchFileCount) buffers…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if let error = model.searchError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
                } else {
                    Text("\(model.searchHits.count) matching blocks in \(Set(model.searchHits.map(\.bufferID)).count) buffers")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !filtered.isEmpty {
                Section("Buffer names") {
                    ForEach(filtered) { entry in bufferRow(entry) }
                }
            }
            if model.searchQuery == query {
                Section("Content matches") {
                    ForEach(orderedHits) { hit in searchRow(hit) }
                    if model.searchHits.isEmpty, !model.isSearching, model.searchError == nil {
                        Text(model.searchFailures.isEmpty ? "No matching block content." : "No matches in the buffers that could be searched.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.searchFailures.isEmpty {
                    Section("Could not search \(model.searchFailures.count) buffers") {
                        ForEach(model.searchFailures) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.id).font(.subheadline)
                                Text(failure.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func searchRow(_ hit: BufferSearchHit) -> some View {
        Button {
            let matchedQuery = model.searchQuery
            Task {
                if await model.open(hit.bufferID) {
                    path.append(BufferRoute(bufferID: hit.bufferID, hit: hit, query: matchedQuery))
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(hit.bufferName).font(.subheadline.bold())
                    Spacer()
                    Text("Block \(hit.blockIndex + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(hit.excerpt).font(.system(.subheadline, design: .monospaced)).lineLimit(3)
                Text("\(hit.bufferID) · \(hit.language)").font(.caption).foregroundStyle(.secondary)
            }.foregroundStyle(.primary).padding(.vertical, 4)
        }.disabled(model.busy)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.and.pencil").font(.system(size: 54, weight: .light)).foregroundStyle(.tint)
            Text("Your scratchpad, everywhere.").font(.title2.bold())
            Text("Choose the HeyNote folder under iCloud Drive in Files. Your existing buffers stay in the same folder and sync with HeyNote on your computer.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Choose HeyNote folder") { chooseFolder = true }
                .buttonStyle(.borderedProminent).disabled(model.busy)
            Text("Use the same Apple Account on this device and your computer. Changes sync when iCloud Drive is available.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Text("HeyNote by Jonatan Heyman · iOS companion")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
    }
}

private struct MessageBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let message = model.message {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.hasConflict ? "exclamationmark.icloud" : "info.circle")
                Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.message = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss message")
            }
            .padding(14)
            .background(Color.secondary.opacity(0.12))
        }
    }
}

private struct BlockSelection: Identifiable {
    let id: UUID
    var query: String = ""
}

private struct BlockFramesPreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct BufferScreen: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("HeyNote.blocksLastFirst.v1") private var blocksLastFirst = true
    let initialHit: BufferSearchHit?
    let initialQuery: String
    @State private var search = ""
    @State private var selection: BlockSelection?
    @State private var discardEdits = false
    @State private var panelPosition: UUID?
    @State private var openedInitialHit = false

    private var blocks: [(Int, NoteBlock)] {
        let matching: [(Int, NoteBlock)] = (model.document?.blocks ?? []).enumerated().compactMap { index, block in
            search.isEmpty || block.text.bufferMatch(search) != nil || block.language.bufferMatch(search) != nil
                ? (index + 1, block) : nil
        }
        return blocksLastFirst ? Array(matching.reversed()) : matching
    }

    var body: some View {
        VStack(spacing: 0) {
            MessageBanner()
            if model.hasConflict {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This buffer has another version.").font(.headline)
                    Text("Keep this device's edits in a new buffer, or discard them and load the current file from iCloud Drive.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save my edits as a new buffer") { Task { await model.saveCopy() } }
                        .buttonStyle(.borderedProminent)
                    Button("Use iCloud version…") { discardEdits = true }
                        .disabled(model.cloudConflict)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            blockPanel
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                BlockSortMenu()
                    .disabled(model.document == nil || model.isOpening)
                Button { Task { await model.save() } } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Save buffer")
                    .disabled(!model.dirty || model.busy || model.hasConflict)
                Button {
                    if let id = model.addBlock() { selection = BlockSelection(id: id) }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add block").disabled(model.isOpening)
            }
        }
        .sheet(item: $selection, onDismiss: { Task { await model.save() } }) { item in
            BlockEditor(id: item.id, query: item.query)
        }
        .alert("Discard this device's edits?", isPresented: $discardEdits) {
            Button("Cancel", role: .cancel) { }
            Button("Load iCloud version", role: .destructive) { Task { await model.useCloudVersion() } }
        } message: {
            Text("The unsaved edits on this device will be removed. The current buffer in iCloud Drive will be opened.")
        }
        .task {
            guard !openedInitialHit else { return }
            openedInitialHit = true
            guard let hit = initialHit, let note = model.document else { return }
            let candidates = note.blocks.enumerated().filter {
                $0.element.delimiter == hit.delimiter && $0.element.text.bufferMatch(initialQuery) != nil
            }
            let match = candidates.first(where: { $0.offset == hit.blockIndex }) ?? (candidates.count == 1 ? candidates.first : nil)
            if let match {
                panelPosition = match.element.id
                selection = BlockSelection(id: match.element.id, query: initialQuery)
            } else {
                model.message = "This search result changed in iCloud Drive. Search again to find its current block."
            }
        }
        .onDisappear { Task { await model.save() } }
    }

    private var panelLabel: String {
        guard let entry = blocks.first(where: { $0.1.id == panelPosition }) ?? blocks.first else { return "No blocks" }
        return "Block \(entry.0) of \(model.document?.blocks.count ?? 0)"
    }

    private func movePanel(_ direction: Int, toEnd: Bool, proxy: ScrollViewProxy) {
        let visible = blocks
        guard !model.isOpening, !visible.isEmpty else { return }
        let index = visible.firstIndex(where: { $0.1.id == panelPosition }) ?? 0
        let target = toEnd ? (direction < 0 ? 0 : visible.count - 1) : min(max(index + direction, 0), visible.count - 1)
        let id = visible[target].1.id
        panelPosition = id
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: toEnd && direction > 0 ? .bottom : .top)
        }
    }

    private var blockPanel: some View {
        let visible = blocks
        return ScrollViewReader { proxy in
            GeometryReader { viewport in
                List {
                    Section {
                        ForEach(visible, id: \.1.id) { index, block in
                            blockRow(index, block: block)
                                .id(block.id)
                                .background(GeometryReader { row in
                                    Color.clear.preference(key: BlockFramesPreference.self,
                                                           value: [block.id: row.frame(in: .named("blockPanel"))])
                                })
                        }
                        if visible.isEmpty { Text("No matching blocks.").foregroundStyle(.secondary) }
                    } header: {
                        Text("\(model.document?.blocks.count ?? 0) blocks · \(blocksLastFirst ? "last to first" : "first to last")")
                    } footer: {
                        Text("Tap a block to edit. Hold an arrow to jump to the start or end.")
                    }
                }
                .coordinateSpace(name: "blockPanel")
                .onPreferenceChange(BlockFramesPreference.self) { frames in
                    let first = visible.first { _, block in
                        guard let frame = frames[block.id] else { return false }
                        return frame.maxY > 0 && frame.minY < viewport.size.height
                    }?.1.id
                    if let first, panelPosition != first { panelPosition = first }
                }
                .onChange(of: search) { _ in
                    panelPosition = visible.first?.1.id
                    if let id = panelPosition { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: blocksLastFirst) { _ in
                    panelPosition = visible.first?.1.id
                    if let id = panelPosition { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: selection?.id) { id in
                    if let id, visible.contains(where: { $0.1.id == id }) { proxy.scrollTo(id, anchor: .top) }
                }
                .searchable(text: $search, prompt: "Search block content")
                .refreshable { await model.refresh() }
                .safeAreaInset(edge: .bottom) {
                    BlockNavigationBar(position: panelLabel, enabled: !visible.isEmpty && !model.isOpening,
                                       previous: { movePanel(-1, toEnd: false, proxy: proxy) },
                                       next: { movePanel(1, toEnd: false, proxy: proxy) },
                                       first: { movePanel(-1, toEnd: true, proxy: proxy) },
                                       last: { movePanel(1, toEnd: true, proxy: proxy) })
                }
            }
        }
    }

    private func blockRow(_ index: Int, block: NoteBlock) -> some View {
        Button { selection = BlockSelection(id: block.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(block.language.uppercased()).font(.caption2.monospaced().bold()).foregroundStyle(.tint)
                    Spacer()
                    Text("\(index)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(block.preview).font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 6)
        }
    }
}

private struct BlockEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("HeyNote.blocksLastFirst.v1") private var blocksLastFirst = true
    @State private var currentID: UUID
    @State private var scrollRequest: EditorScrollRequest?
    private let languages = ["text", "markdown", "math", "javascript", "jsx", "typescript", "tsx", "json", "python", "html", "css", "sql", "xml", "yaml", "toml", "shell", "powershell", "swift", "rust", "cpp", "csharp", "java", "golang", "ruby", "php", "clojure", "elixir", "erlang", "kotlin", "lua", "groovy", "diff", "vue", "dart", "scala", "mermaid", "lezer"]
    private var block: NoteBlock? { model.document?.blocks.first(where: { $0.id == currentID }) }
    private var blockIndex: Int? { model.document?.blocks.firstIndex(where: { $0.id == currentID }) }

    init(id: UUID, query: String = "") {
        _currentID = State(initialValue: id)
        _scrollRequest = State(initialValue: query.isEmpty ? nil : EditorScrollRequest(target: .match(query)))
    }

    private var editor: some View {
        // Capture the displayed ID so a delegate callback during a transition
        // always belongs to the block whose text was in the native editor.
        let id = currentID
        return NativeTextEditor(text: Binding(get: { model.text(for: id) }, set: { model.updateText($0, id: id) }),
                                blockID: id, scrollRequest: scrollRequest)
            .disabled(model.isOpening)
    }

    private func navigate(_ direction: Int, toEnd: Bool) {
        guard !model.isOpening, let source = model.document?.blocks else { return }
        let blocks = blocksLastFirst ? Array(source.reversed()) : source
        guard let index = blocks.firstIndex(where: { $0.id == currentID }), !blocks.isEmpty else { return }
        let target = toEnd ? (direction < 0 ? 0 : blocks.count - 1) : min(max(index + direction, 0), blocks.count - 1)
        guard target != index || toEnd else { return }
        currentID = blocks[target].id
        scrollRequest = EditorScrollRequest(target: .edge(toEnd && direction > 0 ? .bottom : .top))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MessageBanner()
                if block != nil {
                    editor
                } else {
                    Text("This block changed in iCloud Drive. Close the editor and reopen it.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("\(block?.language.capitalized ?? "Text") block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(languages, id: \.self) { language in
                            Button(language.capitalized) { model.setLanguage(language, id: currentID) }
                        }
                    } label: { Image(systemName: "curlybraces") }
                        .accessibilityLabel("Block language").disabled(block == nil || model.isOpening)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    BlockSortMenu().disabled(model.isOpening)
                    Button("Done") { dismiss() }.fontWeight(.semibold).disabled(model.isOpening)
                }
            }
            .safeAreaInset(edge: .bottom) {
                BlockNavigationBar(position: blockIndex.map { "Block \($0 + 1) of \(model.document?.blocks.count ?? 0)" } ?? "Block unavailable",
                                   enabled: block != nil && !model.isOpening,
                                   previous: { navigate(-1, toEnd: false) }, next: { navigate(1, toEnd: false) },
                                   first: { navigate(-1, toEnd: true) }, last: { navigate(1, toEnd: true) })
            }
        }.interactiveDismissDisabled(model.isOpening)
    }
}

private struct BlockSortMenu: View {
    @AppStorage("HeyNote.blocksLastFirst.v1") private var blocksLastFirst = true

    var body: some View {
        Menu {
            Picker("Block order", selection: $blocksLastFirst) {
                Text("Last to first").tag(true)
                Text("First to last").tag(false)
            }
        } label: { Image(systemName: "arrow.up.arrow.down") }
            .accessibilityLabel("Sort blocks")
    }
}

private struct BlockNavigationBar: View {
    @EnvironmentObject var model: AppModel
    let position: String
    let enabled: Bool
    let previous: () -> Void
    let next: () -> Void
    let first: () -> Void
    let last: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BlockNavigationArrow(symbol: "arrow.up", label: "Previous block", jumpLabel: "Jump to top block",
                                     enabled: enabled, tap: previous, hold: first)
                    .frame(width: 44, height: 44)
                Spacer()
                Text(position).font(.caption.monospacedDigit())
                Spacer()
                BlockNavigationArrow(symbol: "arrow.down", label: "Next block", jumpLabel: "Jump to bottom block",
                                     enabled: enabled, tap: next, hold: last)
                    .frame(width: 44, height: 44)
            }
            if let status = model.saveStatus {
                HStack(spacing: 8) {
                    if model.isSaving { ProgressView().controlSize(.mini) }
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if model.dirty, model.message != nil, !model.isSaving, !model.hasConflict {
                        Button("Save") { Task { await model.save() } }.font(.caption)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
        }.padding(.horizontal, 8).background(.bar)
    }
}

private struct BlockNavigationArrow: UIViewRepresentable {
    let symbol: String
    let label: String
    let jumpLabel: String
    let enabled: Bool
    let tap: () -> Void
    let hold: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        button.tintColor = UIColor(red: 0.16, green: 0.58, blue: 0.42, alpha: 1)
        button.accessibilityLabel = label
        button.accessibilityHint = "Tap to move one block. Touch and hold to jump to the \(symbol == "arrow.up" ? "top" : "bottom") of the buffer."
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: jumpLabel, target: context.coordinator, selector: #selector(Coordinator.accessibilityJump(_:)))]
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        press.minimumPressDuration = 0.45
        press.cancelsTouchesInView = true
        button.addGestureRecognizer(press)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
    }

    final class Coordinator: NSObject {
        var parent: BlockNavigationArrow
        private var didHold = false
        init(parent: BlockNavigationArrow) { self.parent = parent }
        @objc func touchDown() { didHold = false }
        @objc func tapped() {
            guard parent.enabled, !didHold else { return }
            parent.tap()
        }
        @objc func longPressed(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began, parent.enabled else { return }
            didHold = true
            parent.hold()
            UISelectionFeedbackGenerator().selectionChanged()
        }
        @objc func accessibilityJump(_ action: UIAccessibilityCustomAction) -> Bool {
            guard parent.enabled else { return false }
            parent.hold()
            return true
        }
    }
}

private struct FolderPicker: UIViewControllerRepresentable {
    let selected: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        init(selected: @escaping (URL) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { selected(url) }
        }
    }
}

private enum EditorEdge { case top, bottom }
private enum EditorScrollTarget { case edge(EditorEdge), match(String) }
private struct EditorScrollRequest {
    let id = UUID()
    let target: EditorScrollTarget
}

private struct NativeTextEditor: UIViewRepresentable {
    @Binding var text: String
    let blockID: UUID
    let scrollRequest: EditorScrollRequest?
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UITextView {
        let editor = UITextView()
        editor.delegate = context.coordinator
        editor.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular))
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .systemBackground
        editor.textColor = .label
        editor.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 24, right: 16)
        editor.textContainer.lineFragmentPadding = 0
        editor.alwaysBounceVertical = true
        editor.keyboardDismissMode = .interactive
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartDashesType = .no
        editor.smartQuotesType = .no
        editor.smartInsertDeleteType = .no
        editor.isFindInteractionEnabled = true
        editor.accessibilityLabel = "Scratchbuffer block"
        context.coordinator.editor = editor
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: context.coordinator, action: #selector(Coordinator.undo)),
            UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), style: .plain, target: context.coordinator, action: #selector(Coordinator.redo)),
            UIBarButtonItem(title: "Tab", style: .plain, target: context.coordinator, action: #selector(Coordinator.tab)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .search, target: context.coordinator, action: #selector(Coordinator.find)),
            UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.done))
        ]
        editor.inputAccessoryView = toolbar
        return editor
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let changedBlock = context.coordinator.blockID != blockID
        if changedBlock {
            view.unmarkText()
            view.findInteraction?.dismissFindNavigator()
            view.undoManager?.removeAllActions()
        }
        context.coordinator.parent = self
        context.coordinator.blockID = blockID
        if changedBlock || view.text != text {
            let selection = view.selectedRange
            view.text = text
            let count = (text as NSString).length
            view.selectedRange = changedBlock ? NSRange(location: 0, length: 0) : NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location)))
        }
        if changedBlock || context.coordinator.scrollRequestID != scrollRequest?.id {
            context.coordinator.scrollRequestID = scrollRequest?.id
            context.coordinator.scroll(to: scrollRequest?.target ?? .edge(.top), in: view)
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextEditor
        weak var editor: UITextView?
        var blockID: UUID?
        var scrollRequestID: UUID?
        init(parent: NativeTextEditor) { self.parent = parent }
        func scroll(to target: EditorScrollTarget, in view: UITextView) {
            let expectedBlock = blockID
            let expectedRequest = scrollRequestID
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.blockID == expectedBlock, self.scrollRequestID == expectedRequest else { return }
                let range: NSRange
                let edge: EditorEdge?
                switch target {
                case .edge(let end):
                    edge = end
                    range = NSRange(location: end == .bottom ? (view.text as NSString).length : 0, length: 0)
                case .match(let query):
                    guard let match = view.text.bufferMatch(query) else { return }
                    edge = nil
                    range = NSRange(match, in: view.text)
                }
                view.selectedRange = range
                view.layoutIfNeeded()
                view.scrollRangeToVisible(range)
                view.layoutIfNeeded()
                if let edge {
                    let top = -view.adjustedContentInset.top
                    let y = edge == .bottom ? max(top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom) : top
                    view.setContentOffset(CGPoint(x: 0, y: y), animated: true)
                }
            }
        }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        @objc func undo() { editor?.undoManager?.undo() }
        @objc func redo() { editor?.undoManager?.redo() }
        @objc func tab() { editor?.insertText("\t") }
        @objc func find() { editor?.findInteraction?.presentFindNavigator(showingReplace: true) }
        @objc func done() { editor?.resignFirstResponder() }
    }
}
