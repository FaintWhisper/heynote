import SwiftUI
import MarkdownUI

struct RenderedMarkdown: View {
    let text: String
    var fontSize: CGFloat = 18

    var body: some View {
        Markdown(text)
            .markdownTheme(.gitHub)
            .markdownTextStyle(\.text) {
                FontSize(fontSize)
                ForegroundColor(AppDesign.text)
                BackgroundColor(nil)
            }
            .markdownTextStyle(\.link) { ForegroundColor(AppDesign.accent) }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.95))
                BackgroundColor(AppDesign.field)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.225))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.95))
                        }
                        .padding(14)
                }
                .background(AppDesign.field, in: RoundedRectangle(cornerRadius: 8))
                .markdownMargin(top: 0, bottom: 16)
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTableBorderStyle(.init(color: AppDesign.line))
                        .markdownTableBackgroundStyle(.alternatingRows(AppDesign.raised, AppDesign.field))
                }
                .markdownMargin(top: 0, bottom: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockPreview: View, Equatable {
    let text: String
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 136

    static func == (left: Self, right: Self) -> Bool { left.text == right.text }

    var body: some View {
        RenderedMarkdown(text: text, fontSize: 17)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maximumHeight, alignment: .top)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }
}

struct MarkdownBlockReader: View {
    let text: String
    let blockID: UUID
    let scrollRequest: EditorScrollRequest?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).id("markdownTop")
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Empty block").font(.system(size: 18)).foregroundStyle(AppDesign.secondary)
                    } else {
                        RenderedMarkdown(text: text).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("markdownBottom")
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
            .background(AppDesign.raised)
            .onAppear { scroll(proxy) }
            .onChange(of: scrollRequest?.id) { _ in scroll(proxy) }
        }
        .id(blockID)
        .accessibilityLabel("Rendered Markdown block")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        let bottom: Bool
        if case .edge(.bottom)? = scrollRequest?.target { bottom = true }
        else { bottom = false }
        DispatchQueue.main.async {
            proxy.scrollTo(bottom ? "markdownBottom" : "markdownTop", anchor: bottom ? .bottom : .top)
        }
    }
}
