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
        RenderedMarkdown(text: text, fontSize: 18)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maximumHeight, alignment: .top)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }
}
