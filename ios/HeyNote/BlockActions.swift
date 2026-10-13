import SwiftUI
import UIKit
import MarkdownUI

struct BlockActionRequest: Identifiable { let id: UUID }
struct BlockShareRequest: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class BlockActionsState: ObservableObject {
    @Published var deleting: BlockActionRequest?
    @Published var moving: BlockActionRequest?
    @Published var sharing: BlockShareRequest?

    func copy(_ id: UUID, model: AppModel, plainText: Bool = false) {
        guard let block = model.document?.blocks.first(where: { $0.id == id }) else { return }
        UIPasteboard.general.string = plainText ? MarkdownContent(block.text).renderPlainText() : block.text
    }

    func share(_ id: UUID, model: AppModel) {
        guard let block = model.document?.blocks.first(where: { $0.id == id }) else { return }
        sharing = BlockShareRequest(text: block.text)
    }

    func menu(for id: UUID, model: AppModel, lastFirst: Bool) -> [UIMenuElement] {
        guard let blocks = model.document?.blocks, let index = blocks.firstIndex(where: { $0.id == id }) else { return [] }
        let block = blocks[index]
        let top = lastFirst ? blocks.count - 1 : 0
        let bottom = lastFirst ? 0 : blocks.count - 1
        var items: [UIMenuElement] = [
            UIAction(title: "Copy block content", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(id, model: model) },
            UIAction(title: "Share block…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share(id, model: model) }
        ]
        if block.isMarkdown {
            items.append(UIAction(title: "Copy as plain text", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                self?.copy(id, model: model, plainText: true)
            })
        }
        let disabled: UIMenuElement.Attributes = model.isOpening ? .disabled : []
        items.append(UIAction(title: "Duplicate block", image: UIImage(systemName: "plus.square.on.square"), attributes: disabled) { _ in model.duplicateBlock(id) })
        items.append(UIAction(title: "Move to another buffer…", image: UIImage(systemName: "folder"),
                              attributes: model.busy || model.hasConflict ? .disabled : []) { [weak self] _ in self?.moving = BlockActionRequest(id: id) })
        items.append(UIAction(title: "Move to top", image: UIImage(systemName: "arrow.up.to.line"),
                              attributes: model.isOpening || index == top ? .disabled : []) { _ in model.reorderBlock(id, to: top) })
        items.append(UIAction(title: "Move to bottom", image: UIImage(systemName: "arrow.down.to.line"),
                              attributes: model.isOpening || index == bottom ? .disabled : []) { _ in model.reorderBlock(id, to: bottom) })
        items.append(UIAction(title: "Delete block…", image: UIImage(systemName: "trash"), attributes: disabled.union(.destructive)) { [weak self] _ in
            self?.deleting = BlockActionRequest(id: id)
        })
        return items
    }
}

struct BlockActionButtons: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var actions: BlockActionsState
    @AppStorage("HeyNote.blocksLastFirst.v1") private var lastFirst = true
    let id: UUID

    private var index: Int? { model.document?.blocks.firstIndex(where: { $0.id == id }) }
    private var count: Int { model.document?.blocks.count ?? 0 }

    var body: some View {
        Button { actions.copy(id, model: model) } label: { Label("Copy block content", systemImage: "doc.on.doc") }
        Button { actions.share(id, model: model) } label: { Label("Share block…", systemImage: "square.and.arrow.up") }
        if model.document?.blocks.first(where: { $0.id == id })?.isMarkdown == true {
            Button { actions.copy(id, model: model, plainText: true) } label: { Label("Copy as plain text", systemImage: "text.alignleft") }
        }
        Divider()
        Button { model.duplicateBlock(id) } label: { Label("Duplicate block", systemImage: "plus.square.on.square") }
            .disabled(model.isOpening)
        Button { actions.moving = BlockActionRequest(id: id) } label: { Label("Move to another buffer…", systemImage: "folder") }
            .disabled(model.busy || model.hasConflict)
        Menu {
            Button { move(by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                .disabled(index == (lastFirst ? count - 1 : 0))
            Button { move(by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                .disabled(index == (lastFirst ? 0 : count - 1))
            Button { model.reorderBlock(id, to: lastFirst ? count - 1 : 0) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
            Button { model.reorderBlock(id, to: lastFirst ? 0 : count - 1) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
        } label: { Label("Reorder block", systemImage: "arrow.up.arrow.down") }.disabled(model.isOpening || count < 2)
        Divider()
        Button(role: .destructive) { actions.deleting = BlockActionRequest(id: id) } label: { Label("Delete block…", systemImage: "trash") }
            .disabled(model.isOpening)
    }

    private func move(by direction: Int) {
        guard let index else { return }
        model.reorderBlock(id, to: index + direction * (lastFirst ? -1 : 1))
    }
}

struct BlockActionPresentation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var actions: BlockActionsState

    func body(content: Content) -> some View {
        content.background {
          Color.clear.frame(width: 0, height: 0)
            .alert("Delete this block?", isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                   presenting: actions.deleting) { request in
                Button("Cancel", role: .cancel) { actions.deleting = nil }
                Button("Delete block", role: .destructive) { model.deleteBlock(request.id); actions.deleting = nil }
            } message: { _ in Text("The block will be removed from this buffer and the change will sync to iCloud Drive.") }
            .sheet(item: $actions.sharing) { request in BlockShareSheet(text: request.text) }
            .sheet(item: $actions.moving) { request in
                MoveBlockSheet(id: request.id).environmentObject(model).tint(AppDesign.accent)
            }
        }
    }
}

private struct BlockShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct MoveBlockSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var filter = ""
    @State private var transferring = false
    private var targets: [BufferEntry] {
        model.buffers.filter {
            $0.id != model.activeID && (filter.isEmpty || $0.id.bufferMatch(filter) != nil || model.bufferDetails[$0.id]?.title.bufferMatch(filter) != nil)
        }.sorted { BufferEntry.precedes($0, $1, oldestFirst: false) }
    }

    var body: some View {
        NavigationStack {
            List {
                if transferring { HStack { ProgressView(); Text("Moving block…") } }
                ForEach(targets) { target in
                    Button {
                        transferring = true
                        Task {
                            if await model.transferBlock(id, to: target.id) { dismiss() }
                            transferring = false
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.bufferDetails[target.id]?.title ?? target.name).font(.system(size: 20, weight: .semibold))
                            Text(target.id).font(.system(size: 16)).foregroundStyle(AppDesign.secondary)
                        }.padding(.vertical, 4)
                    }.disabled(transferring || model.busy || model.hasConflict)
                }
                if targets.isEmpty { Text("No other matching buffers.").foregroundStyle(AppDesign.secondary) }
                if let message = model.message { Text(message).font(.system(size: 15)).foregroundStyle(AppDesign.secondary) }
            }
            .navigationTitle("Move block").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "Choose a destination buffer")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(transferring) } }
            .interactiveDismissDisabled(transferring)
        }
    }
}
