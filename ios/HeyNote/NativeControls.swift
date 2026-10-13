import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct FolderPicker: UIViewControllerRepresentable {
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

enum EditorEdge { case top, bottom }
enum EditorScrollTarget { case edge(EditorEdge), match(String) }
struct EditorScrollRequest {
    let id = UUID()
    let target: EditorScrollTarget
}

@MainActor
protocol MarkdownReading: AnyObject {
    func sourceLine(_ completion: @escaping (Double?) -> Void)
    func show(line: Double)
}

@MainActor
final class EditorControls: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    weak var editor: UITextView?
    weak var reader: MarkdownReading?
    var blockID: UUID?

    func switchMode(toSource: Bool) {
        let expected = blockID
        if toSource {
            reader?.sourceLine { [weak self] line in
                guard let self, self.blockID == expected, let line else { return }
                self.showSource(line: line)
            }
        } else {
            guard let editor else { return }
            editor.layoutIfNeeded()
            let point = CGPoint(x: 1, y: max(0, editor.contentOffset.y - editor.textContainerInset.top))
            let manager = editor.layoutManager
            let glyph = manager.glyphIndex(for: point, in: editor.textContainer)
            let offset = glyph < manager.numberOfGlyphs ? manager.characterIndexForGlyph(at: glyph) : (editor.text as NSString).length
            let line = SourceLineMap(editor.text).line(at: offset)
            editor.findInteraction?.dismissFindNavigator()
            editor.resignFirstResponder()
            reader?.show(line: line)
        }
    }

    private func showSource(line: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let editor = self?.editor else { return }
            editor.superview?.layoutIfNeeded()
            editor.layoutIfNeeded()
            let offset = SourceLineMap(editor.text).offset(at: line)
            let manager = editor.layoutManager
            let range = manager.glyphRange(forCharacterRange: NSRange(location: offset, length: offset < (editor.text as NSString).length ? 1 : 0), actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: range, in: editor.textContainer)
            let top = -editor.adjustedContentInset.top
            let bottom = max(top, editor.contentSize.height - editor.bounds.height + editor.adjustedContentInset.bottom)
            let y = min(max(rect.minY + editor.textContainerInset.top, top), bottom)
            editor.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    func refresh() {
        let undo = editor?.undoManager?.canUndo == true
        let redo = editor?.undoManager?.canRedo == true
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
    func undo() { editor?.undoManager?.undo(); refresh() }
    func redo() { editor?.undoManager?.redo(); refresh() }
    func tab() { editor?.insertText("\t"); refresh() }
}

struct NativeTextEditor: UIViewRepresentable {
    @Binding var text: String
    let blockID: UUID
    let scrollRequest: EditorScrollRequest?
    let controls: EditorControls
    var supplementalMenu: (() -> [UIMenuElement])? = nil
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UITextView {
        let editor = UITextView()
        editor.delegate = context.coordinator
        editor.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 18, weight: .regular))
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = AppDesign.raisedUI
        editor.textColor = AppDesign.textUI
        editor.tintColor = AppDesign.accentUI
        editor.textContainerInset = UIEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
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
        controls.editor = editor
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
        controls.blockID = blockID
        view.isEditable = context.environment.isEnabled
        if changedBlock || view.text != text {
            let selection = view.selectedRange
            let contentOffset = view.contentOffset
            view.text = text
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = (view.font?.pointSize ?? 18) * 1.6
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            let attributes: [NSAttributedString.Key: Any] = [
                .font: view.font!, .foregroundColor: AppDesign.textUI, .paragraphStyle: paragraph
            ]
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
            view.typingAttributes = attributes
            let count = (text as NSString).length
            view.selectedRange = changedBlock ? NSRange(location: 0, length: 0) : NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location)))
            if !changedBlock { view.setContentOffset(contentOffset, animated: false) }
        }
        DispatchQueue.main.async { controls.refresh() }
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
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            DispatchQueue.main.async { [weak self] in self?.parent.controls.refresh() }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: suggestedActions + (parent.supplementalMenu?() ?? []))
        }
    }
}
