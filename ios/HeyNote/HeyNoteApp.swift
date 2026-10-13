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
    @State private var path: [String] = []
    @State private var search = ""
    @State private var chooseFolder = false
    @State private var newBuffer = false
    @State private var name = ""

    private var filtered: [BufferEntry] {
        model.buffers.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                MessageBanner()
                if model.folderName == nil {
                    welcome
                } else {
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
                                Button {
                                    path.append(id)
                                } label: {
                                    Label("Return to unsaved edits", systemImage: "pencil.circle")
                                }
                            }
                        }
                        Section("Scratchbuffers") {
                            ForEach(filtered) { entry in
                                Button {
                                    Task {
                                        if await model.open(entry.id) { path.append(entry.id) }
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
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }.padding(.vertical, 4)
                                }.disabled(model.busy)
                            }
                            if filtered.isEmpty {
                                Text(search.isEmpty ? "No .txt buffers in this folder." : "No matching buffers.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $search, prompt: "Find a buffer")
                    .refreshable { await model.refresh() }
                }
            }
            .navigationTitle("HeyNote")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { chooseFolder = true } label: { Image(systemName: "folder") }
                        .accessibilityLabel("Choose HeyNote folder")
                        .disabled(model.busy)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.isOpening {
                        ProgressView()
                    } else {
                        Button { name = ""; newBuffer = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New scratchbuffer")
                            .disabled(model.folderName == nil || model.busy)
                    }
                }
            }
            .navigationDestination(for: String.self) { _ in BufferScreen() }
            .sheet(isPresented: $chooseFolder) {
                FolderPicker { url in Task { await model.connect(url) } }
            }
            .alert("New scratchbuffer", isPresented: $newBuffer) {
                TextField("Buffer name", text: $name)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    Task {
                        if await model.create(name: name), let id = model.activeID { path.append(id) }
                    }
                }
            } message: {
                Text("Creates a HeyNote .txt buffer in the selected folder.")
            }
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

private struct BlockSelection: Identifiable { let id: UUID }

private struct BufferScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var selection: BlockSelection?
    @State private var discardEdits = false

    private var blocks: [(Int, NoteBlock)] {
        (model.document?.blocks ?? []).enumerated().compactMap { index, block in
            search.isEmpty || block.text.localizedCaseInsensitiveContains(search) || block.language.localizedCaseInsensitiveContains(search)
                ? (index + 1, block) : nil
        }
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
            List {
                Section {
                    ForEach(blocks, id: \.1.id) { index, block in
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
                } header: {
                    Text("\(model.document?.blocks.count ?? 0) blocks")
                } footer: {
                    Text("Tap a block to edit. Block headers and creation times are preserved for desktop HeyNote.")
                }
            }
            .searchable(text: $search, prompt: "Search block content")
            .refreshable { await model.refresh() }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if model.isSaving { ProgressView().controlSize(.small) }
                else { Image(systemName: model.hasConflict ? "exclamationmark.icloud" : (model.dirty ? "pencil" : "checkmark.circle")) }
                Text(model.saveStatus).font(.caption)
                Spacer()
            }.foregroundStyle(.secondary).padding(12).background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
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
            BlockEditor(id: item.id)
        }
        .alert("Discard this device's edits?", isPresented: $discardEdits) {
            Button("Cancel", role: .cancel) { }
            Button("Load iCloud version", role: .destructive) { Task { await model.useCloudVersion() } }
        } message: {
            Text("The unsaved edits on this device will be removed. The current buffer in iCloud Drive will be opened.")
        }
        .onDisappear { Task { await model.save() } }
    }
}

private struct BlockEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let id: UUID
    private let languages = ["text", "markdown", "math", "javascript", "jsx", "typescript", "tsx", "json", "python", "html", "css", "sql", "xml", "yaml", "toml", "shell", "powershell", "swift", "rust", "cpp", "csharp", "java", "golang", "ruby", "php", "clojure", "elixir", "erlang", "kotlin", "lua", "groovy", "diff", "vue", "dart", "scala", "mermaid", "lezer"]
    private var block: NoteBlock? { model.document?.blocks.first(where: { $0.id == id }) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MessageBanner()
                if block != nil {
                    NativeTextEditor(text: Binding(get: { model.text(for: id) }, set: { model.updateText($0, id: id) }))
                        .disabled(model.isOpening)
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
                            Button(language.capitalized) { model.setLanguage(language, id: id) }
                        }
                    } label: { Image(systemName: "curlybraces") }
                        .accessibilityLabel("Block language").disabled(block == nil || model.isOpening)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).disabled(model.isOpening)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.saveStatus).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
            }
        }.interactiveDismissDisabled(model.isOpening)
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

private struct NativeTextEditor: UIViewRepresentable {
    @Binding var text: String
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
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            let count = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location)))
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextEditor
        weak var editor: UITextView?
        init(parent: NativeTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        @objc func undo() { editor?.undoManager?.undo() }
        @objc func redo() { editor?.undoManager?.redo() }
        @objc func tab() { editor?.insertText("\t") }
        @objc func find() { editor?.findInteraction?.presentFindNavigator(showingReplace: true) }
        @objc func done() { editor?.resignFirstResponder() }
    }
}
