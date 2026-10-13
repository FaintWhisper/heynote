import SwiftUI
import UIKit

@main
struct HeyNoteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .environmentObject(model)
                .tint(AppDesign.accent)
                .foregroundStyle(AppDesign.text)
                .background(AppDesign.bar.ignoresSafeArea())
                .onChange(of: phase) { value in
                    Task { await model.sceneChanged(value) }
                }
        }
    }
}

private struct BufferDetailsRequest: Hashable {
    let folder: UUID
    let entries: [BufferEntry]
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
    @State private var scrolled = false

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var orderedBuffers: [BufferEntry] {
        model.buffers.sorted { BufferEntry.precedes($0, $1, oldestFirst: oldestFirst) }
    }
    private var filtered: [BufferEntry] {
        orderedBuffers.filter {
            query.isEmpty || $0.id.bufferMatch(query) != nil || model.bufferDetails[$0.id]?.title.bufferMatch(query) != nil
        }
    }
    private var orderedHits: [BufferSearchHit] {
        let positions = Dictionary(uniqueKeysWithValues: orderedBuffers.enumerated().map { ($0.element.id, $0.offset) })
        return model.searchHits.sorted {
            if $0.bufferID == $1.bufferID {
                return blocksLastFirst ? $0.blockIndex > $1.blockIndex : $0.blockIndex < $1.blockIndex
            }
            return (positions[$0.bufferID] ?? Int.max) < (positions[$1.bufferID] ?? Int.max)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                AppChrome {
                    Button { chooseFolder = true } label: { Image(systemName: "folder") }
                        .accessibilityLabel("Choose HeyNote folder").disabled(model.busy)
                    Spacer()
                    Menu {
                        Picker("File modification date", selection: $oldestFirst) {
                            Text("Newest modified first").tag(false)
                            Text("Oldest modified first").tag(true)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel("Sort buffers by file modification date")
                        .disabled(model.folderName == nil)
                    if model.isOpening {
                        ProgressView().frame(width: 44, height: 44)
                    } else {
                        Button { name = ""; newBuffer = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New scratchbuffer")
                            .disabled(model.folderName == nil || model.busy)
                    }
                }
                Text("HeyNote").font(.system(size: 34, weight: .bold)).tracking(-0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 10)
                    .background(AppDesign.bar)
                if model.folderName != nil {
                    AppSearchField(text: $search, prompt: "Search names and contents", scrolled: scrolled)
                }
                MessageBanner()
                if model.folderName == nil { welcome }
                else { library }
            }
            .background(AppDesign.surface)
            .navigationTitle("HeyNote")
            .toolbar(.hidden, for: .navigationBar)
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
                        if await model.create(name: name), let id = model.activeID {
                            path.append(BufferRoute(bufferID: id))
                        }
                    }
                }
            } message: { Text("Creates a HeyNote .txt buffer in the selected folder.") }
        }
        .task(id: LibrarySearchRequest(query: search, folder: model.folderVersion, reload: searchReload, active: path.isEmpty)) {
            guard path.isEmpty else { return }
            await model.searchAll(search)
        }
        .task(id: BufferDetailsRequest(folder: model.folderVersion, entries: model.buffers)) {
            await model.loadBufferDetails()
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
        VStack(spacing: 0) {
            DesignScroll(scrolled: $scrolled) {
                if query.isEmpty { bufferList }
                else { searchResults }
            }
            .refreshable {
                await model.refreshSearch()
                searchReload = UUID()
            }
            Text("\(model.buffers.count) buffers · \(model.folderName ?? "HeyNote")")
                .font(.system(size: 12)).foregroundStyle(AppDesign.secondary)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(AppDesign.bar)
                .overlay(alignment: .top) { DesignSeparator(leading: 0) }
        }
    }

    private var bufferList: some View {
        Group {
            if model.dirty, let id = model.activeID {
                Button { path.append(BufferRoute(bufferID: id)) } label: {
                    Label("Return to unsaved edits", systemImage: "pencil.circle")
                        .font(.system(size: 14)).padding(.bottom, 14)
                }.buttonStyle(.plain)
            }
            DesignSectionLabel(oldestFirst ? "Oldest modified first" : "Newest modified first")
            bufferGroup(orderedBuffers)
            DesignSectionFoot("Choose the same HeyNote folder on your iPhone to sync through iCloud Drive.")
        }
    }

    private func bufferGroup(_ entries: [BufferEntry]) -> some View {
        DesignGroup {
            ForEach(entries) { entry in
                bufferRow(entry)
                    .overlay(alignment: .bottom) {
                        if entry.id != entries.last?.id { DesignSeparator(leading: 48) }
                    }
            }
            if entries.isEmpty {
                Text("No .txt buffers in this folder.").font(.system(size: 15))
                    .foregroundStyle(AppDesign.secondary).padding(24)
            }
        }
    }

    private func details(for entry: BufferEntry) -> BufferDetails? {
        if entry.id == model.activeID, let document = model.document {
            return BufferDetails(title: model.title, blockCount: document.blocks.count)
        }
        return model.bufferDetails[entry.id]
    }

    private func bufferRow(_ entry: BufferEntry) -> some View {
        let details = details(for: entry)
        let title = details?.title ?? entry.name
        let showFilename = entry.name.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame || !entry.directory.isEmpty
        let count = details.map { "\($0.blockCount) \($0.blockCount == 1 ? "block" : "blocks"), " } ?? ""
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        return Button {
            Task {
                if await model.open(entry.id) { path.append(BufferRoute(bufferID: entry.id)) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: 22, weight: .light))
                    .foregroundStyle(AppDesign.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.25)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if let date = entry.modified {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 13)).foregroundStyle(AppDesign.secondary)
                                .fixedSize().accessibilityLabel("Modified \(date.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    Text((showFilename ? entry.id + ", " : "") + count + size)
                        .font(.system(size: 13)).foregroundStyle(AppDesign.secondary).lineLimit(1)
                    if let error = model.bufferDetailsErrors[entry.id] {
                        Text(error).font(.system(size: 12)).foregroundStyle(AppDesign.secondary).lineLimit(2)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppDesign.secondary.opacity(0.45))
            }
            .foregroundStyle(AppDesign.text)
            .padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 64)
        }.buttonStyle(DesignRowStyle()).disabled(model.busy)
    }

    private var searchResults: some View {
        Group {
            Group {
                if model.isSearching || model.searchQuery != query {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.searchFileCount == 0 ? "Searching all buffers…" : "Searching \(model.searchedFiles) of \(model.searchFileCount) buffers…")
                    }
                } else if let error = model.searchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else {
                    Text("\(model.searchHits.count) matching blocks in \(Set(model.searchHits.map(\.bufferID)).count) buffers")
                }
            }
            .font(.system(size: 13)).foregroundStyle(AppDesign.secondary)
            .padding(.horizontal, 4).padding(.bottom, 16)
            if !filtered.isEmpty {
                DesignSectionLabel("Buffer names")
                bufferGroup(filtered)
            }
            if model.searchQuery == query {
                DesignSectionLabel("Content matches")
                DesignGroup {
                    ForEach(orderedHits) { hit in
                        searchRow(hit)
                            .overlay(alignment: .bottom) {
                                if hit.id != orderedHits.last?.id { DesignSeparator() }
                            }
                    }
                    if model.searchHits.isEmpty, !model.isSearching, model.searchError == nil {
                        Text(model.searchFailures.isEmpty ? "No matching block content." : "No matches in the buffers that could be searched.")
                            .font(.system(size: 15)).foregroundStyle(AppDesign.secondary).padding(24)
                    }
                }
                if !model.searchFailures.isEmpty {
                    DesignSectionLabel("Could not search \(model.searchFailures.count) buffers")
                    DesignGroup {
                        ForEach(model.searchFailures) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.id).font(.system(size: 14))
                                Text(failure.message).font(.system(size: 12)).foregroundStyle(AppDesign.secondary)
                            }.padding(15)
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
                HStack(spacing: 9) {
                    Text(hit.bufferName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("Block \(hit.blockIndex + 1)").font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(AppDesign.secondary)
                }
                HighlightedPreview(text: hit.excerpt, query: query, lines: 3)
                Text("\(hit.bufferID) · \(hit.language)").font(.system(size: 12))
                    .foregroundStyle(AppDesign.secondary).lineLimit(1)
            }.foregroundStyle(AppDesign.text).padding(.horizontal, 15).padding(.vertical, 13)
        }.buttonStyle(DesignRowStyle()).disabled(model.busy)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.and.pencil").font(.system(size: 54, weight: .light)).foregroundStyle(AppDesign.accent)
            Text("Your scratchpad, everywhere.").font(.title2.bold())
            Text("Choose the HeyNote folder under iCloud Drive in Files. Your existing buffers stay in the same folder and sync with HeyNote on your computer.")
                .multilineTextAlignment(.center).foregroundStyle(AppDesign.secondary)
            Button("Choose HeyNote folder") { chooseFolder = true }
                .buttonStyle(.borderedProminent).disabled(model.busy)
            Text("Use the same Apple Account on this device and your computer.")
                .font(.footnote).foregroundStyle(AppDesign.secondary).multilineTextAlignment(.center)
            Spacer()
            Text("HeyNote by Jonatan Heyman · iOS companion").font(.system(size: 12)).foregroundStyle(AppDesign.secondary)
        }.padding(28)
    }
}

private struct HighlightedPreview: View {
    let text: String
    var query = ""
    var lines = 4
    private var highlighted: AttributedString {
        var value = AttributedString(text)
        if !query.isEmpty, let range = text.bufferMatch(query), let match = Range(range, in: value) {
            value[match].backgroundColor = AppDesign.selection
        }
        return value
    }
    var body: some View {
        Text(highlighted).font(.system(size: 13.5, design: .monospaced)).lineSpacing(4)
            .lineLimit(lines).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let message = model.message {
            HStack(alignment: .top, spacing: 12) {
                Text(message).font(.system(size: 13)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.message = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss message").foregroundStyle(AppDesign.accent)
            }.padding(.vertical, 12).padding(.horizontal, 16).background(AppDesign.selection)
        }
    }
}

private struct BlockSelection: Identifiable {
    let id: UUID
    var query = ""
}

private struct BlockFramesPreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct BufferScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("HeyNote.blocksLastFirst.v1") private var blocksLastFirst = true
    let initialHit: BufferSearchHit?
    let initialQuery: String
    @State private var search = ""
    @State private var selection: BlockSelection?
    @State private var discardEdits = false
    @State private var panelPosition: UUID?
    @State private var openedInitialHit = false
    @State private var scrolled = false

    private var blocks: [(Int, NoteBlock)] {
        let matching: [(Int, NoteBlock)] = (model.document?.blocks ?? []).enumerated().compactMap { index, block in
            search.isEmpty || block.text.bufferMatch(search) != nil || block.language.bufferMatch(search) != nil
                ? (index + 1, block) : nil
        }
        return blocksLastFirst ? Array(matching.reversed()) : matching
    }

    var body: some View {
        VStack(spacing: 0) {
            AppChrome(title: model.title) {
                Button { dismiss() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                        Text("HeyNote").font(.system(size: 17))
                    }
                }.accessibilityLabel("Back to HeyNote")
                Spacer()
                BlockSortMenu().disabled(model.document == nil || model.isOpening)
                Button { Task { await model.save() } } label: { Image(systemName: "arrow.down.to.line") }
                    .accessibilityLabel("Save buffer").disabled(!model.dirty || model.busy || model.hasConflict)
                Button {
                    if let id = model.addBlock() { selection = BlockSelection(id: id) }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add block").disabled(model.isOpening)
            }
            AppSearchField(text: $search, prompt: "Search block content", scrolled: scrolled)
            MessageBanner()
            if model.hasConflict {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This buffer has another version.").font(.headline)
                    Text("Keep this device's edits in a new buffer, or discard them and load the current file from iCloud Drive.")
                        .font(.footnote).foregroundStyle(AppDesign.secondary)
                    Button("Save my edits as a new buffer") { Task { await model.saveCopy() } }
                        .buttonStyle(.borderedProminent)
                    Button("Use iCloud version…") { discardEdits = true }.disabled(model.cloudConflict)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            blockPanel
        }
        .background(AppDesign.surface)
        .navigationTitle(model.title).toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selection, onDismiss: { Task { await model.save() } }) { item in
            BlockEditor(id: item.id, query: item.query)
                .environmentObject(model).tint(AppDesign.accent)
        }
        .alert("Discard this device's edits?", isPresented: $discardEdits) {
            Button("Cancel", role: .cancel) { }
            Button("Load iCloud version", role: .destructive) { Task { await model.useCloudVersion() } }
        } message: { Text("The unsaved edits on this device will be removed. The current buffer in iCloud Drive will be opened.") }
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
            } else { model.message = "This search result changed in iCloud Drive. Search again to find its current block." }
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
        panelPosition = visible[target].1.id
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(visible[target].1.id, anchor: toEnd && direction > 0 ? .bottom : .top)
        }
    }

    private var blockPanel: some View {
        let visible = blocks
        return ScrollViewReader { proxy in
            GeometryReader { viewport in
                VStack(spacing: 0) {
                    DesignScroll(scrolled: $scrolled) {
                        DesignSectionLabel("\(model.document?.blocks.count ?? 0) blocks · \(blocksLastFirst ? "last to first" : "first to last")")
                        DesignGroup {
                            ForEach(visible, id: \.1.id) { index, block in
                                blockRow(index, block: block)
                                    .id(block.id)
                                    .overlay(alignment: .bottom) {
                                        if block.id != visible.last?.1.id { DesignSeparator() }
                                    }
                                    .background(GeometryReader { row in
                                        Color.clear.preference(key: BlockFramesPreference.self,
                                                               value: [block.id: row.frame(in: .named("blockPanel"))])
                                    })
                            }
                            if visible.isEmpty {
                                Text("No matching blocks.").font(.system(size: 15))
                                    .foregroundStyle(AppDesign.secondary).padding(24)
                            }
                        }
                        DesignSectionFoot("Tap a block to edit. Hold an arrow to jump to the start or end.")
                    }
                    .coordinateSpace(name: "blockPanel")
                    .onPreferenceChange(BlockFramesPreference.self) { frames in
                        let first = visible.first { _, block in
                            guard let frame = frames[block.id] else { return false }
                            return frame.maxY > 0 && frame.minY < viewport.size.height - 48
                        }?.1.id
                        if let first, panelPosition != first { panelPosition = first }
                    }
                    .refreshable { await model.refresh() }
                    BlockNavigationBar(position: panelLabel, enabled: !visible.isEmpty && !model.isOpening,
                                       previous: { movePanel(-1, toEnd: false, proxy: proxy) },
                                       next: { movePanel(1, toEnd: false, proxy: proxy) },
                                       first: { movePanel(-1, toEnd: true, proxy: proxy) },
                                       last: { movePanel(1, toEnd: true, proxy: proxy) })
                }
            }
            .onChange(of: search) { _ in scrollToTop(proxy) }
            .onChange(of: blocksLastFirst) { _ in scrollToTop(proxy) }
            .onChange(of: selection?.id) { id in
                if let id, visible.contains(where: { $0.1.id == id }) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        panelPosition = blocks.first?.1.id
        if let id = panelPosition { proxy.scrollTo(id, anchor: .top) }
    }

    private func blockRow(_ index: Int, block: NoteBlock) -> some View {
        Button { selection = BlockSelection(id: block.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(block.language).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("\(index)").font(.system(size: 12).monospacedDigit())
                }.foregroundStyle(AppDesign.secondary)
                HighlightedPreview(text: block.preview, query: search)
                    .foregroundStyle(AppDesign.text)
            }.padding(.horizontal, 15).padding(.vertical, 13)
        }.buttonStyle(DesignRowStyle())
    }
}

private struct BlockEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("HeyNote.blocksLastFirst.v1") private var blocksLastFirst = true
    @StateObject private var controls = EditorControls()
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
        let id = currentID
        return NativeTextEditor(text: Binding(get: { model.text(for: id) }, set: { model.updateText($0, id: id) }),
                                blockID: id, scrollRequest: scrollRequest, controls: controls)
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
        VStack(spacing: 0) {
            AppChrome(title: blockIndex.map { "Block \($0 + 1)" }, height: 56) {
                Menu {
                    ForEach(languages, id: \.self) { language in
                        Button(language.capitalized) { model.setLanguage(language, id: currentID) }
                    }
                } label: {
                    Text(block?.language.capitalized ?? "Text").font(.system(size: 16))
                        .lineLimit(1).frame(minWidth: 80, alignment: .leading).padding(.horizontal, 8)
                }.accessibilityLabel("Block language").disabled(block == nil || model.isOpening)
                Spacer()
                BlockSortMenu().disabled(model.isOpening)
                Button("Done") { dismiss() }.font(.system(size: 17, weight: .semibold)).disabled(model.isOpening)
            }
            .overlay(alignment: .bottom) { DesignSeparator(leading: 0) }
            MessageBanner()
            if block != nil { editor }
            else {
                Text("This block changed in iCloud Drive. Close the editor and reopen it.")
                    .foregroundStyle(AppDesign.secondary).padding().frame(maxHeight: .infinity)
            }
            HStack(spacing: 2) {
                Button { controls.tab() } label: { Image(systemName: "arrow.right.to.line") }
                    .accessibilityLabel("Insert tab")
                Button { controls.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("Undo").disabled(!controls.canUndo)
                Button { controls.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityLabel("Redo").disabled(!controls.canRedo)
                Spacer(minLength: 4)
                Text("\((block?.text.count ?? 0).formatted()) characters")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(AppDesign.secondary)
                    .lineLimit(1).padding(.trailing, 8)
            }
            .buttonStyle(EditorToolStyle()).padding(.horizontal, 8).frame(height: 42)
            .background(AppDesign.bar).overlay(alignment: .top) { DesignSeparator(leading: 0) }
            .disabled(block == nil || model.isOpening)
            BlockNavigationBar(position: blockIndex.map { "Block \($0 + 1) of \(model.document?.blocks.count ?? 0)" } ?? "Block unavailable",
                               enabled: block != nil && !model.isOpening,
                               previous: { navigate(-1, toEnd: false) }, next: { navigate(1, toEnd: false) },
                               first: { navigate(-1, toEnd: true) }, last: { navigate(1, toEnd: true) })
        }
        .foregroundStyle(AppDesign.text)
        .background(AppDesign.bar.ignoresSafeArea())
        .interactiveDismissDisabled(model.isOpening)
    }
}

private struct EditorToolStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 22, weight: .regular))
            .foregroundStyle(AppDesign.accent).frame(width: 40, height: 36)
            .contentShape(Rectangle()).opacity(!enabled ? 0.35 : (configuration.isPressed ? 0.5 : 1))
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
                BlockNavigationArrow(symbol: "chevron.up", label: "Previous block", jumpLabel: "Jump to top block",
                                     enabled: enabled, tap: previous, hold: first)
                    .frame(width: 44, height: 44)
                Spacer()
                Text(position).font(.system(size: 13).monospacedDigit()).foregroundStyle(AppDesign.secondary)
                Spacer()
                BlockNavigationArrow(symbol: "chevron.down", label: "Next block", jumpLabel: "Jump to bottom block",
                                     enabled: enabled, tap: next, hold: last)
                    .frame(width: 44, height: 44)
            }.frame(height: 48)
            if let status = model.saveStatus {
                HStack(spacing: 8) {
                    if model.isSaving { ProgressView().controlSize(.mini) }
                    Text(status).font(.system(size: 12)).foregroundStyle(AppDesign.secondary).lineLimit(2)
                    if model.dirty, model.message != nil, !model.isSaving, !model.hasConflict {
                        Button("Save") { Task { await model.save() } }.font(.system(size: 12))
                    }
                }.padding(.horizontal, 15).padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 8).background(AppDesign.bar)
        .overlay(alignment: .top) { DesignSeparator(leading: 0) }
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
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        button.tintColor = AppDesign.accentUI
        button.accessibilityLabel = label
        button.accessibilityHint = "Tap to move one block. Touch and hold to jump to the \(symbol == "chevron.up" ? "top" : "bottom") of the buffer."
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: jumpLabel, target: context.coordinator, selector: #selector(Coordinator.accessibilityJump(_:)))]
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        press.minimumPressDuration = 0.45
        press.cancelsTouchesInView = true
        button.addGestureRecognizer(press)
        return button
    }
    func updateUIView(_ view: UIButton, context: Context) {
        context.coordinator.parent = self
        view.isEnabled = enabled
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
